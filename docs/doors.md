# Sandbox doors

Same model as the Rust bridge: **getting bytes across the wall** is the hard part.

```text
                         OUTSIDE WORLD
                              │
                 GitHub Actions (has internet)
                              │
                    transfer artifact ZIP
                              │
                    ChatGPT GitHub connector
                              │
                          /mnt/data
                              │
                           SANDBOX
                    (unpack / install / run)
```

| Door | Role |
| --- | --- |
| **This repo (Actions artifacts)** | Primary large-binary ingress for arbitrary approved files; files > 400 MiB are split into < 512 MiB part artifacts ([chunked-transfers.md](./chunked-transfers.md)) |
| ChatGPT Library | Persistent cache after first successful pull |
| Internal mirrors (`pip`/`npm`) | Prefer when mirrored — no bridge needed |
| `container.download` | Opportunistic; MIME limits often reject archives |
| Human upload | Last resort |

This repository does **not** compile or run requester software on GitHub.
It only packages **inert** bytes after maintainer approval.
