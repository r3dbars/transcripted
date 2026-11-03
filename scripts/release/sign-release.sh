#!/bin/bash
# Sign an unsigned Transcripted.app, build the DMG and sign it.
#
# Usage: bash scripts/release/sign-release.sh --app build/Transcripted.app --version 1.2.3
#
# This is the signing half of the Release Candidate workflow. The build half
# (`TRANSCRIPTED_UNSIGNED_APP_ONLY=1 bash build-beta.sh`) runs in a job with no
# secrets and uploads the unsigned app; the job that holds the Developer ID
# certificate runs this script on it. It compiles nothing and runs none of the
# build scripts. It needs a Developer ID Application identity in the keychain
# and refuses to fall back to ad-hoc signing. It does not notarize; the
# workflow does that next.
#
# It shares lib/release-package.sh with build-beta.sh, so a shipped build is
# signed and packaged by the same functions as a local one.

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../entrypoints" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

APP_INPUT=""
VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --app) APP_INPUT="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        *) echo "Unknown argument: $1"; echo "Usage: bash scripts/release/sign-release.sh --app <Transcripted.app> --version <x.y.z>"; exit 1 ;;
    esac
done

if [ -z "$APP_INPUT" ] || [ -z "$VERSION" ]; then
    echo "Usage: bash scripts/release/sign-release.sh --app <Transcripted.app> --version <x.y.z>"
    exit 1
fi
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must be numeric semver, got: $VERSION"
    exit 1
fi
if [ ! -d "$APP_INPUT" ]; then
    echo "App bundle not found: $APP_INPUT"
    exit 1
fi

APP_NAME="Transcripted"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="Transcripted-${VERSION}.dmg"
DMG_VOLUME_NAME="Transcripted"
TRANSCRIPTED_HEADLESS_PACKAGE_SMOKE=0
SIGNING_DISPLAY_NAME=""

source "$ENTRYPOINT_DIR/lib/release-package.sh"

mkdir -p "$BUILD_DIR"
if [ "$(cd "$APP_INPUT" && pwd -P)" != "$(cd "$BUILD_DIR" && pwd -P)/$APP_NAME.app" ]; then
    rm -rf "$APP_BUNDLE"
    ditto "$APP_INPUT" "$APP_BUNDLE"
fi

bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")"
bundle_build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_BUNDLE/Contents/Info.plist")"
if [ "$bundle_version" != "$VERSION" ] || [ "$bundle_build" != "$VERSION" ]; then
    echo "App bundle is $bundle_version ($bundle_build), not the requested $VERSION."
    exit 1
fi

SIGNING_MATCH="$(resolve_sign_identity "${SIGNING_IDENTITY:-Developer ID Application}")"
if [ -z "$SIGNING_MATCH" ]; then
    echo "No Developer ID Application identity is available; refusing to ship an ad-hoc signed build."
    exit 1
fi
SIGNING_IDENTITY="$(echo "$SIGNING_MATCH" | awk '{print $2}')"
SIGNING_DISPLAY_NAME="$(echo "$SIGNING_MATCH" | sed 's/.*"\(.*\)"/\1/')"
case "$SIGNING_DISPLAY_NAME" in
    "Developer ID Application"*) ;;
    *) echo "Signing identity is not a Developer ID Application certificate."; exit 1 ;;
esac

sign_app_bundle "$SIGNING_IDENTITY"
validate_signed_app

create_release_dmg
sign_release_dmg "$SIGNING_IDENTITY"

echo ""
echo "Signed: $APP_BUNDLE and $BUILD_DIR/$DMG_NAME (not notarized yet)"
