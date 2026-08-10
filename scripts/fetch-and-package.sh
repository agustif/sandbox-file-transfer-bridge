#!/usr/bin/env bash
# Download a validated fetch request and package a transfer artifact.
#
# Usage:
#   ./scripts/fetch-and-package.sh <request.json> <out-dir> [issue-number]
#
# Expects request.json produced by parse-request.py (type=fetch).
# Uses curl for the download; verifies sha256; never executes the payload.
set -euo pipefail

REQUEST_JSON=${1:-}
OUT_DIR=${2:-}
ISSUE_NUMBER=${3:-0}

if [[ -z "$REQUEST_JSON" || -z "$OUT_DIR" ]]; then
  echo "Usage: $0 <request.json> <out-dir> [issue-number]" >&2
  exit 2
fi

REQUEST_JSON=$(cd "$(dirname "$REQUEST_JSON")" && pwd)/$(basename "$REQUEST_JSON")
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd "$OUT_DIR" && pwd)

command -v curl >/dev/null
command -v python3 >/dev/null

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# Extract fields as shell-safe assignments
eval "$(python3 - "$REQUEST_JSON" <<'PY'
import json, sys, shlex
r = json.load(open(sys.argv[1], encoding="utf-8"))
if r.get("type") != "fetch":
    raise SystemExit("error: only type=fetch supported in this script")
p = r["payload"]
print(f"REQ_NAME={shlex.quote(r['name'])}")
print(f"REQ_SHA={shlex.quote(r['request_sha256'])}")
print(f"URL={shlex.quote(p['url'])}")
print(f"EXPECT_SHA={shlex.quote(p['sha256'])}")
print(f"OUTPUT={shlex.quote(p['output'])}")
print(f"MAX_BYTES={int(p['max_bytes'])}")
print(f"HOST={shlex.quote(p['host'])}")
PY
)"

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
PAYLOAD_PATH="$STAGE/$OUTPUT"

echo "Fetching host=$HOST output=$OUTPUT max_bytes=$MAX_BYTES"
CURL_OPTS=(--fail --silent --show-error --location --proto-redir =https --max-redirs 5)
if curl --help all 2>/dev/null | grep -q -- '--max-filesize'; then
  CURL_OPTS+=(--max-filesize "$MAX_BYTES")
fi

curl "${CURL_OPTS[@]}" --output "$PAYLOAD_PATH" "$URL"

ACTUAL_SIZE=$(wc -c <"$PAYLOAD_PATH" | tr -d ' ')
if [[ "$ACTUAL_SIZE" -gt "$MAX_BYTES" ]]; then
  echo "error: downloaded size $ACTUAL_SIZE exceeds max_bytes $MAX_BYTES" >&2
  exit 1
fi
if [[ "$ACTUAL_SIZE" -eq 0 ]]; then
  echo "error: empty download" >&2
  exit 1
fi

ACTUAL_SHA=$(sha256_file "$PAYLOAD_PATH")
if [[ "$ACTUAL_SHA" != "$EXPECT_SHA" ]]; then
  echo "error: sha256 mismatch" >&2
  echo "  expected: $EXPECT_SHA" >&2
  echo "  actual:   $ACTUAL_SHA" >&2
  exit 1
fi
echo "sha256 ok ($ACTUAL_SHA)"

ARCHIVE_NAME=transfer-payload.tar.gz
mkdir -p "$STAGE/pkg"
cp "$PAYLOAD_PATH" "$STAGE/pkg/$OUTPUT"
cp "$REQUEST_JSON" "$STAGE/pkg/request.json"

CREATED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
GIT_SHA=${GITHUB_SHA:-unknown}

tar -czf "$OUT_DIR/$ARCHIVE_NAME" -C "$STAGE/pkg" .
ARCHIVE_SHA=$(sha256_file "$OUT_DIR/$ARCHIVE_NAME")
ARCHIVE_BYTES=$(wc -c <"$OUT_DIR/$ARCHIVE_NAME" | tr -d ' ')

cp "$PAYLOAD_PATH" "$OUT_DIR/$OUTPUT"
cp "$REQUEST_JSON" "$OUT_DIR/request.json"

export OUT_DIR ARCHIVE_NAME ARCHIVE_SHA ARCHIVE_BYTES
export REQ_NAME REQ_SHA ISSUE_NUMBER CREATED_AT GIT_SHA
export HOST URL OUTPUT ACTUAL_SHA ACTUAL_SIZE

python3 - <<'PY'
import json, os
from pathlib import Path
out = Path(os.environ["OUT_DIR"])
manifest = {
    "schema": 1,
    "kind": "transfer",
    "type": "fetch",
    "name": os.environ["REQ_NAME"],
    "request_issue": int(os.environ["ISSUE_NUMBER"]),
    "request_sha256": os.environ["REQ_SHA"],
    "created_at": os.environ["CREATED_AT"],
    "git_sha": os.environ["GIT_SHA"],
    "host": os.environ["HOST"],
    "source_url": os.environ["URL"],
    "output": os.environ["OUTPUT"],
    "output_sha256": os.environ["ACTUAL_SHA"],
    "output_bytes": int(os.environ["ACTUAL_SIZE"]),
    "archive": os.environ["ARCHIVE_NAME"],
    "sha256": os.environ["ARCHIVE_SHA"],
    "archive_bytes": int(os.environ["ARCHIVE_BYTES"]),
    "notes": "Inert bytes only. Sandbox unpacks/uses; runner does not execute payload.",
}
(out / "manifest.json").write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(json.dumps(manifest, indent=2))
PY

{
  echo "${ARCHIVE_SHA}  ${ARCHIVE_NAME}"
  echo "${ACTUAL_SHA}  ${OUTPUT}"
  echo "$(sha256_file "$OUT_DIR/manifest.json")  manifest.json"
  echo "$(sha256_file "$OUT_DIR/request.json")  request.json"
} >"$OUT_DIR/SHA256SUMS"

SHORT=${REQ_SHA:0:12}
ARTIFACT_NAME="transfer-issue-${ISSUE_NUMBER}-${SHORT}"
echo "$ARTIFACT_NAME" >"$OUT_DIR/artifact-name.txt"

echo "Wrote transfer artifact to $OUT_DIR"
echo "  artifact_hint=$ARTIFACT_NAME"
echo "  archive=$ARCHIVE_NAME sha256=$ARCHIVE_SHA"
echo "  file=$OUTPUT sha256=$ACTUAL_SHA size=$ACTUAL_SIZE"
