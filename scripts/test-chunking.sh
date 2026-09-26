#!/usr/bin/env bash
# Offline tests for chunked transfers: parser, split, manifest, reassembly and
# the fetch-and-package chunk decision. No network: curl is replaced by a stub
# that copies a local synthetic file.
#
# Usage: ./scripts/test-chunking.sh
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
S="$ROOT/scripts"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

PASS=0
ok() { echo "ok - $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL - $*" >&2; exit 1; }
sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }
expect_fail() { # <description> <cmd...>
  local d=$1; shift
  if "$@" >"$T/last.log" 2>&1; then cat "$T/last.log" >&2; fail "$d (expected failure)"; fi
  ok "$d"
}

# ---------------------------------------------------------------- synthetic file
python3 -c 'import os,sys; sys.stdout.buffer.write(os.urandom(10000))' >"$T/blob.bin"
BLOB_SHA=$(sha "$T/blob.bin")

# ---------------------------------------------------------------- parser
req() { # <payload-json-fragment> -> issue body file path
  cat >"$T/issue.txt" <<EOF
\`\`\`json
{"schema":1,"kind":"artifact-request","name":"t","type":"fetch",
 "payload":{"url":"https://example.com/blob.bin","sha256":"$BLOB_SHA","output":"blob.bin"$1}}
\`\`\`
EOF
  echo "$T/issue.txt"
}
python3 "$S/parse-request.py" "$(req '')" --out-request "$T/r0.json" >/dev/null
python3 - "$T/r0.json" <<'PY' || fail "chunk_bytes must be absent when not requested"
import json, sys; r = json.load(open(sys.argv[1])); assert "chunk_bytes" not in r["payload"]
PY
ok "parser: no chunk_bytes by default (request hash unchanged for old requests)"
python3 "$S/parse-request.py" "$(req ',"chunk_bytes":1048576')" --out-request "$T/r1.json" >/dev/null
python3 - "$T/r1.json" <<'PY' || fail "chunk_bytes not kept"
import json, sys; r = json.load(open(sys.argv[1])); assert r["payload"]["chunk_bytes"] == 1048576
PY
ok "parser: accepts payload.chunk_bytes"
expect_fail "parser: rejects chunk_bytes below 1 MiB" python3 "$S/parse-request.py" "$(req ',"chunk_bytes":1000')" --out-request "$T/x.json"
expect_fail "parser: rejects chunk_bytes above 450 MiB" python3 "$S/parse-request.py" "$(req ',"chunk_bytes":500000000')" --out-request "$T/x.json"
expect_fail "parser: rejects non-integer chunk_bytes" python3 "$S/parse-request.py" "$(req ',"chunk_bytes":"big"')" --out-request "$T/x.json"

# ---------------------------------------------------------------- split + manifest
OUT="$T/out"
python3 "$S/split-transfer.py" "$T/blob.bin" "$OUT" --artifact-base transfer-issue-9-abcdef012345 \
  --chunk-bytes 3000 --min-chunk-bytes 1 --expect-sha256 "$BLOB_SHA" >/dev/null
[[ "$(ls "$OUT/parts" | tr '\n' ' ')" == "blob.bin.part000 blob.bin.part001 blob.bin.part002 blob.bin.part003 " ]] \
  || fail "unexpected parts: $(ls "$OUT/parts")"
ok "split: 10000 bytes / 3000 -> 4 numbered parts"
[[ "$(cat "$OUT/part-count.txt")" == 4 ]] || fail "part-count.txt"
python3 - "$OUT" "$BLOB_SHA" <<'PY' || fail "manifest.json contents"
import hashlib, json, sys
from pathlib import Path
out, sha = Path(sys.argv[1]), sys.argv[2]
m = json.loads((out / "manifest" / "manifest.json").read_text())
assert m["output"] == "blob.bin" and m["size"] == 10000 and m["sha256"] == sha, m
assert m["part_count"] == 4 and m["chunk_bytes"] == 3000
assert m["manifest_artifact"] == "transfer-issue-9-abcdef012345-manifest"
assert [p["size"] for p in m["parts"]] == [3000, 3000, 3000, 1000]
for i, p in enumerate(m["parts"]):
    assert p["index"] == i and p["name"] == f"blob.bin.part{i:03d}"
    assert p["artifact"] == f"transfer-issue-9-abcdef012345-part{i:03d}"
    assert hashlib.sha256((out / "parts" / p["name"]).read_bytes()).hexdigest() == p["sha256"]
lines = (out / "manifest" / "parts.sha256").read_text().splitlines()
assert lines == [f'{p["sha256"]}  {p["name"]}' for p in m["parts"]]
assert (out / "manifest" / "file.sha256").read_text() == f"{sha}  blob.bin\n"
PY
ok "manifest: original name, size, sha256 and per-part name/size/sha256/artifact"
(cd "$OUT/manifest" && if command -v sha256sum >/dev/null; then sha256sum -c --quiet SHA256SUMS; else shasum -a 256 -c --quiet SHA256SUMS; fi) \
  || fail "manifest SHA256SUMS"
[[ -x "$OUT/manifest/reassemble.sh" ]] || fail "reassemble.sh missing/not executable"
ok "manifest artifact: SHA256SUMS valid, reassemble.sh included"

expect_fail "split: refuses more than max parts" python3 "$S/split-transfer.py" "$T/blob.bin" "$T/o2" \
  --artifact-base b --chunk-bytes 100 --min-chunk-bytes 1
expect_fail "split: refuses wrong expected sha256" python3 "$S/split-transfer.py" "$T/blob.bin" "$T/o3" \
  --artifact-base b --chunk-bytes 3000 --min-chunk-bytes 1 --expect-sha256 "$(printf '0%.0s' {1..64})"

# ---------------------------------------------------------------- reassembly
# Simulate the sandbox: each artifact ZIP unzipped into its own directory.
stage_download() { # <dest>
  local d=$1; rm -rf "$d"; mkdir -p "$d/manifest"
  cp "$OUT"/manifest/* "$d/manifest/"
  for p in "$OUT"/parts/*; do mkdir -p "$d/$(basename "$p")-artifact"; cp "$p" "$d/$(basename "$p")-artifact/"; done
}
D="$T/dl"
stage_download "$D"
(cd "$D" && bash manifest/reassemble.sh . "$T/rejoined") >/dev/null
cmp "$T/blob.bin" "$T/rejoined/blob.bin" || fail "reassembled file differs"
ok "reassemble: parts from separate artifact dirs rejoin byte-identical"

stage_download "$D"
printf 'X' | dd of="$(ls "$D"/blob.bin.part002-artifact/*)" bs=1 seek=10 conv=notrunc 2>/dev/null
expect_fail "reassemble: detects a corrupted part" bash "$D/manifest/reassemble.sh" "$D" "$T/r2"
[[ ! -e "$T/r2/blob.bin" ]] || fail "corrupt reassembly left an output file"

stage_download "$D"
rm -rf "$D/blob.bin.part001-artifact"
expect_fail "reassemble: detects a missing part" bash "$D/manifest/reassemble.sh" "$D" "$T/r3"

stage_download "$D"
printf '%064d  blob.bin\n' 0 >"$D/manifest/file.sha256"
expect_fail "reassemble: detects full-file sha256 mismatch" bash "$D/manifest/reassemble.sh" "$D" "$T/r4"
[[ ! -e "$T/r4/blob.bin" ]] || fail "bad full sha left an output file"

# ---------------------------------------------------------------- fetch-and-package (curl stubbed)
mkdir -p "$T/bin"
cat >"$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Test stub: never touches the network; copies $FAKE_CURL_SRC to --output.
out=""
while [[ $# -gt 0 ]]; do
  case "$1" in --output) out=$2; shift 2 ;; --help) exit 0 ;; *) shift ;; esac
done
[[ -n "$out" ]] || exit 2
cp "$FAKE_CURL_SRC" "$out"
EOF
chmod +x "$T/bin/curl"

mkreq() { # <file> <chunk_bytes|""> <max_bytes> -> request json path
  python3 - "$1" "$2" "$3" "$(sha "$1")" "$T/req.json" <<'PY'
import json, sys
f, chunk, maxb, sha, out = sys.argv[1:]
p = {"url": "https://example.com/blob.bin", "sha256": sha, "output": "blob.bin",
     "max_bytes": int(maxb), "host": "example.com"}
if chunk:
    p["chunk_bytes"] = int(chunk)
json.dump({"schema": 1, "kind": "artifact-request", "name": "t", "type": "fetch",
           "payload": p, "request_sha256": "abcdef0123456789" * 4}, open(out, "w"))
PY
  echo "$T/req.json"
}

export FAKE_CURL_SRC="$T/blob.bin"
PATH="$T/bin:$PATH" SPLIT_EXTRA_ARGS="--min-chunk-bytes 1" \
  "$S/fetch-and-package.sh" "$(mkreq "$T/blob.bin" 4096 20000)" "$T/fp1" 9 >/dev/null
[[ "$(cat "$T/fp1/mode.txt")" == chunked ]] || fail "expected chunked mode"
[[ "$(cat "$T/fp1/artifact-name.txt")" == transfer-issue-9-abcdef012345 ]] || fail "artifact name"
[[ "$(cat "$T/fp1/part-count.txt")" == 3 ]] || fail "expected 3 parts"
[[ ! -e "$T/fp1/transfer-payload.tar.gz" ]] || fail "chunked mode should not build a tarball"
python3 - "$T/fp1/manifest/manifest.json" <<'PY' || fail "chunked manifest metadata"
import json, sys; m = json.load(open(sys.argv[1]))
assert m["request_issue"] == 9 and m["name"] == "t" and m["type"] == "fetch" and m["part_count"] == 3
PY
(cd "$T/fp1" && bash manifest/reassemble.sh parts "$T/fp1-out") >/dev/null
cmp "$T/blob.bin" "$T/fp1-out/blob.bin" || fail "fetch-and-package chunked roundtrip"
ok "fetch-and-package: file > chunk_bytes -> chunked parts + manifest, roundtrip ok"

PATH="$T/bin:$PATH" "$S/fetch-and-package.sh" "$(mkreq "$T/blob.bin" "" 20000)" "$T/fp2" 9 >/dev/null
[[ "$(cat "$T/fp2/mode.txt")" == single ]] || fail "expected single mode"
[[ -f "$T/fp2/transfer-payload.tar.gz" && -f "$T/fp2/blob.bin" && ! -d "$T/fp2/parts" ]] || fail "single layout"
"$S/verify-transfer.sh" "$T/fp2" >/dev/null || fail "verify-transfer on single mode"
ok "fetch-and-package: file <= default 400 MiB threshold -> unchanged single artifact"

expect_fail "fetch-and-package: max_bytes still enforced" env PATH="$T/bin:$PATH" \
  "$S/fetch-and-package.sh" "$(mkreq "$T/blob.bin" 4096 5000)" "$T/fp3" 9

# ---------------------------------------------------------------- workflow wiring
WF="$ROOT/.github/workflows/build-transfer.yml"
MAX_PARTS=$(python3 -c 'import importlib.util,sys; s=importlib.util.spec_from_file_location("s", sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); print(m.MAX_PARTS)' "$S/split-transfer.py")
for ((i = 0; i < MAX_PARTS; i++)); do
  n=$(printf '%03d' "$i")
  grep -q -- "-part${n}\$" "$WF" || fail "build-transfer.yml has no upload step for part${n}"
done
ok "workflow: upload steps exist for all $MAX_PARTS possible parts"

echo "all $PASS chunking tests passed"
