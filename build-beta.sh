#!/bin/bash
# Keep the familiar root command while the implementation lives under scripts/entrypoints.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec "$SCRIPT_DIR/scripts/entrypoints/build-beta.sh" "$@"
