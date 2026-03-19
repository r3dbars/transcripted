#!/bin/bash
# create-dmg.sh — Package Transcripted.app into a drag-to-install DMG
# Usage: ./scripts/create-dmg.sh [path/to/Transcripted.app] [output/dir]

set -euo pipefail

APP_PATH="${1:?Usage: create-dmg.sh <app-path> [output-dir]}"
OUTPUT_DIR="${2:-.}"
APP_NAME="Transcripted"
DMG_NAME="${APP_NAME}.dmg"
VOLUME_NAME="${APP_NAME}"
STAGING_DIR=$(mktemp -d)

echo "==> Creating DMG from ${APP_PATH}"

# Verify app exists
if [ ! -d "${APP_PATH}" ]; then
    echo "ERROR: ${APP_PATH} does not exist"
    exit 1
fi

# Extract version from app bundle
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "${APP_PATH}/Contents/Info.plist")
DMG_NAME="${APP_NAME}-${VERSION}.dmg"
echo "    Version: ${VERSION}"

# Set up staging directory with app and Applications symlink
cp -R "${APP_PATH}" "${STAGING_DIR}/${APP_NAME}.app"
ln -s /Applications "${STAGING_DIR}/Applications"

# Create temporary DMG
TEMP_DMG="${STAGING_DIR}/temp.dmg"
hdiutil create -volname "${VOLUME_NAME}" \
    -srcfolder "${STAGING_DIR}" \
    -ov -format UDRW \
    "${TEMP_DMG}"

# Convert to compressed read-only DMG
FINAL_DMG="${OUTPUT_DIR}/${DMG_NAME}"
hdiutil convert "${TEMP_DMG}" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -o "${FINAL_DMG}"

# Clean up
rm -rf "${STAGING_DIR}"

echo "==> DMG created: ${FINAL_DMG}"
echo "    Size: $(du -h "${FINAL_DMG}" | cut -f1)"
