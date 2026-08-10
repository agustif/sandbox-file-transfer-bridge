#!/usr/bin/env bash
# Verify a transfer artifact (directory, tar.gz package, or Actions ZIP).
#
# Usage:
#   ./scripts/verify-transfer.sh <artifact-dir|transfer-payload.tar.gz|artifact.zip>
set -euo pipefail

SRC=${1:-}
if [[ -z "$SRC" ]]; then
  echo "Usage: $0 <artifact-dir|tar.gz|zip>" >&2
  exit 2
fi

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

DIR=""
if [[ -d "$SRC" ]]; then
  DIR=$SRC
elif [[ -f "$SRC" ]]; then
  case "$SRC" in
    *.zip)
      unzip -q "$SRC" -d "$WORKDIR/zip"
      # Prefer a dir that contains manifest.json
      DIR=$(find "$WORKDIR/zip" -type f -name manifest.json -exec dirname {} \; | head -n1)
      [[ -n "$DIR" ]] || { echo "error: manifest.json not found in ZIP" >&2; exit 1; }
      ;;
    *.tar.gz|*.tgz)
      mkdir -p "$WORKDIR/extract"
      tar -xzf "$SRC" -C "$WORKDIR/extract"
      DIR=$WORKDIR/extract
      ;;
    *)
      echo "error: unsupported file type: $SRC" >&2
      exit 1
      ;;
  esac
else
  echo "error: not found: $SRC" >&2
  exit 1
fi

cd "$DIR"
if [[ ! -f manifest.json ]]; then
  echo "error: manifest.json missing in $DIR" >&2
  ls -la >&2
  exit 1
fi

if [[ -f SHA256SUMS ]]; then
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -c SHA256SUMS
  else
    shasum -a 256 -c SHA256SUMS
  fi
  echo "SHA256SUMS: ok"
else
  echo "warning: no SHA256SUMS" >&2
fi

python3 - <<'PY'
import json, sys
from pathlib import Path
m = json.loads(Path("manifest.json").read_text())
for k in ("schema", "kind", "type", "sha256", "archive"):
    if k not in m:
        sys.exit(f"manifest missing {k}")
print(f"manifest ok: kind={m['kind']} type={m['type']} name={m.get('name')}")
if m.get("output"):
    p = Path(m["output"])
    if p.is_file():
        print(f"output present: {p} ({p.stat().st_size} bytes)")
    else:
        # may only be inside the archive
        print(f"note: raw output file not at top level (may be inside {m.get('archive')})")
PY

echo "transfer verification passed"
