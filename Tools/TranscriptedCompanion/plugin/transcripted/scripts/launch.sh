#!/bin/bash
set -euo pipefail

PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$PLUGIN_DIR/server/transcripted-mcp"
MANIFEST="$PLUGIN_DIR/server/manifest.json"

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo "Transcripted requires an Apple Silicon Mac." >&2
  exit 1
fi
if [ ! -x "$HELPER" ] || [ -L "$HELPER" ] || [ ! -f "$MANIFEST" ] || [ -L "$MANIFEST" ]; then
  echo "Transcripted's plugin helper is missing. Rebuild or reinstall this plugin." >&2
  exit 1
fi
EXPECTED_HASH="$(/usr/bin/plutil -extract sha256 raw -o - "$MANIFEST")"
ACTUAL_HASH="$(/usr/bin/shasum -a 256 "$HELPER" | /usr/bin/awk '{print $1}')"
if [ "$EXPECTED_HASH" != "$ACTUAL_HASH" ]; then
  echo "Transcripted's plugin helper changed. Rebuild or reinstall this plugin." >&2
  exit 1
fi

export TRANSCRIPTED_DISABLE_FILE_LOGGER=1
export TRANSCRIPTED_MCP_COMPANION_MODE=1
exec "$HELPER" "$@"
