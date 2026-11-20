#!/bin/bash

set -euo pipefail

if [ $# -ne 1 ]; then
    echo "Usage: bash scripts/release/verify-sparkle-release.sh <version>"
    echo "Example: bash scripts/release/verify-sparkle-release.sh 1.1.25"
    exit 1
fi

VERSION="$1"
TAG="v${VERSION}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# Without a file, follow the same release-asset redirect installed apps use.
# With a file, verify an unpublished candidate without contacting GitHub.
FEED_URL="https://github.com/r3dbars/transcripted/releases/latest/download/appcast.xml"
APPCAST_PATH="${VERIFY_APPCAST_FILE:-}"
INFO_PLIST="${VERIFY_INFO_PLIST:-$REPO_ROOT/Info.plist}"
FETCHED_FEED=""
DELTA_URLS_FILE=""
trap 'rm -f "$DELTA_URLS_FILE" "$FETCHED_FEED"' EXIT
DMG_NAME="Transcripted-${VERSION}.dmg"
EXPECTED_URL="https://github.com/r3dbars/transcripted/releases/download/${TAG}/${DMG_NAME}"
EXPECTED_MINIMUM_SYSTEM_VERSION="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "$INFO_PLIST")"
EXPECTED_HARDWARE_REQUIREMENTS="arm64"

if [ -z "$APPCAST_PATH" ]; then
    if ! command -v gh >/dev/null 2>&1; then
        echo "Missing gh CLI."
        exit 1
    fi
    FETCHED_FEED="$(mktemp "${TMPDIR:-/tmp}/transcripted-appcast.XXXXXX")"
    APPCAST_PATH="$FETCHED_FEED"
    echo "Fetching the live feed..."
    curl -fsSL --retry 3 "$FEED_URL" -o "$APPCAST_PATH"
elif [ ! -f "$APPCAST_PATH" ]; then
    echo "Missing appcast: $APPCAST_PATH"
    exit 1
fi

echo "Checking Info.plist Sparkle settings..."
/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$INFO_PLIST" | grep -Fx "$FEED_URL" >/dev/null
/usr/libexec/PlistBuddy -c "Print :SUVerifyUpdateBeforeExtraction" "$INFO_PLIST" | grep -Fx "true" >/dev/null
/usr/libexec/PlistBuddy -c "Print :SUEnableAutomaticChecks" "$INFO_PLIST" | grep -Fx "true" >/dev/null
/usr/libexec/PlistBuddy -c "Print :SUAllowsAutomaticUpdates" "$INFO_PLIST" | grep -Fx "true" >/dev/null

echo "Checking feed signature..."
PUBLIC_KEY="$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$INFO_PLIST")"
node "$REPO_ROOT/scripts/release/verify-sparkle-appcast.mjs" "$APPCAST_PATH" "$PUBLIC_KEY"

echo "Checking appcast entry..."
DELTA_URLS_FILE="$(mktemp "${TMPDIR:-/tmp}/transcripted-delta-urls.XXXXXX")"
python3 - "$APPCAST_PATH" "$VERSION" "$EXPECTED_URL" "$EXPECTED_MINIMUM_SYSTEM_VERSION" "$EXPECTED_HARDWARE_REQUIREMENTS" > "$DELTA_URLS_FILE" <<'PY'
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

# Delta updates are optional, but each one listed must be signed and hosted
# on this release next to the DMG. The shell HEAD-checks the printed URLs.
delta_prefix = expected_url.rsplit("/", 1)[0] + "/"
for delta in item.findall("sparkle:deltas/enclosure", namespaces):
    from_version = delta.attrib.get(f"{{{namespaces['sparkle']}}}deltaFrom", "")
    delta_url = delta.attrib.get("url", "")
    want = f"{delta_prefix}Transcripted{version}-{from_version}.delta"
    if not from_version or delta_url != want:
        raise SystemExit(f"delta URL mismatch:\n  got: {delta_url}\n  want: {want}")
    if not delta.attrib.get(f"{{{namespaces['sparkle']}}}edSignature", ""):
        raise SystemExit(f"delta from {from_version} is missing sparkle:edSignature")
    delta_length = delta.attrib.get("length", "")
    if not delta_length.isdigit() or int(delta_length) <= 0:
        raise SystemExit(f"delta from {from_version} has invalid length")
    print(delta_url)
PY

if [ -z "$FETCHED_FEED" ]; then
    echo "Sparkle candidate appcast verified offline for ${TAG}."
    exit 0
fi

echo "Checking GitHub release ${TAG}..."
gh release view "$TAG" --repo r3dbars/transcripted >/dev/null

echo "Checking release asset URL..."
curl -fsSIL --retry 3 "$EXPECTED_URL" >/dev/null

if [ -s "$DELTA_URLS_FILE" ]; then
    echo "Checking delta update assets..."
    while IFS= read -r delta_url; do
        curl -fsSIL --retry 3 "$delta_url" >/dev/null
        echo "  ok: ${delta_url##*/}"
    done < "$DELTA_URLS_FILE"
else
    echo "No delta updates in this release; every client downloads the full DMG."
fi

echo "Sparkle release verified for ${TAG}."
