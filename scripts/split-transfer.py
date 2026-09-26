#!/usr/bin/env python3
"""Split a verified transfer file into numbered parts + a manifest.

Used by fetch-and-package.sh when a file is larger than the chunk threshold,
so that every Actions artifact stays well under the 512 MiB download limit of
downstream sandboxes (e.g. ChatGPT's GitHub connector).

Layout written under <out-dir>:

  parts/<output>.part000, parts/<output>.part001, ...   (one artifact each)
  manifest/manifest.json      machine-readable parts list + hashes
  manifest/parts.sha256       "<sha256>  <part name>" in reassembly order
  manifest/file.sha256        "<sha256>  <output>" for the full file
  manifest/reassemble.sh      copy of scripts/reassemble.sh
  manifest/request.json       normalized request (if --request-json given)
  manifest/SHA256SUMS         hashes of the manifest artifact's own files
  part-count.txt

The source file is only read, never executed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
from pathlib import Path

MIB = 1024 * 1024
DEFAULT_CHUNK_BYTES = 400 * MIB
MAX_CHUNK_BYTES = 450 * MIB  # keeps each artifact safely < 512 MiB after zip overhead
MAX_PARTS = 16  # build-transfer.yml has exactly this many part upload steps
READ_BLOCK = 4 * MIB
OUTPUT_RE = re.compile(r"^[a-zA-Z0-9._-]{1,128}$")


def die(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(1)


def part_name(output: str, index: int) -> str:
    return f"{output}.part{index:03d}"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(READ_BLOCK), b""):
            h.update(block)
    return h.hexdigest()


def split(
    src: Path,
    out_dir: Path,
    *,
    output: str,
    chunk_bytes: int,
    artifact_base: str,
    expect_sha256: str | None,
    max_parts: int,
    min_chunk_bytes: int,
) -> dict:
    if not OUTPUT_RE.match(output) or ".." in output:
        die(f"invalid output name {output!r}")
    if chunk_bytes < min_chunk_bytes or chunk_bytes > MAX_CHUNK_BYTES:
        die(f"chunk_bytes {chunk_bytes} out of range ({min_chunk_bytes}..{MAX_CHUNK_BYTES})")
    size = src.stat().st_size
    if size == 0:
        die("refusing to split an empty file")
    part_count = -(-size // chunk_bytes)
    if part_count > max_parts:
        die(
            f"{size} bytes at chunk_bytes={chunk_bytes} needs {part_count} parts; "
            f"max is {max_parts}. Use a larger payload.chunk_bytes."
        )

    parts_dir = out_dir / "parts"
    manifest_dir = out_dir / "manifest"
    parts_dir.mkdir(parents=True, exist_ok=True)
    manifest_dir.mkdir(parents=True, exist_ok=True)

    full = hashlib.sha256()
    parts = []
    with src.open("rb") as f:
        for index in range(part_count):
            name = part_name(output, index)
            h = hashlib.sha256()
            written = 0
            with (parts_dir / name).open("wb") as pf:
                while written < chunk_bytes:
                    block = f.read(min(READ_BLOCK, chunk_bytes - written))
                    if not block:
                        break
                    pf.write(block)
                    h.update(block)
                    full.update(block)
                    written += len(block)
            if written == 0:
                die(f"internal error: empty part {name}")
            parts.append(
                {
                    "index": index,
                    "name": name,
                    "size": written,
                    "sha256": h.hexdigest(),
                    "artifact": f"{artifact_base}-part{index:03d}",
                }
            )
        if f.read(1):
            die("internal error: bytes left over after splitting")

    full_sha = full.hexdigest()
    if expect_sha256 and full_sha != expect_sha256.lower():
        die(f"sha256 mismatch while splitting: expected {expect_sha256}, got {full_sha}")
    if sum(p["size"] for p in parts) != size:
        die("internal error: part sizes do not add up")

    manifest = {
        "schema": 1,
        "kind": "transfer-chunked",
        "output": output,
        "size": size,
        "sha256": full_sha,
        "chunk_bytes": chunk_bytes,
        "part_count": part_count,
        "artifact_base": artifact_base,
        "manifest_artifact": f"{artifact_base}-manifest",
        "parts": parts,
        "reassemble": "reassemble.sh",
    }
    return manifest


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("src", help="verified source file")
    ap.add_argument("out_dir", help="output directory")
    ap.add_argument("--output", help="original filename (default: basename of src)")
    ap.add_argument("--artifact-base", required=True, help="e.g. transfer-issue-3-608ba5081c89")
    ap.add_argument("--chunk-bytes", type=int, default=DEFAULT_CHUNK_BYTES)
    ap.add_argument("--expect-sha256", help="fail if the full file hash differs")
    ap.add_argument("--max-parts", type=int, default=MAX_PARTS)
    ap.add_argument("--min-chunk-bytes", type=int, default=MIB,
                    help="lower bound for --chunk-bytes (tests use a tiny value)")
    ap.add_argument("--request-json", help="normalized request to include in the manifest artifact")
    ap.add_argument("--meta", help="JSON object of extra top-level manifest fields")
    ap.add_argument("--reassemble-script",
                    default=str(Path(__file__).resolve().parent / "reassemble.sh"))
    args = ap.parse_args()

    src = Path(args.src)
    if not src.is_file():
        die(f"not a file: {src}")
    out_dir = Path(args.out_dir)
    output = args.output or src.name

    manifest = split(
        src,
        out_dir,
        output=output,
        chunk_bytes=args.chunk_bytes,
        artifact_base=args.artifact_base,
        expect_sha256=args.expect_sha256,
        max_parts=args.max_parts,
        min_chunk_bytes=args.min_chunk_bytes,
    )
    if args.meta:
        extra = json.loads(args.meta)
        if not isinstance(extra, dict):
            die("--meta must be a JSON object")
        for k, v in extra.items():
            manifest.setdefault(k, v)

    manifest_dir = out_dir / "manifest"
    (manifest_dir / "manifest.json").write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    (manifest_dir / "parts.sha256").write_text(
        "".join(f"{p['sha256']}  {p['name']}\n" for p in manifest["parts"]), encoding="utf-8"
    )
    (manifest_dir / "file.sha256").write_text(
        f"{manifest['sha256']}  {manifest['output']}\n", encoding="utf-8"
    )
    dst_script = manifest_dir / "reassemble.sh"
    shutil.copyfile(args.reassemble_script, dst_script)
    os.chmod(dst_script, 0o755)
    files = ["manifest.json", "parts.sha256", "file.sha256", "reassemble.sh"]
    if args.request_json:
        shutil.copyfile(args.request_json, manifest_dir / "request.json")
        files.append("request.json")
    (manifest_dir / "SHA256SUMS").write_text(
        "".join(f"{sha256_file(manifest_dir / n)}  {n}\n" for n in files), encoding="utf-8"
    )
    (out_dir / "part-count.txt").write_text(f"{manifest['part_count']}\n", encoding="utf-8")

    print(f"split {manifest['output']} ({manifest['size']} bytes, sha256 {manifest['sha256']})")
    print(f"  chunk_bytes={manifest['chunk_bytes']} parts={manifest['part_count']}")
    for p in manifest["parts"]:
        print(f"  {p['artifact']}: {p['name']} {p['size']} bytes sha256 {p['sha256']}")
    print(f"  manifest artifact: {manifest['manifest_artifact']}")


if __name__ == "__main__":
    main()
