#!/bin/bash

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: bash scripts/generate-sparkle-appcast.sh /path/to/updates-folder"
    exit 1
fi

UPDATES_DIR="$1"
SPARKLE_APPCAST_TOOL="deps-tools/sparkle/bin/generate_appcast"
REPO_APPCAST_PATH="docs/appcast.xml"

if [ ! -x "$SPARKLE_APPCAST_TOOL" ]; then
    echo "Sparkle tooling is missing."
    echo "Run: bash build-deps.sh --force"
    exit 1
fi

if [ ! -d "$UPDATES_DIR" ]; then
    echo "Updates folder not found: $UPDATES_DIR"
    exit 1
fi

"$SPARKLE_APPCAST_TOOL" "$UPDATES_DIR"

GENERATED_APPCAST="$UPDATES_DIR/appcast.xml"
if [ -f "$GENERATED_APPCAST" ]; then
    cp "$GENERATED_APPCAST" "$REPO_APPCAST_PATH"
fi

echo ""
echo "Appcast generated inside: $UPDATES_DIR"
if [ -f "$GENERATED_APPCAST" ]; then
    echo "Updated: $REPO_APPCAST_PATH"
else
    echo "Copy the generated appcast.xml contents into $REPO_APPCAST_PATH before pushing."
fi
