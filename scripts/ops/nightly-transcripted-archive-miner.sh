#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

python3 scripts/ops/build-codex-memory-index.py \
  --since-hours 24 \
  --nightly-report \
  "$@"
