#!/usr/bin/env bash
# Extract a transfer artifact into a destination directory.
#
# Usage:
#   ./scripts/apply-transfer.sh <artifact.zip|transfer-payload.tar.gz|artifact-dir> <dest-dir>
set -euo pipefail

SRC=${1:-}
DEST=${2:-}
if [[ -z "$SRC" || -z "$DEST" ]]; then
  echo "Usage: $0 <artifact.zip|tar.gz|dir> <dest-dir>" >&2
  exit 2
fi

mkdir -p "$DEST"
ABS_DEST=$(cd "$DEST" && pwd)
WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

if [[ -d "$SRC" ]]; then
  if [[ -f "$SRC/transfer-payload.tar.gz" ]]; then
    tar -xzf "$SRC/transfer-payload.tar.gz" -C "$ABS_DEST"
    # Also copy manifests if present
    for f in manifest.json SHA256SUMS request.json; do
      [[ -f "$SRC/$f" ]] && cp "$SRC/$f" "$ABS_DEST/" || true
    done
  else
    cp -a "$SRC"/. "$ABS_DEST"/
  fi
elif [[ "$SRC" == *.zip ]]; then
  unzip -q "$SRC" -d "$WORKDIR/zip"
  ROOT=$(find "$WORKDIR/zip" -type f -name manifest.json -exec dirname {} \; | head -n1)
  [[ -n "$ROOT" ]] || { echo "error: manifest.json not found" >&2; exit 1; }
  if [[ -f "$ROOT/transfer-payload.tar.gz" ]]; then
    tar -xzf "$ROOT/transfer-payload.tar.gz" -C "$ABS_DEST"
    for f in manifest.json SHA256SUMS request.json; do
      [[ -f "$ROOT/$f" ]] && cp "$ROOT/$f" "$ABS_DEST/" || true
    done
  else
    cp -a "$ROOT"/. "$ABS_DEST"/
  fi
elif [[ "$SRC" == *.tar.gz || "$SRC" == *.tgz ]]; then
  tar -xzf "$SRC" -C "$ABS_DEST"
else
  echo "error: unsupported source: $SRC" >&2
  exit 1
fi

echo "Applied transfer artifact to $ABS_DEST"
ls -la "$ABS_DEST" | head -30
