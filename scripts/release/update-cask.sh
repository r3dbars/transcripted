#!/bin/bash
# Update Casks/transcripted.rb to point at a published GitHub release.
#
# Given a version, this fetches the matching release DMG, computes its
# sha256, and rewrites the cask's `version` and `sha256` fields in place.
# Run it after publishing a new release so the Homebrew tap tracks the
# latest artifact.

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: bash scripts/release/update-cask.sh <version>"
    echo "Example: bash scripts/release/update-cask.sh 1.1.11"
    exit 1
fi

VERSION="$1"
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CASK_PATH="$REPO_ROOT/Casks/transcripted.rb"
DMG_URL="https://github.com/r3dbars/transcripted/releases/download/v${VERSION}/Transcripted-${VERSION}.dmg"

if [ ! -f "$CASK_PATH" ]; then
    echo "Cask file not found: $CASK_PATH"
    exit 1
fi

TMP_DMG="$(mktemp -t transcripted-cask-XXXXXX.dmg)"
trap 'rm -f "$TMP_DMG"' EXIT

echo "Fetching $DMG_URL"
if ! curl --fail --location --silent --show-error --output "$TMP_DMG" "$DMG_URL"; then
    echo "Failed to download release asset for v${VERSION}."
    echo "Confirm the release was published at:"
    echo "  https://github.com/r3dbars/transcripted/releases/tag/v${VERSION}"
    exit 1
fi

SHA256="$(shasum -a 256 "$TMP_DMG" | awk '{print $1}')"
echo "sha256: $SHA256"

# Rewrite the first `version` and `sha256` lines in the cask block.
python3 - "$CASK_PATH" "$VERSION" "$SHA256" <<'PY'
import re
import sys

path, version, sha256 = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path, "r", encoding="utf-8") as fh:
    text = fh.read()

text, n_version = re.subn(
    r'(?m)^(\s*version\s+)"[^"]*"',
    rf'\g<1>"{version}"',
    text,
    count=1,
)
text, n_sha = re.subn(
    r'(?m)^(\s*sha256\s+)"[^"]*"',
    rf'\g<1>"{sha256}"',
    text,
    count=1,
)

if n_version != 1 or n_sha != 1:
    sys.stderr.write(
        f"Could not locate version/sha256 lines in {path} "
        f"(version matches={n_version}, sha256 matches={n_sha}).\n"
    )
    sys.exit(1)

with open(path, "w", encoding="utf-8") as fh:
    fh.write(text)
PY

echo "Updated $CASK_PATH to version $VERSION."
