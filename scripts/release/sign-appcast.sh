#!/bin/bash
# Embed Sparkle's EdDSA feed signature in an appcast.xml.
#
# Usage: SPARKLE_PRIVATE_KEY=... bash scripts/release/sign-appcast.sh /path/to/appcast.xml
#
# Run this last. Any later edit to the file (including mark-appcast-critical.py
# or re-running generate-sparkle-appcast.sh) breaks the signature. The key is
# read from SPARKLE_PRIVATE_KEY and handed to sign_update on stdin, never
# written to disk or printed. Without the variable the key comes from the login
# keychain, which is the local-only path.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: bash scripts/release/sign-appcast.sh /path/to/appcast.xml"
    exit 1
fi

APPCAST_PATH="$1"
SPARKLE_SIGN_TOOL="${SPARKLE_SIGN_TOOL:-deps-tools/sparkle/bin/sign_update}"

if [ ! -x "$SPARKLE_SIGN_TOOL" ]; then
    echo "Sparkle sign_update is missing: $SPARKLE_SIGN_TOOL"
    echo "Run: bash scripts/release/fetch-sparkle-tools.sh (release job) or bash build-deps.sh --force"
    exit 1
fi

if [ ! -f "$APPCAST_PATH" ]; then
    echo "Appcast not found: $APPCAST_PATH"
    exit 1
fi

if [ "$(basename "$APPCAST_PATH")" != "appcast.xml" ]; then
    echo "The release asset must be named appcast.xml (got $(basename "$APPCAST_PATH"))."
    exit 1
fi

if [ -f "config/release/legacy-appcast-freeze.json" ] \
    && [ "$(cd "$(dirname "$APPCAST_PATH")" && pwd -P)/appcast.xml" = "$(pwd -P)/docs/appcast.xml" ]; then
    echo "docs/appcast.xml is the frozen legacy feed; do not sign it again."
    exit 1
fi

# A previous signature block would be signed over; start from the bare feed.
python3 - "$APPCAST_PATH" <<'PY'
import re
import sys

path = sys.argv[1]
text = open(path, encoding="utf-8").read()
stripped = re.sub(r"\n?<!-- sparkle-signatures:.*?-->\s*", "\n", text, flags=re.S).rstrip("\n") + "\n"
if stripped != text:
    open(path, "w", encoding="utf-8").write(stripped)
PY

if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGN_TOOL" --ed-key-file - "$APPCAST_PATH"
else
    "$SPARKLE_SIGN_TOOL" "$APPCAST_PATH"
fi

# sign_update embeds the signature as a trailing comment. Refuse to hand back a
# feed without it: an unsigned feed would still install, which is what this
# step exists to prevent.
if ! grep -q '<!-- sparkle-signatures:' "$APPCAST_PATH"; then
    echo "sign_update did not embed a feed signature in $APPCAST_PATH"
    exit 1
fi

# Read the signature back with the same key, so a half-written or tampered feed
# fails here and not on a user's Mac.
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    if ! printf '%s' "$SPARKLE_PRIVATE_KEY" | "$SPARKLE_SIGN_TOOL" --verify --ed-key-file - "$APPCAST_PATH" >/dev/null 2>&1; then
        echo "The embedded feed signature does not verify against the signing key."
        exit 1
    fi
fi

python3 - "$APPCAST_PATH" <<'PY'
import sys
import xml.etree.ElementTree as ET

try:
    ET.parse(sys.argv[1])
except ET.ParseError as exc:
    raise SystemExit(f"signed feed is not valid XML: {exc}")
PY

echo "Signed feed: $APPCAST_PATH"
