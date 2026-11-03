#!/bin/bash
# Download Sparkle's command-line tools (generate_appcast, sign_update) into
# deps-tools/sparkle/bin, checked against the sha256 pinned in build-deps.sh.
#
# The signing job of the Release Candidate workflow uses this instead of
# build-deps.sh: it holds the release secrets, so it must not run the build
# scripts or execute tools another job produced. Only the pinned, hash-checked
# upstream archive is trusted here.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

PIN_SOURCE="scripts/entrypoints/build-deps.sh"
SPARKLE_VERSION="$(sed -n 's/^SPARKLE_VERSION="${SPARKLE_VERSION:-\([^}]*\)}"$/\1/p' "$PIN_SOURCE" | head -1)"
SPARKLE_SHA256="$(sed -n 's/^SPARKLE_SHA256="${SPARKLE_SHA256:-\([^}]*\)}"$/\1/p' "$PIN_SOURCE" | head -1)"
if [ -z "$SPARKLE_VERSION" ] || ! [[ "$SPARKLE_SHA256" =~ ^[0-9a-f]{64}$ ]]; then
    echo "Could not read the pinned Sparkle version and sha256 from $PIN_SOURCE"
    exit 1
fi

DEST="deps-tools/sparkle"
if [ -x "$DEST/bin/generate_appcast" ] && [ -x "$DEST/bin/sign_update" ]; then
    echo "Sparkle tools already present in $DEST/bin"
    exit 0
fi

work="$(mktemp -d "${TMPDIR:-/tmp}/transcripted-sparkle-tools.XXXXXX")"
trap 'rm -rf "$work"' EXIT

url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
echo "Downloading Sparkle $SPARKLE_VERSION tools..."
curl -fsSL --retry 3 "$url" -o "$work/sparkle.zip"
actual="$(shasum -a 256 "$work/sparkle.zip" | awk '{print $1}')"
if [ "$actual" != "$SPARKLE_SHA256" ]; then
    echo "Sparkle archive checksum mismatch (got $actual, pinned $SPARKLE_SHA256)"
    exit 1
fi

unzip -q "$work/sparkle.zip" -d "$work/unpacked"
mkdir -p "$DEST"
ditto "$work/unpacked/bin" "$DEST/bin"
chmod +x "$DEST/bin/generate_appcast" "$DEST/bin/sign_update"
echo "Sparkle tools ready in $DEST/bin"
