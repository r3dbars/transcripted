#!/bin/bash

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: bash scripts/release/verify-sparkle-release.sh <version>"
    echo "Example: bash scripts/release/verify-sparkle-release.sh 1.1.25"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
APPCAST_PATH="docs/appcast.xml"
DMG_NAME="Transcripted-${VERSION}.dmg"
EXPECTED_URL="https://github.com/r3dbars/transcripted/releases/download/${TAG}/${DMG_NAME}"
EXPECTED_MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)"
EXPECTED_HARDWARE_REQUIREMENTS="arm64"

if [ ! -f "$APPCAST_PATH" ]; then
    echo "Missing appcast: $APPCAST_PATH"
    exit 1
fi

if ! command -v gh >/dev/null 2>&1; then
    echo "Missing gh CLI."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "Missing python3."
    exit 1
fi

echo "Checking GitHub release ${TAG}..."
gh release view "$TAG" --repo r3dbars/transcripted >/dev/null

echo "Checking release asset URL..."
curl -fsSIL --retry 3 "$EXPECTED_URL" >/dev/null

echo "Checking Info.plist Sparkle settings..."
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" Info.plist | grep -F "docs/appcast.xml" >/dev/null
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Info.plist | grep -E ".{20,}" >/dev/null
/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" Info.plist | grep -F "true" >/dev/null
/usr/libexec/PlistBuddy -c "Print :SUAllowsAutomaticUpdates" Info.plist | grep -F "true" >/dev/null

echo "Checking appcast entry..."
python3 - "$APPCAST_PATH" "$VERSION" "$EXPECTED_URL" "$EXPECTED_MINIMUM_SYSTEM_VERSION" "$EXPECTED_HARDWARE_REQUIREMENTS" <<'PY'
import sys
import xml.etree.ElementTree as ET

appcast_path, version, expected_url, expected_minimum_system_version, expected_hardware_requirements = sys.argv[1:6]
namespaces = {
    "sparkle": "http://www.andymatuschak.org/xml-namespaces/sparkle",
}

root = ET.parse(appcast_path).getroot()
items = root.findall("./channel/item")
if not items:
    raise SystemExit("appcast has no items")

item = items[0]
enclosure = item.find("enclosure")
if enclosure is None:
    raise SystemExit("latest appcast item is missing enclosure")

url = enclosure.attrib.get("url", "")
if url != expected_url:
    raise SystemExit(f"latest appcast URL mismatch:\n  got: {url}\n  want: {expected_url}")

signature = enclosure.attrib.get(f"{{{namespaces['sparkle']}}}edSignature", "")
if not signature:
    raise SystemExit("latest appcast item is missing sparkle:edSignature")

length = enclosure.attrib.get("length", "")
if not length.isdigit() or int(length) <= 0:
    raise SystemExit("latest appcast item has invalid length")

version_fields = [
    item.findtext("title") or "",
    item.findtext("sparkle:shortVersionString", namespaces=namespaces) or "",
    item.findtext("sparkle:version", namespaces=namespaces) or "",
]
if not any(version in field for field in version_fields):
    raise SystemExit(f"latest appcast item does not mention version {version}")

minimum_system_version = item.findtext("sparkle:minimumSystemVersion", namespaces=namespaces) or ""
if minimum_system_version != expected_minimum_system_version:
    raise SystemExit(
        "latest appcast minimumSystemVersion mismatch:\n"
        f"  got: {minimum_system_version}\n"
        f"  want: {expected_minimum_system_version}"
    )

hardware_requirements = item.findtext("sparkle:hardwareRequirements", namespaces=namespaces) or ""
if hardware_requirements != expected_hardware_requirements:
    raise SystemExit(
        "latest appcast hardwareRequirements mismatch:\n"
        f"  got: {hardware_requirements}\n"
        f"  want: {expected_hardware_requirements}"
    )
PY

echo "Sparkle release verified for ${TAG}."
