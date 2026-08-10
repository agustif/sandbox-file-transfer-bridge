# sandbox-file-transfer-bridge

**Generic approved file transfer** for ChatGPT’s Linux sandbox (and any offline
x86_64 Linux environment).

GitHub Actions has internet. The sandbox often does not. This repo is a **byte
ingress factory**: approve a request → download/package on a runner → ship an
Actions artifact ZIP → GitHub connector → `/mnt/data`.

It does **not** remotely execute your programs. Payloads are **inert**.

```text
REQUEST (public issue, JSON only)
        │
        ▼
maintainer applies approved-transfer
        │
        ▼
networked fetch on trusted default-branch workflow
        │
        ▼
transfer artifact (tar.gz + manifest + SHA256SUMS)
        │
        ▼
GitHub Actions artifact ZIP
        │
        ▼
ChatGPT GitHub connector → /mnt/data
        │
        ▼
sandbox unpack / install / run
```

Public repo: [agustif/sandbox-file-transfer-bridge](https://github.com/agustif/sandbox-file-transfer-bridge)

Related specialized factory: [agustif/rust-sandbox-bridge](https://github.com/agustif/rust-sandbox-bridge)
(official Rust toolchain + cargo-vendor).

---

## v1: `type: fetch`

Anyone can open an issue with:

```json
{
  "schema": 1,
  "kind": "artifact-request",
  "name": "example-fetch",
  "type": "fetch",
  "payload": {
    "url": "https://example.com/file.tar.gz",
    "sha256": "…64 hex chars…",
    "output": "file.tar.gz",
    "max_bytes": 104857600
  }
}
```

A maintainer applies **`approved-transfer`**. CI then:

1. Parses JSON as data only (no shell interpolation of untrusted strings as code)
2. Downloads over HTTPS
3. Verifies SHA-256 (fail closed)
4. Packages `transfer-payload.tar.gz` + `manifest.json` + `SHA256SUMS`
5. Uploads artifact `transfer-issue-<n>-<request_sha12>` (90-day retention)
6. Comments on the issue

---

## Labels

| Label | Meaning |
| --- | --- |
| `approved-transfer` | Maintainer approved; starts transfer workflow |
| `transfer-built` | Artifact produced successfully |

No auto-approve. Labeler must have **write**, **maintain**, or **admin**.

---

## Security

- Issue body is untrusted **data**
- Never `eval` / execute request text or downloaded blobs on the runner
- HTTPS only; credentials in URLs rejected
- SHA-256 mandatory for `fetch`
- Size caps (default 512 MiB, hard 2 GiB)
- Optional host allowlist in `scripts/parse-request.py` (`HOST_ALLOWLIST`)
- Minimal Actions permissions; workflow always from default branch

---

## Sandbox usage

```bash
# After connector places artifact ZIP under /mnt/data
unzip /mnt/data/transfer-issue-*.zip -d /mnt/data/transfer
cd /mnt/data/transfer
sha256sum -c SHA256SUMS
# raw file often at top level:
ls -la
# or:
tar -xzf transfer-payload.tar.gz -C /mnt/data/payload
```

Helpers:

| Script | Purpose |
| --- | --- |
| `scripts/parse-request.py` | Validate issue JSON |
| `scripts/fetch-and-package.sh` | Download + package (CI) |
| `scripts/verify-transfer.sh` | Checksums + manifest |
| `scripts/apply-transfer.sh` | Extract into a dest dir |
| `scripts/discover-artifacts.sh` | List recent artifacts via `gh` |

---

## Discovery (agents)

1. List successful runs of `build-transfer.yml`
2. List artifacts on the run
3. Download ZIP named `transfer-issue-<n>-*`
4. Verify `SHA256SUMS`
5. Use payload

Manifest keys (stable):

```json
{
  "schema": 1,
  "kind": "transfer",
  "type": "fetch",
  "name": "...",
  "request_issue": 1,
  "request_sha256": "...",
  "output": "...",
  "output_sha256": "...",
  "archive": "transfer-payload.tar.gz",
  "sha256": "..."
}
```

---

## Future types

See [docs/request-types.md](./docs/request-types.md): `apt`, `oci-rootfs`, etc.
Same approval door; different packaging recipes.

Library cache conventions: [docs/library-cache.md](./docs/library-cache.md).

---

## Maintainer

```bash
# After reviewing an issue:
gh issue edit <N> --add-label approved-transfer --repo agustif/sandbox-file-transfer-bridge
```

---

## License

MIT — see [LICENSE](./LICENSE).
