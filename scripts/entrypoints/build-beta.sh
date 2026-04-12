#!/bin/bash
# Build Transcripted for beta distribution
# Usage: ./build-beta.sh <beta-token> <user-name>
# Example: ./build-beta.sh transcripted-beta-nate Nate
#
# Prerequisites:
# - Developer ID Application certificate installed
# - Notarization credentials stored locally via xcrun notarytool
# - NOTARY_PROFILE set to the local keychain profile name for notarytool
# - optional: brew install create-dmg for the custom DMG layout

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

BETA_TOKEN="${1:-}"
USER_NAME="${2:-beta}"
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"

if [ -z "$BETA_TOKEN" ]; then
    echo "Usage: ./build-beta.sh <beta-token> <user-name>"
    echo "Example: ./build-beta.sh transcripted-beta-nate Nate"
    exit 1
fi

APP_NAME="Transcripted"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
STAGED_APP_BINARY="$BUILD_DIR/$APP_NAME-beta-bin"
DMG_NAME="Transcripted-${USER_NAME}.dmg"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${SIGN_IDENTITY:-}}"
SIGNING_DISPLAY_NAME=""
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BETA_CONFIG_PATH="Sources/Beta/BetaConfig.swift"
BETA_CONFIG_BACKUP="$(mktemp -t transcripted-beta-config)"
BETA_ENTITLEMENTS="config/entitlements/beta.plist"
DEPS_FRAMEWORK_ROOT="deps-frameworks"
ESPEAK_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/ESpeakNG.framework"
SENTRY_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/Sentry.framework"
SPARKLE_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/Sparkle.framework"
TRANSCRIPTED_CORE_MODULE="deps-modules/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"

validate_signed_app() {
    echo "Validating app signature..."
    codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
    codesign -dvvv --entitlements - "$APP_BUNDLE"
}

validate_notarized_artifacts() {
    echo "Validating Gatekeeper acceptance..."
    spctl -a -t exec -vv "$APP_BUNDLE"
    spctl -a -t open -vv "$BUILD_DIR/$DMG_NAME"
}

resolve_sign_identity() {
    local requested_identity="$1"
    local found_line

    if [ -n "$requested_identity" ]; then
        found_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$requested_identity" | head -1 || true)"
        if [ -z "$found_line" ]; then
            echo "❌ Requested signing identity not found: $requested_identity"
            echo "Available identities:"
            security find-identity -v -p codesigning || true
            exit 1
        fi
        printf '%s\n' "$found_line"
        return 0
    fi

    security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 || true
}

sign_embedded_payloads() {
    local sign_hash="$1"
    local framework_path
    local metallib_path
    local nested_code_path

    while IFS= read -r -d '' nested_code_path; do
        codesign --force --sign "$sign_hash" "$nested_code_path"
    done < <(
        find "$APP_BUNDLE/Contents/Frameworks" \
            \( -path "*/Sparkle.framework/Versions/*/Updater.app" \
            -o -path "*/Sparkle.framework/Versions/*/XPCServices/*.xpc" \
            -o -path "*/Sparkle.framework/Versions/*/Autoupdate" \) \
            -print0 | sort -z
    )

    for framework_path in "$APP_BUNDLE"/Contents/Frameworks/*.framework; do
        [ -d "$framework_path" ] || continue
        codesign --force --sign "$sign_hash" "$framework_path"
    done

    for metallib_path in "$APP_BUNDLE"/Contents/MacOS/*.metallib; do
        [ -f "$metallib_path" ] || continue
        codesign --force --sign "$sign_hash" "$metallib_path"
    done
}

cleanup() {
    if [ -f "$BETA_CONFIG_BACKUP" ]; then
        cp "$BETA_CONFIG_BACKUP" "$BETA_CONFIG_PATH"
        rm -f "$BETA_CONFIG_BACKUP"
    fi
}

trap cleanup EXIT

if [ ! -f "$BETA_ENTITLEMENTS" ]; then
    echo "❌ Missing entitlements file: $BETA_ENTITLEMENTS"
    exit 1
fi

if [ ! -f "deps-libs/libDraftDeps.a" ] || [ ! -d "deps-modules" ] || [ ! -f "$TRANSCRIPTED_CORE_MODULE" ] || [ ! -d "$ESPEAK_FRAMEWORK" ] || [ ! -d "$SENTRY_FRAMEWORK" ] || [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "❌ Dependencies missing or stale — required for beta builds"
    echo "   Missing module: $TRANSCRIPTED_CORE_MODULE"
    echo "   Missing framework: $ESPEAK_FRAMEWORK"
    echo "   Missing framework: $SENTRY_FRAMEWORK"
    echo "   Missing framework: $SPARKLE_FRAMEWORK"
    echo "   Run build-deps.sh --force first to rebuild dependencies."
    exit 1
fi

echo "🔨 Building Transcripted Beta for $USER_NAME (token: $BETA_TOKEN)..."

# Clean app bundle only (preserve previously built DMGs)
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Bundle Parakeet CoreML models
PARAKEET_SRC="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml"
if [ -d "$PARAKEET_SRC/Encoder.mlmodelc" ]; then
    echo "Bundling Parakeet models..."
    mkdir -p "$APP_BUNDLE/Contents/Resources/parakeet-models"
    cp -R "$PARAKEET_SRC" "$APP_BUNDLE/Contents/Resources/parakeet-models/"
else
    echo "⚠️  Parakeet models not found — Parakeet engine will attempt runtime download"
fi

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Copy bundled app resources (custom sounds, etc.) when present
if [ -d "Resources" ]; then
    cp -R Resources/. "$APP_BUNDLE/Contents/Resources/"
fi

# Inject the user's beta token after dependency preflight succeeds.
echo "Injecting token for $USER_NAME..."
cp "$BETA_CONFIG_PATH" "$BETA_CONFIG_BACKUP"
sed -i '' "s/BETA_TOKEN_PLACEHOLDER/$BETA_TOKEN/" "$BETA_CONFIG_PATH"

# Unified dependencies (FluidAudio + mlx-swift-lm)
echo "Dependencies found"

DEPS_MODULE_FLAGS="-Ideps-modules"
for dir in deps-modules/*/; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in
        *.swiftmodule) continue ;;
    esac
    DEPS_MODULE_FLAGS="$DEPS_MODULE_FLAGS -I$dir"
done

DEPS_FLAGS="$DEPS_MODULE_FLAGS -F$DEPS_FRAMEWORK_ROOT -Ldeps-libs -lDraftDeps -framework ESpeakNG -framework CoreML -framework CoreAudio"

# Bundle Metal libraries if present
for metallib in deps-libs/*.metallib; do
    [ -f "$metallib" ] && cp "$metallib" "$APP_BUNDLE/Contents/MacOS/"
done

cp -R "$ESPEAK_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
cp -R "$SENTRY_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"
cp -R "$SPARKLE_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"

# Compile with BETA_BUILD flag
echo "Compiling (beta build)..."
SOURCE_FILES=$(find Sources -name '*.swift' -not -path 'Sources/TranscriptedCore/*')
rm -f "$STAGED_APP_BINARY"
swiftc \
    -O \
    -D BETA_BUILD \
    -o "$STAGED_APP_BINARY" \
    -framework AVFoundation \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework EventKit \
    -framework Speech \
    -framework Security \
    -framework Carbon \
    -framework Metal \
    -framework MetalKit \
    -framework Accelerate \
    -framework Vision \
    -framework MetalPerformanceShaders \
    -framework MetalPerformanceShadersGraph \
    -framework Sentry \
    -framework Sparkle \
    -lsqlite3 \
    -lc++ \
    $DEPS_FLAGS \
    $SOURCE_FILES \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    2>&1

mv "$STAGED_APP_BINARY" "$APP_BINARY"

if [ ! -x "$APP_BINARY" ]; then
    echo "❌ Build finished without a runnable app binary: $APP_BINARY"
    exit 1
fi

SIGNING_MATCH="$(resolve_sign_identity "$SIGNING_IDENTITY")"
if [ -n "$SIGNING_MATCH" ]; then
    SIGNING_IDENTITY="$(echo "$SIGNING_MATCH" | awk '{print $2}')"
    SIGNING_DISPLAY_NAME="$(echo "$SIGNING_MATCH" | sed 's/.*"\(.*\)"/\1/')"
fi

if [ -n "$SIGNING_IDENTITY" ]; then
    echo "Signing with: ${SIGNING_DISPLAY_NAME:-$SIGNING_IDENTITY}"
    sign_embedded_payloads "$SIGNING_IDENTITY"
    if ! codesign --force \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$BETA_ENTITLEMENTS" \
        "$APP_BUNDLE" 2>&1; then
        echo "❌ Signing failed! Make sure you have a valid Developer ID Application certificate."
        echo "   Open Xcode → Settings → Accounts → Manage Certificates"
        exit 1
    fi
else
    echo "⚠️  No Developer ID found — signing ad-hoc for local smoke testing"
    sign_embedded_payloads "-"
    codesign --force \
        --sign - \
        --entitlements "$BETA_ENTITLEMENTS" \
        "$APP_BUNDLE" 2>&1
fi

validate_signed_app

# Create DMG
echo "Creating DMG..."
rm -f "$BUILD_DIR/$DMG_NAME"

if command -v create-dmg >/dev/null 2>&1; then
    # Check for custom background
    DMG_BG_FLAGS=""
    if [ -f "assets/dmg-background.png" ]; then
        DMG_BG_FLAGS="--background assets/dmg-background.png"
    fi

    create-dmg \
        --volname "Transcripted Beta" \
        --window-pos 200 120 \
        --window-size 600 400 \
        --icon-size 100 \
        --icon "Transcripted.app" 175 190 \
        --hide-extension "Transcripted.app" \
        --app-drop-link 425 190 \
        --no-internet-enable \
        $DMG_BG_FLAGS \
        "$BUILD_DIR/$DMG_NAME" \
        "$APP_BUNDLE" \
        2>&1 || true
else
    echo "⚠️  create-dmg not found — using hdiutil fallback"
    STAGING_DIR="$BUILD_DIR/dmg-staging"
    rm -rf "$STAGING_DIR"
    mkdir -p "$STAGING_DIR"
    cp -R "$APP_BUNDLE" "$STAGING_DIR/"
    ln -s /Applications "$STAGING_DIR/Applications"
    hdiutil create \
        -volname "Transcripted Beta" \
        -srcfolder "$STAGING_DIR" \
        -ov \
        -format UDZO \
        "$BUILD_DIR/$DMG_NAME" 2>&1
    rm -rf "$STAGING_DIR"
fi

if [ ! -f "$BUILD_DIR/$DMG_NAME" ]; then
    echo "❌ DMG creation failed!"
    exit 1
fi

# Sign the DMG
if [ -n "$SIGNING_IDENTITY" ]; then
    echo "Signing DMG..."
    codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$BUILD_DIR/$DMG_NAME"
else
    echo "⚠️  Skipping DMG signature (no Developer ID available)"
fi

# Notarize (only with Developer ID — Apple Development certs can't be notarized)
if [ "$SKIP_NOTARIZATION" = "1" ]; then
    echo "⚠️  Skipping notarization (SKIP_NOTARIZATION=1)"
    echo "   Expect Gatekeeper to reject the Developer ID app until it is notarized."
elif [[ "$SIGNING_DISPLAY_NAME" == Developer\ ID* ]]; then
    if [ -z "$NOTARY_PROFILE" ]; then
        echo "❌ NOTARY_PROFILE is not set."
        echo "   Store credentials with: xcrun notarytool store-credentials <profile-name> ..."
        echo "   Then run: NOTARY_PROFILE=<profile-name> ./build-beta.sh <beta-token> <user-name>"
        exit 1
    fi

    echo "Submitting for notarization (this takes 1-5 minutes)..."
    xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    echo "Stapling notarization ticket..."
    xcrun stapler staple "$BUILD_DIR/$DMG_NAME"
    validate_notarized_artifacts
else
    echo "⚠️  Skipping notarization (using development cert — local testing only)"
fi

echo ""
echo "✅ Done! DMG ready: $BUILD_DIR/$DMG_NAME"
echo "   Size: $(du -sh "$BUILD_DIR/$DMG_NAME" | cut -f1)"
echo "   Token: $BETA_TOKEN"
echo "   User: $USER_NAME"
