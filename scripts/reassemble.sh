#!/usr/bin/env bash
# Reassemble a chunked transfer produced by scripts/split-transfer.py.
#
# Usage:
#   ./reassemble.sh [parts-dir] [out-dir]
#
#   parts-dir  directory searched (recursively) for <output>.partNNN files.
#              Default: current directory. Each part artifact ZIP can simply be
#              unzipped into its own subdirectory under here.
#   out-dir    where <output> is written. Default: current directory.
#
# Reads parts.sha256 and file.sha256 from the directory containing this script
# (the unzipped manifest artifact); override with MANIFEST_DIR=...
#
# Steps: locate every part, verify each part's sha256, cat them in order,
# verify the full file's sha256, then atomically move it into place.
# Needs only bash + coreutils (sha256sum) or shasum; python3 is not required.
set -euo pipefail

MANIFEST_DIR=${MANIFEST_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}
PARTS_DIR=${1:-.}
OUT_DIR=${2:-.}

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

die() { echo "error: $*" >&2; exit 1; }

[[ -f "$MANIFEST_DIR/parts.sha256" ]] || die "missing $MANIFEST_DIR/parts.sha256"
[[ -f "$MANIFEST_DIR/file.sha256" ]] || die "missing $MANIFEST_DIR/file.sha256"
[[ -d "$PARTS_DIR" ]] || die "parts dir not found: $PARTS_DIR"
mkdir -p "$OUT_DIR"

read -r EXPECT_SHA OUTPUT <"$MANIFEST_DIR/file.sha256"
[[ "$EXPECT_SHA" =~ ^[0-9a-f]{64}$ ]] || die "bad sha256 in file.sha256"
[[ "$OUTPUT" =~ ^[A-Za-z0-9._-]{1,128}$ && "$OUTPUT" != *..* ]] || die "bad output name in file.sha256"

PART_PATHS=()
INDEX=0
while read -r PART_SHA PART_NAME; do
  [[ -z "${PART_SHA:-}" ]] && continue
  [[ "$PART_SHA" =~ ^[0-9a-f]{64}$ ]] || die "bad sha256 line in parts.sha256"
  WANT_NAME=$(printf '%s.part%03d' "$OUTPUT" "$INDEX")
  [[ "$PART_NAME" == "$WANT_NAME" ]] || die "parts.sha256 out of order: got $PART_NAME, want $WANT_NAME"

  MATCHES=()
  while IFS= read -r -d '' f; do MATCHES+=("$f"); done \
    < <(find "$PARTS_DIR" -type f -name "$PART_NAME" -print0)
  [[ ${#MATCHES[@]} -gt 0 ]] || die "part not found under $PARTS_DIR: $PART_NAME"
  [[ ${#MATCHES[@]} -eq 1 ]] || die "multiple copies of $PART_NAME under $PARTS_DIR: ${MATCHES[*]}"

  GOT_SHA=$(sha256_of "${MATCHES[0]}")
  if [[ "$GOT_SHA" != "$PART_SHA" ]]; then
    die "sha256 mismatch for $PART_NAME (expected $PART_SHA, got $GOT_SHA)"
  fi
  echo "part ok: $PART_NAME ($GOT_SHA)"
  PART_PATHS+=("${MATCHES[0]}")
  INDEX=$((INDEX + 1))
done <"$MANIFEST_DIR/parts.sha256"

[[ ${#PART_PATHS[@]} -gt 0 ]] || die "parts.sha256 lists no parts"

TMP="$OUT_DIR/.$OUTPUT.reassemble.$$"
trap 'rm -f "$TMP"' EXIT
cat "${PART_PATHS[@]}" >"$TMP"

GOT_SHA=$(sha256_of "$TMP")
if [[ "$GOT_SHA" != "$EXPECT_SHA" ]]; then
  die "sha256 mismatch for reassembled $OUTPUT (expected $EXPECT_SHA, got $GOT_SHA)"
fi
mv -f "$TMP" "$OUT_DIR/$OUTPUT"
trap - EXIT
echo "reassembled $OUT_DIR/$OUTPUT from ${#PART_PATHS[@]} parts; sha256 ok ($GOT_SHA)"
