# Chunked transfers (files > 400 MiB)

Downstream sandboxes (for example ChatGPT's GitHub connector) cannot download a
single Actions artifact larger than **512 MiB**. So after the SHA-256 check,
`build-transfer.yml` splits any file larger than the chunk threshold into
numbered parts and uploads **one artifact per part**, plus a small manifest
artifact.

| Setting | Value |
| --- | --- |
| Default threshold / part size | 400 MiB (419430400 bytes) |
| Per-request override | `payload.chunk_bytes`, 1 MiB..450 MiB |
| Max parts | 16 (fails with a clear error if more would be needed) |
| `max_bytes` | Still enforced on the full download (default 512 MiB, hard cap 2 GiB) |

Files at or below the threshold keep the old behavior: one artifact
`transfer-issue-<n>-<request_sha12>` with `transfer-payload.tar.gz`, the raw
file, `manifest.json` and `SHA256SUMS`.

## Artifacts for a chunked transfer

| Artifact | Contents |
| --- | --- |
| `transfer-issue-<n>-<sha12>-part000` | `<output>.part000` (first `chunk_bytes` bytes) |
| `transfer-issue-<n>-<sha12>-part001` | `<output>.part001` |
| … | … |
| `transfer-issue-<n>-<sha12>-manifest` | `manifest.json`, `parts.sha256`, `file.sha256`, `reassemble.sh`, `request.json`, `SHA256SUMS` |

Parts are uploaded with `compression-level: 0`; each is at most 450 MiB, so the
artifact ZIP stays well under 512 MiB. The build job also re-runs
`reassemble.sh` on the runner before uploading, as a self-check.

`manifest.json` (chunked):

```json
{
  "schema": 1,
  "kind": "transfer-chunked",
  "type": "fetch",
  "name": "lean-4.34.1-linux",
  "request_issue": 3,
  "request_sha256": "…",
  "source_url": "https://…",
  "output": "lean-4.34.1-linux.tar.zst",
  "size": 600000000,
  "sha256": "<sha256 of the full file>",
  "chunk_bytes": 419430400,
  "part_count": 2,
  "artifact_base": "transfer-issue-3-608ba5081c89",
  "manifest_artifact": "transfer-issue-3-608ba5081c89-manifest",
  "parts": [
    {"index": 0, "name": "lean-4.34.1-linux.tar.zst.part000", "size": 419430400,
     "sha256": "…", "artifact": "transfer-issue-3-608ba5081c89-part000"},
    {"index": 1, "name": "lean-4.34.1-linux.tar.zst.part001", "size": 180569600,
     "sha256": "…", "artifact": "transfer-issue-3-608ba5081c89-part001"}
  ],
  "reassemble": "reassemble.sh"
}
```

(Sizes above are illustrative.) The issue comment posted by the workflow lists
the same information: every artifact name, part file, size and SHA-256.

## Sandbox side: download and reassemble

1. From the workflow run linked in the issue comment, download **every**
   `…-partNNN` artifact and the `…-manifest` artifact into `/mnt/data`
   (one at a time is fine; each is < 512 MiB).
2. Unzip each ZIP into its own directory:

   ```bash
   cd /mnt/data && mkdir -p xfer
   for z in transfer-issue-3-608ba5081c89-*.zip; do unzip -o "$z" -d "xfer/${z%.zip}"; done
   ```

3. Reassemble and verify:

   ```bash
   bash /mnt/data/xfer/transfer-issue-3-608ba5081c89-manifest/reassemble.sh /mnt/data/xfer /mnt/data
   # -> /mnt/data/lean-4.34.1-linux.tar.zst
   ```

`reassemble.sh [parts-dir] [out-dir]` finds each `<output>.partNNN` anywhere
under `parts-dir`, verifies every part against `parts.sha256`, `cat`s them in
order into a temp file, verifies the full-file SHA-256 from `file.sha256`, and
only then moves the result into `out-dir`. It needs only bash and
`sha256sum` (or `shasum`); it exits non-zero on a missing, duplicated or corrupt
part and never leaves a half-written output file.

Manual equivalent:

```bash
cd /mnt/data/xfer
cat */lean-4.34.1-linux.tar.zst.part000 */lean-4.34.1-linux.tar.zst.part001 > /mnt/data/lean-4.34.1-linux.tar.zst
sha256sum */*.part*                              # compare with parts.sha256 / manifest.json
sha256sum /mnt/data/lean-4.34.1-linux.tar.zst    # compare with manifest "sha256"
```

## Testing

`scripts/test-chunking.sh` (run by `.github/workflows/test.yml` on every pull
request) splits a synthetic 10000-byte file with a tiny chunk size, checks
`manifest.json`, simulates per-artifact download directories, reassembles, and
checks corrupt/missing-part detection, `max_bytes` enforcement and the
single-vs-chunked decision in `fetch-and-package.sh`. `curl` is replaced by a
local stub, so CI makes no external downloads.
