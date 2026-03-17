#!/bin/bash
# notarize.sh — Submit a DMG or ZIP to Apple for notarization and staple
# Usage: ./scripts/notarize.sh <file> <apple-id> <team-id> <app-password>

set -euo pipefail

FILE="${1:?Usage: notarize.sh <file> <apple-id> <team-id> <app-password>}"
APPLE_ID="${2:?Missing Apple ID}"
TEAM_ID="${3:?Missing Team ID}"
APP_PASSWORD="${4:?Missing app-specific password}"

echo "==> Submitting ${FILE} for notarization..."

# Submit for notarization and wait for result
xcrun notarytool submit "${FILE}" \
    --apple-id "${APPLE_ID}" \
    --team-id "${TEAM_ID}" \
    --password "${APP_PASSWORD}" \
    --wait

# Staple the notarization ticket (only works for DMG, not ZIP)
if [[ "${FILE}" == *.dmg ]]; then
    echo "==> Stapling notarization ticket..."
    xcrun stapler staple "${FILE}"
    echo "==> Notarization complete and stapled: ${FILE}"
else
    echo "==> Notarization complete (ZIP files cannot be stapled): ${FILE}"
fi
