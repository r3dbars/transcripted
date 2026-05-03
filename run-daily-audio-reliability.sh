#!/bin/bash
# Keep the familiar root command while the implementation lives under scripts/ops.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/scripts/ops/daily-audio-reliability-check.sh" "$@"
