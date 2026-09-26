#!/usr/bin/env python3
"""Parse and validate an untrusted transfer request (issue body → JSON).

Security:
  - Issue text is data only — never eval/exec/source.
  - Never interpolate request fields into a shell without treating them as data.
  - v1 supports type=fetch only (HTTPS URL + required sha256).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

SCHEMA = 1
MAX_BODY_BYTES = 64 * 1024
MAX_NAME_LEN = 64
MAX_OUTPUT_LEN = 128
MAX_NOTES_LEN = 2000
DEFAULT_MAX_BYTES = 512 * 1024 * 1024  # 512 MiB default
ABSOLUTE_MAX_BYTES = 2 * 1024 * 1024 * 1024  # 2 GiB hard cap
# Files larger than chunk_bytes are split into parts, one Actions artifact each
# (downstream sandboxes cannot download a single artifact > 512 MiB).
DEFAULT_CHUNK_BYTES = 400 * 1024 * 1024  # 400 MiB
MIN_CHUNK_BYTES = 1 * 1024 * 1024  # 1 MiB
MAX_CHUNK_BYTES = 450 * 1024 * 1024  # 450 MiB: stays < 512 MiB after zip overhead

# Optional host allowlist. Empty = any HTTPS host (still requires sha256).
# Maintainers can tighten this list in-repo without changing the parser API.
HOST_ALLOWLIST: set[str] = set()

NAME_RE = re.compile(r"^[a-zA-Z0-9._-]{1,64}$")
OUTPUT_RE = re.compile(r"^[a-zA-Z0-9._-]{1,128}$")
SHA256_RE = re.compile(r"^[a-fA-F0-9]{64}$")
JSON_FENCE_RE = re.compile(r"```(?:json)?\s*\n(.*?)\n```", re.DOTALL | re.IGNORECASE)

SUPPORTED_TYPES = {"fetch"}


class RequestError(Exception):
    pass


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def extract_json_blob(text: str) -> dict[str, Any]:
    if len(text.encode("utf-8")) > MAX_BODY_BYTES:
        raise RequestError(f"issue body exceeds {MAX_BODY_BYTES} bytes")

    candidates: list[str] = []
    candidates.extend(JSON_FENCE_RE.findall(text))
    stripped = text.strip()
    if stripped.startswith("{"):
        candidates.append(stripped)

    last_err: Exception | None = None
    for blob in candidates:
        try:
            data = json.loads(blob)
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError as e:
            last_err = e
            continue

    if last_err:
        raise RequestError(f"failed to parse JSON: {last_err}")
    raise RequestError("no valid JSON object found; put a fenced ```json block in the issue")


def validate_fetch_payload(payload: Any) -> dict[str, Any]:
    if not isinstance(payload, dict):
        raise RequestError("payload must be an object")

    allowed_keys = {"url", "sha256", "output", "max_bytes", "chunk_bytes"}
    unknown = set(payload.keys()) - allowed_keys
    if unknown:
        raise RequestError(f"payload has unsupported keys: {sorted(unknown)}")

    url = payload.get("url")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise RequestError("payload.url must be an https:// URL")
    if any(x in url for x in ("\n", "\r", " ", "\t", '"', "'", "`", "$", "|", ";", "&")):
        raise RequestError("payload.url contains forbidden characters")

    parsed = urlparse(url)
    if parsed.scheme != "https" or not parsed.hostname:
        raise RequestError("payload.url must be a valid https URL with a host")
    if parsed.username or parsed.password:
        raise RequestError("payload.url must not include credentials")
    host = parsed.hostname.lower()
    if HOST_ALLOWLIST and host not in HOST_ALLOWLIST:
        raise RequestError(
            f"host {host!r} not in allowlist; edit scripts/parse-request.py HOST_ALLOWLIST"
        )

    sha256 = payload.get("sha256")
    if not isinstance(sha256, str) or not SHA256_RE.match(sha256):
        raise RequestError("payload.sha256 must be a 64-char hex digest")
    sha256 = sha256.lower()

    output = payload.get("output")
    if not isinstance(output, str) or not OUTPUT_RE.match(output):
        raise RequestError("payload.output must match [a-zA-Z0-9._-]{1,128}")
    if ".." in output or "/" in output or "\\" in output:
        raise RequestError("payload.output must be a plain filename, not a path")

    max_bytes = payload.get("max_bytes", DEFAULT_MAX_BYTES)
    if not isinstance(max_bytes, int) or isinstance(max_bytes, bool):
        raise RequestError("payload.max_bytes must be an integer")
    if max_bytes < 1 or max_bytes > ABSOLUTE_MAX_BYTES:
        raise RequestError(f"payload.max_bytes out of range (1..{ABSOLUTE_MAX_BYTES})")

    result = {
        "url": url,
        "sha256": sha256,
        "output": output,
        "max_bytes": max_bytes,
        "host": host,
    }

    # Optional; only included when given so existing request hashes stay stable.
    if "chunk_bytes" in payload:
        chunk_bytes = payload["chunk_bytes"]
        if not isinstance(chunk_bytes, int) or isinstance(chunk_bytes, bool):
            raise RequestError("payload.chunk_bytes must be an integer")
        if chunk_bytes < MIN_CHUNK_BYTES or chunk_bytes > MAX_CHUNK_BYTES:
            raise RequestError(
                f"payload.chunk_bytes out of range ({MIN_CHUNK_BYTES}..{MAX_CHUNK_BYTES})"
            )
        result["chunk_bytes"] = chunk_bytes

    return result


def validate_request(data: dict[str, Any]) -> dict[str, Any]:
    if data.get("schema") != SCHEMA:
        raise RequestError(f"unsupported schema: {data.get('schema')!r} (want {SCHEMA})")
    if data.get("kind") != "artifact-request":
        raise RequestError("kind must be 'artifact-request'")

    name = data.get("name")
    if not isinstance(name, str) or not NAME_RE.match(name):
        raise RequestError("name must match [a-zA-Z0-9._-]{1,64}")

    req_type = data.get("type")
    if req_type not in SUPPORTED_TYPES:
        raise RequestError(
            f"unsupported type {req_type!r}; v1 supports: {sorted(SUPPORTED_TYPES)}"
        )

    notes = data.get("notes", "")
    if notes is None:
        notes = ""
    if not isinstance(notes, str) or len(notes) > MAX_NOTES_LEN:
        raise RequestError(f"notes must be a string ≤ {MAX_NOTES_LEN} chars")

    if req_type == "fetch":
        payload = validate_fetch_payload(data.get("payload"))
    else:
        raise RequestError(f"unhandled type: {req_type}")

    # Reject any other top-level keys beyond known set
    allowed_top = {"schema", "kind", "name", "type", "payload", "notes"}
    unknown = set(data.keys()) - allowed_top
    if unknown:
        raise RequestError(f"unsupported top-level keys: {sorted(unknown)}")

    out = {
        "schema": SCHEMA,
        "kind": "artifact-request",
        "name": name,
        "type": req_type,
        "payload": payload,
    }
    if notes:
        out["notes"] = notes

    # Stable request hash for artifact naming / cache keys
    canonical = json.dumps(out, sort_keys=True, separators=(",", ":"))
    out["request_sha256"] = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("input", nargs="?", help="Issue body path (default: stdin)")
    ap.add_argument("--out-request", required=True, help="Normalized request JSON path")
    ap.add_argument("--print-type", action="store_true")
    ap.add_argument("--print-request-sha", action="store_true")
    args = ap.parse_args()

    text = Path(args.input).read_text(encoding="utf-8") if args.input else sys.stdin.read()
    try:
        raw = extract_json_blob(text)
        request = validate_request(raw)
    except RequestError as e:
        die(str(e))

    out = Path(args.out_request)
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(request, indent=2, sort_keys=True) + "\n", encoding="utf-8")

    if args.print_type:
        print(request["type"])
    elif args.print_request_sha:
        print(request["request_sha256"])
    else:
        print(f"ok: wrote {out}")
        print(f"  name={request['name']} type={request['type']}")
        print(f"  request_sha256={request['request_sha256']}")
        if request["type"] == "fetch":
            p = request["payload"]
            print(
                f"  host={p['host']} output={p['output']} max_bytes={p['max_bytes']}"
                f" chunk_bytes={p.get('chunk_bytes', DEFAULT_CHUNK_BYTES)}"
            )


if __name__ == "__main__":
    main()
