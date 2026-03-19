#!/bin/bash
# release.sh — Build, sign, notarize, and publish a release locally
# Usage: ./scripts/release.sh <version>
# Example: ./scripts/release.sh 0.1.0
#
# Prerequisites:
#   - Developer ID certificate in keychain
#   - APPLE_ID, APPLE_TEAM_ID, APPLE_APP_PASSWORD env vars (or stored in .env)
#   - SPARKLE_PRIVATE_KEY env var (for Sparkle EdDSA signing)
#   - gh CLI authenticated

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
APP_NAME="Transcripted"
SCHEME="Transcripted"
BUNDLE_ID="com.transcripted.app"

# --- Parse version ---
VERSION="${1:?Usage: release.sh <version> (e.g. 0.1.0)}"
TAG="v${VERSION}"
echo "==> Releasing ${APP_NAME} ${TAG}"

# --- Load .env if present ---
if [ -f "${PROJECT_DIR}/.env" ]; then
    echo "    Loading .env"
    set -a
    source "${PROJECT_DIR}/.env"
    set +a
fi

# --- Check prerequisites ---
echo "==> Checking prerequisites..."

if ! command -v gh &>/dev/null; then
    echo "ERROR: gh CLI not found. Install with: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "ERROR: gh not authenticated. Run: gh auth login"
    exit 1
fi

: "${APPLE_ID:?Set APPLE_ID env var or add to .env}"
: "${APPLE_TEAM_ID:?Set APPLE_TEAM_ID env var or add to .env}"
: "${APPLE_APP_PASSWORD:?Set APPLE_APP_PASSWORD env var or add to .env}"

# Check signing identity exists
if ! security find-identity -v -p codesigning | grep -q "Developer ID Application"; then
    echo "ERROR: No Developer ID Application certificate found in keychain"
    exit 1
fi

# --- Ensure working tree is clean ---
if [ -n "$(git -C "${PROJECT_DIR}" status --porcelain)" ]; then
    echo "ERROR: Working tree has uncommitted changes. Commit or stash first."
    exit 1
fi

# --- Build ---
echo "==> Building ${APP_NAME} ${VERSION} (Release, arm64)..."
BUILD_DIR="${PROJECT_DIR}/build-release"
rm -rf "${BUILD_DIR}"

xcodebuild -project "${PROJECT_DIR}/${APP_NAME}.xcodeproj" \
    -scheme "${SCHEME}" \
    -configuration Release \
    -derivedDataPath "${BUILD_DIR}" \
    -destination "generic/platform=macOS" \
    ARCHS=arm64 \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="Developer ID Application" \
    DEVELOPMENT_TEAM="${APPLE_TEAM_ID}" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
    MARKETING_VERSION="${VERSION}" \
    CURRENT_PROJECT_VERSION="${VERSION}" \
    | tail -5

APP_PATH=$(find "${BUILD_DIR}/Build/Products/Release" -name "*.app" -maxdepth 1 | head -1)
if [ -z "${APP_PATH}" ] || [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: Build succeeded but .app not found"
    exit 1
fi
echo "    App: ${APP_PATH}"

# --- Re-sign embedded frameworks and helpers ---
echo "==> Re-signing embedded binaries with Developer ID + hardened runtime..."
SIGN_IDENTITY="7AC6EF5E8D58DD881DF96F173B2CD3DC41273A44"

# Sign all nested binaries inside Sparkle framework (XPC services, helpers)
find "${APP_PATH}/Contents/Frameworks" -type f -perm +111 -o -name "*.dylib" | while read -r binary; do
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${binary}" 2>/dev/null || true
done

# Sign XPC services and .app bundles inside frameworks
find "${APP_PATH}/Contents/Frameworks" -name "*.xpc" -o -name "*.app" | while read -r bundle; do
    codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${bundle}" 2>/dev/null || true
done

# Sign the Sparkle framework itself
find "${APP_PATH}/Contents/Frameworks" -name "*.framework" | while read -r framework; do
    codesign --force --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${framework}" 2>/dev/null || true
done

# Re-sign the main app (picks up everything)
codesign --force --deep --options runtime --timestamp --sign "${SIGN_IDENTITY}" "${APP_PATH}"
echo "    Signing verified: $(codesign -dv "${APP_PATH}" 2>&1 | grep 'Authority='| head -1)"

# --- Create output directory ---
OUTPUT_DIR="${PROJECT_DIR}/release-${VERSION}"
rm -rf "${OUTPUT_DIR}"
mkdir -p "${OUTPUT_DIR}"

# --- Create ZIP (for Sparkle updates) ---
echo "==> Creating ZIP..."
ZIP_FILE="${OUTPUT_DIR}/${APP_NAME}-${VERSION}.zip"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${ZIP_FILE}"
echo "    ZIP: $(du -h "${ZIP_FILE}" | cut -f1)"

# --- Create DMG (for website download) ---
echo "==> Creating DMG..."
"${SCRIPT_DIR}/create-dmg.sh" "${APP_PATH}" "${OUTPUT_DIR}"
DMG_FILE=$(ls "${OUTPUT_DIR}"/*.dmg | head -1)
echo "    DMG: $(du -h "${DMG_FILE}" | cut -f1)"

# --- Notarize ---
echo "==> Notarizing ZIP..."
xcrun notarytool submit "${ZIP_FILE}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait

echo "==> Notarizing DMG..."
xcrun notarytool submit "${DMG_FILE}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${APPLE_TEAM_ID}" \
    --password "${APPLE_APP_PASSWORD}" \
    --wait

# Staple the DMG
xcrun stapler staple "${DMG_FILE}"
echo "    DMG stapled"

# --- Sparkle EdDSA signing ---
SPARKLE_SIGNATURE=""
SPARKLE_LENGTH=""
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
    echo "==> Signing ZIP with Sparkle EdDSA..."

    # Download Sparkle tools if needed
    SPARKLE_BIN="/tmp/sparkle-tools/bin/sign_update"
    if [ ! -f "${SPARKLE_BIN}" ]; then
        SPARKLE_VERSION="2.8.0"
        mkdir -p /tmp/sparkle-tools
        curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz" | tar xJ -C /tmp/sparkle-tools
    fi

    SIGN_OUTPUT=$(echo "${SPARKLE_PRIVATE_KEY}" | "${SPARKLE_BIN}" "${ZIP_FILE}" --ed-key-file -)
    SPARKLE_SIGNATURE=$(echo "${SIGN_OUTPUT}" | grep 'sparkle:edSignature' | sed 's/.*"\(.*\)".*/\1/')
    SPARKLE_LENGTH=$(wc -c < "${ZIP_FILE}" | tr -d ' ')
    echo "    Signature: ${SPARKLE_SIGNATURE:0:20}..."
else
    echo "==> Skipping Sparkle signing (SPARKLE_PRIVATE_KEY not set)"
fi

# --- Clean up build artifacts ---
rm -rf "${BUILD_DIR}"

# --- Git tag ---
echo "==> Tagging ${TAG}..."
git -C "${PROJECT_DIR}" tag -d "${TAG}" 2>/dev/null || true
git -C "${PROJECT_DIR}" push origin ":refs/tags/${TAG}" 2>/dev/null || true
git -C "${PROJECT_DIR}" tag "${TAG}"
git -C "${PROJECT_DIR}" push origin main
git -C "${PROJECT_DIR}" push origin "${TAG}"

# --- GitHub Release ---
echo "==> Creating GitHub release..."
gh release create "${TAG}" \
    --repo r3dbars/transcripted \
    --title "${APP_NAME} ${TAG}" \
    --generate-notes \
    "${DMG_FILE}" \
    "${ZIP_FILE}"

echo "    Release: https://github.com/r3dbars/transcripted/releases/tag/${TAG}"

# --- Update webapp (appcast + DMG) ---
echo "==> Updating webapp..."
WEBAPP_DIR="/Users/redbars/redbars/code/transcripted-webapp"

if [ -d "${WEBAPP_DIR}" ]; then
    # Copy DMG for direct download
    cp "${DMG_FILE}" "${WEBAPP_DIR}/public/download/Transcripted.dmg"

    # Update appcast if we have a Sparkle signature
    if [ -n "${SPARKLE_SIGNATURE}" ]; then
        ZIP_URL="https://github.com/r3dbars/transcripted/releases/download/${TAG}/${APP_NAME}-${VERSION}.zip"
        DATE=$(date -u +"%a, %d %b %Y %H:%M:%S %z")

        python3 << PYEOF
import os
version = "${VERSION}"
date = "${DATE}"
zip_url = "${ZIP_URL}"
sig = "${SPARKLE_SIGNATURE}"
length = "${SPARKLE_LENGTH}"

item = f"""    <item>
        <title>Version {version}</title>
        <pubDate>{date}</pubDate>
        <sparkle:version>{version}</sparkle:version>
        <sparkle:shortVersionString>{version}</sparkle:shortVersionString>
        <sparkle:minimumSystemVersion>14.2</sparkle:minimumSystemVersion>
        <description><![CDATA[<h2>What's New in {version}</h2><p>See full release notes on GitHub.</p>]]></description>
        <enclosure
          url="{zip_url}"
          sparkle:edSignature="{sig}"
          length="{length}"
          type="application/octet-stream" />
      </item>"""

appcast = open("${WEBAPP_DIR}/public/appcast.xml").read()
appcast = appcast.replace("</channel>", item + "\n  </channel>")
open("${WEBAPP_DIR}/public/appcast.xml", "w").write(appcast)
print(f"    Updated appcast.xml with v{version}")
PYEOF
    fi

    # Commit and push webapp
    cd "${WEBAPP_DIR}"
    git add public/download/Transcripted.dmg public/appcast.xml
    git commit -m "release: ${TAG} — update DMG + appcast"
    git push origin main
    echo "    Webapp pushed (Cloudflare will deploy)"
else
    echo "    WARNING: Webapp repo not found at ${WEBAPP_DIR}, skipping"
fi

# --- Done ---
echo ""
echo "==> Release ${TAG} complete!"
echo "    GitHub:  https://github.com/r3dbars/transcripted/releases/tag/${TAG}"
echo "    Website: https://transcripted.app/download/Transcripted.dmg (after Cloudflare deploys)"
echo "    Output:  ${OUTPUT_DIR}/"
