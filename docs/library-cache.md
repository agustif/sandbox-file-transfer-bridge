# Library cache conventions

After a transfer artifact reaches `/mnt/data`, optionally store it in ChatGPT Library
so later sandboxes can re-materialize without re-downloading from Actions.

## Suggested identity

```text
/SandboxCache/transfer/<request_sha256>/
  manifest.json
  transfer-payload.tar.gz
  SHA256SUMS
```

Or by human name + content hash:

```text
/SandboxCache/transfer/<name>/<output_sha256>/
```

## Client flow

1. Compute desired `request_sha256` (or known `output_sha256`).
2. Search Library for an exact match.
3. Materialize → `sha256sum -c SHA256SUMS`.
4. On miss: download Actions artifact → verify → optional Library upload (user opt-in).

Never skip hash verification after materialization.
Never select a cache entry with wrong `kind` / arch / schema.
