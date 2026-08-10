#!/usr/bin/env bash
# Discover recent successful transfer artifacts via gh.
#
# Usage:
#   ./scripts/discover-artifacts.sh
#   BRIDGE_REPO=owner/name ./scripts/discover-artifacts.sh
set -euo pipefail

REPO=${BRIDGE_REPO:-agustif/sandbox-file-transfer-bridge}

if ! command -v gh >/dev/null 2>&1; then
  echo "error: gh CLI required" >&2
  exit 1
fi

echo "repo=$REPO"
echo "=== latest successful transfer runs ==="
gh api \
  "repos/$REPO/actions/workflows/build-transfer.yml/runs?status=success&per_page=10" \
  --jq '.workflow_runs[:10][] | {id, created_at, html_url, display_title}'

LATEST=$(gh api \
  "repos/$REPO/actions/workflows/build-transfer.yml/runs?status=success&per_page=1" \
  --jq '.workflow_runs[0].id // empty')

if [[ -n "$LATEST" ]]; then
  echo "=== artifacts on run $LATEST ==="
  gh api "repos/$REPO/actions/runs/$LATEST/artifacts" \
    --jq '.artifacts[] | {name, size_in_bytes, expired, expires_at, id}'
fi
