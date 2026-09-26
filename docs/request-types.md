# Request types

## v1: `fetch`

```json
{
  "schema": 1,
  "kind": "artifact-request",
  "name": "my-file",
  "type": "fetch",
  "payload": {
    "url": "https://example.com/tool.tar.gz",
    "sha256": "<64 hex chars>",
    "output": "tool.tar.gz",
    "max_bytes": 104857600
  }
}
```

| Field | Required | Notes |
| --- | --- | --- |
| `url` | yes | `https://` only; no credentials |
| `sha256` | yes | Fails closed on mismatch |
| `output` | yes | Basename only |
| `max_bytes` | no | Default 512 MiB; max 2 GiB (applies to the full file) |
| `chunk_bytes` | no | Split threshold and part size; default 400 MiB, range 1 MiB..450 MiB. Larger files become one artifact per part + a manifest artifact ([chunked-transfers.md](./chunked-transfers.md)) |

## Planned (not implemented)

| type | Purpose |
| --- | --- |
| `apt` | Allowlisted Debian packages → relocatable sysroot |
| `oci-rootfs` | Image@digest → rootfs tar |
| `cargo-vendor` | Prefer [rust-sandbox-bridge](https://github.com/agustif/rust-sandbox-bridge) |
| `raw` | Maintainer-only `workflow_dispatch` path for trusted local files |

## Approval

Label: **`approved-transfer`** (write/maintain/admin only).

Success label: **`transfer-built`**.
