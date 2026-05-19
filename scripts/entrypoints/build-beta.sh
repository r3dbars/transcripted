#!/bin/bash
# Build Transcripted for beta distribution
# Usage: ./build-beta.sh <beta-token> <user-name>
# Example: ./build-beta.sh transcripted-beta-nate Nate
#
# Prerequisites:
# - Developer ID Application certificate installed
# - Notarization credentials stored locally via xcrun notarytool
# - NOTARY_PROFILE set to the local keychain profile name for notarytool
# - optional: brew install create-dmg for the fastest DMG layout path

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

BETA_TOKEN="${1:-}"
USER_NAME="${2:-beta}"

# BETA_TOKEN is retained as a positional arg for backwards-compatible invocations,
# but it is no longer injected into the app binary — the app no longer has a beta
# proxy client. Builds without a token are fine. See Sources/Beta/BetaConfig.swift
# for the rationale.
SKIP_NOTARIZATION="${SKIP_NOTARIZATION:-0}"
REQUIRE_BUNDLED_PARAKEET_MODELS="${REQUIRE_BUNDLED_PARAKEET_MODELS:-1}"
BUNDLE_PARAKEET_MODELS="${BUNDLE_PARAKEET_MODELS:-1}"
REGISTER_SENTRY_RELEASE="${REGISTER_SENTRY_RELEASE:-0}"
SWIFTC_NUM_THREADS="${SWIFTC_NUM_THREADS:-$(sysctl -n hw.ncpu 2>/dev/null || printf '8')}"
SENTRY_METADATA="$(python3 scripts/release/sentry-release-metadata.py --format shell Info.plist)"
eval "$SENTRY_METADATA"

if [ -n "$BETA_TOKEN" ]; then
    echo "ℹ️  BETA_TOKEN passed but no longer injected into the binary. Continuing."
fi

if [ -z "$APP_VERSION" ]; then
    echo "❌ Could not read CFBundleShortVersionString from Info.plist"
    exit 1
fi

if [ "$BUNDLE_PARAKEET_MODELS" = "0" ] && [ "$REQUIRE_BUNDLED_PARAKEET_MODELS" != "0" ]; then
    echo "❌ BUNDLE_PARAKEET_MODELS=0 requires REQUIRE_BUNDLED_PARAKEET_MODELS=0"
    echo "   Distribution builds bundle Parakeet by default so first launch does not"
    echo "   depend on a runtime model download."
    echo "   If you intentionally want a thin local test build, rerun with:"
    echo "   REQUIRE_BUNDLED_PARAKEET_MODELS=0 BUNDLE_PARAKEET_MODELS=0 bash build-beta.sh <beta-token> <user-name>"
    exit 1
fi

APP_NAME="Transcripted"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
STAGED_APP_BINARY="$BUILD_DIR/$APP_NAME-beta-bin"
DMG_NAME="Transcripted-${APP_VERSION}.dmg"
DMG_VOLUME_NAME="Transcripted"
DMG_WINDOW_WIDTH=960
DMG_WINDOW_HEIGHT=640
DMG_ICON_SIZE=144
DMG_TEXT_SIZE=16
DMG_APP_ICON_X=220
DMG_APP_ICON_Y=340
DMG_APPLICATIONS_ICON_X=740
DMG_APPLICATIONS_ICON_Y=340
DMG_BACKGROUND_PATH="scripts/release/assets/dmg-background.png"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-${SIGN_IDENTITY:-}}"
SIGNING_DISPLAY_NAME=""
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
BETA_ENTITLEMENTS="config/entitlements/beta.plist"
DEPS_BUILD_STAMP="deps-libs/.build-deps-stamp"
DEPS_FRAMEWORK_ROOT="deps-frameworks"
ESPEAK_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/ESpeakNG.framework"
SENTRY_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/Sentry.framework"
SPARKLE_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/Sparkle.framework"
TRANSCRIPTED_CORE_MODULE="deps-modules/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
ARGMAX_CORE_MODULE="deps-modules/ArgmaxCore.swiftmodule/arm64-apple-macos.swiftmodule"
WHISPERKIT_MODULE="deps-modules/WhisperKit.swiftmodule/arm64-apple-macos.swiftmodule"
MCP_PACKAGE_DIR="Tools/TranscriptedMCP"
MCP_BINARY="$MCP_PACKAGE_DIR/.build/release/transcripted-mcp"
BUNDLED_MCP_BINARY="$APP_BUNDLE/Contents/Helpers/transcripted-mcp"

dependency_input_listing() {
    {
        printf '%s\n' "Package.swift"
        printf '%s\n' "scripts/entrypoints/build-deps.sh"
        find "Sources/TranscriptedCore" -type f ! -name "CLAUDE.md"
    } | while IFS= read -r path; do
        [ -e "$path" ] || continue
        printf '%s\t%s\n' "$(stat -f '%m' "$path")" "$path"
    done
}

newest_dependency_input() {
    dependency_input_listing | awk 'NR == 1 || $1 > max { max = $1; line = $0 } END { if (line != "") print line }'
}

deps_build_stamp_info() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        printf '%s\t%s\n' "$(stat -f '%m' "$DEPS_BUILD_STAMP")" "$DEPS_BUILD_STAMP"
    fi
}

mask_secret() {
    local value="$1"

    if [ -z "$value" ]; then
        printf '%s' "[redacted]"
        return
    fi

    local length=${#value}
    if [ "$length" -le 6 ]; then
        printf '%s' "[redacted]"
        return
    fi

    printf '%s...%s' "${value:0:4}" "${value: -2}"
}

validate_signed_app() {
    echo "Validating app signature..."
    codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
    codesign -dvvv --entitlements - "$APP_BUNDLE"
}

validate_notarized_artifacts() {
    echo "Validating Gatekeeper acceptance..."
    spctl -a -t exec -vv "$APP_BUNDLE"
    xcrun stapler validate "$BUILD_DIR/$DMG_NAME"

    local dmg_check_output
    if dmg_check_output="$(spctl -a -t open -vv "$BUILD_DIR/$DMG_NAME" 2>&1)"; then
        printf '%s\n' "$dmg_check_output"
        return 0
    fi

    printf '%s\n' "$dmg_check_output"
    if printf '%s' "$dmg_check_output" | grep -q "source=Insufficient Context"; then
        echo "⚠️  DMG open assessment returned Insufficient Context after stapling."
        echo "   Treating stapler validation as the source of truth for the signed disk image."
        return 0
    fi

    return 1
}

create_finder_layout_dmg() {
    local output_path="$1"
    local staging_dir="$BUILD_DIR/dmg-staging"
    local rw_dmg="$BUILD_DIR/${DMG_NAME%.dmg}-layout.dmg"
    local staging_size_mb
    local image_size_mb
    local attach_output
    local device
    local mount_dir
    local background_alias_line=""

    echo "ℹ️  create-dmg not found — using built-in Finder layout fallback"

    rm -rf "$staging_dir"
    rm -f "$rw_dmg"
    mkdir -p "$staging_dir"
    cp -R "$APP_BUNDLE" "$staging_dir/"
    ln -s /Applications "$staging_dir/Applications"

    if [ -f "$DMG_BACKGROUND_PATH" ]; then
        mkdir -p "$staging_dir/.background"
        cp "$DMG_BACKGROUND_PATH" "$staging_dir/.background/dmg-background.png"
        chflags hidden "$staging_dir/.background" || true
    fi

    staging_size_mb="$(du -sm "$staging_dir" | awk '{print $1}')"
    image_size_mb=$((staging_size_mb + 160))

    hdiutil create \
        -srcfolder "$staging_dir" \
        -volname "$DMG_VOLUME_NAME" \
        -fs HFS+ \
        -format UDRW \
        -size "${image_size_mb}m" \
        "$rw_dmg" >/dev/null

    if [ -d "/Volumes/$DMG_VOLUME_NAME" ]; then
        hdiutil detach "/Volumes/$DMG_VOLUME_NAME" -force >/dev/null 2>&1 || true
    fi

    attach_output="$(
        hdiutil attach \
        -readwrite \
        -noverify \
        -noautoopen \
        "$rw_dmg"
    )"
    device="$(printf '%s\n' "$attach_output" | awk '/Apple_HFS/ {print $1; exit}')"
    mount_dir="$(printf '%s\n' "$attach_output" | awk '/Apple_HFS/ {$1=""; $2=""; sub(/^  +/, ""); print; exit}')"

    if [ -f "$mount_dir/.background/dmg-background.png" ]; then
        background_alias_line="set background picture of viewOptions to (POSIX file \"$mount_dir/.background/dmg-background.png\" as alias)"
    fi

    bless --folder "$mount_dir" --openfolder "$mount_dir" >/dev/null 2>&1 || true

    if ! osascript <<EOF >/dev/null
tell application "Finder"
    tell disk "$DMG_VOLUME_NAME"
        open
        delay 1
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, $((200 + DMG_WINDOW_WIDTH)), $((120 + DMG_WINDOW_HEIGHT))}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to $DMG_ICON_SIZE
        set text size of viewOptions to $DMG_TEXT_SIZE
        $background_alias_line
        set position of item "$APP_NAME.app" of container window to {$DMG_APP_ICON_X, $DMG_APP_ICON_Y}
        set position of item "Applications" of container window to {$DMG_APPLICATIONS_ICON_X, $DMG_APPLICATIONS_ICON_Y}
        update without registering applications
        delay 1
        close
        open
        delay 1
    end tell
end tell
EOF
    then
        hdiutil detach "$device" -force >/dev/null 2>&1 || true
        return 1
    fi

    sync
    hdiutil detach "$device" >/dev/null

    hdiutil convert \
        "$rw_dmg" \
        -format UDZO \
        -imagekey zlib-level=9 \
        -o "$output_path" >/dev/null

    rm -f "$rw_dmg"
    rm -rf "$staging_dir"
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
    local helper_path

    while IFS= read -r -d '' nested_code_path; do
        if [ "$sign_hash" = "-" ]; then
            codesign --force --sign "$sign_hash" "$nested_code_path"
        else
            codesign --force \
                --sign "$sign_hash" \
                --options runtime \
                --timestamp \
                --preserve-metadata=identifier,entitlements,requirements \
                "$nested_code_path"
        fi
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

    for helper_path in "$APP_BUNDLE"/Contents/Helpers/*; do
        [ -f "$helper_path" ] || continue
        if [ "$sign_hash" = "-" ]; then
            codesign --force --sign "$sign_hash" "$helper_path"
        else
            codesign --force \
                --sign "$sign_hash" \
                --options runtime \
                --timestamp \
                "$helper_path"
        fi
    done
}

bundle_mcp_server() {
    echo "Building Transcripted MCP server..."
    swift build -c release --package-path "$MCP_PACKAGE_DIR"

    if [ ! -x "$MCP_BINARY" ]; then
        echo "❌ MCP build finished without a runnable binary: $MCP_BINARY"
        exit 1
    fi

    cp "$MCP_BINARY" "$BUNDLED_MCP_BINARY"
    chmod 755 "$BUNDLED_MCP_BINARY"
}

if [ ! -f "$BETA_ENTITLEMENTS" ]; then
    echo "❌ Missing entitlements file: $BETA_ENTITLEMENTS"
    exit 1
fi

if [ ! -f "deps-libs/libDraftDeps.a" ] || [ ! -f "$DEPS_BUILD_STAMP" ] || [ ! -d "deps-modules" ] || [ ! -f "$TRANSCRIPTED_CORE_MODULE" ] || [ ! -f "$ARGMAX_CORE_MODULE" ] || [ ! -f "$WHISPERKIT_MODULE" ] || [ ! -d "$ESPEAK_FRAMEWORK" ] || [ ! -d "$SENTRY_FRAMEWORK" ] || [ ! -d "$SPARKLE_FRAMEWORK" ]; then
    echo "❌ Dependencies missing or stale — required for beta builds"
    echo "   Missing stamp: $DEPS_BUILD_STAMP"
    echo "   Missing module: $TRANSCRIPTED_CORE_MODULE"
    echo "   Missing module: $ARGMAX_CORE_MODULE"
    echo "   Missing module: $WHISPERKIT_MODULE"
    echo "   Missing framework: $ESPEAK_FRAMEWORK"
    echo "   Missing framework: $SENTRY_FRAMEWORK"
    echo "   Missing framework: $SPARKLE_FRAMEWORK"
    echo "   Run build-deps.sh --force first to rebuild dependencies."
    exit 1
fi

newest_input="$(newest_dependency_input)"
build_stamp="$(deps_build_stamp_info)"
IFS=$'\t' read -r newest_input_mtime newest_input_path <<< "$newest_input"
IFS=$'\t' read -r build_stamp_mtime build_stamp_path <<< "$build_stamp"

if [ -n "${newest_input_mtime:-}" ] && [ -n "${build_stamp_mtime:-}" ] && [ "$newest_input_mtime" -gt "$build_stamp_mtime" ]; then
    echo "❌ Dependencies are stale for TranscriptedCore."
    echo "   Newest input: $newest_input_path"
    echo "   Built deps stamp: $build_stamp_path"
    echo "   Run build-deps.sh --force first to rebuild dependencies."
    exit 1
fi

echo "🔨 Building Transcripted Beta for $USER_NAME (token: $(mask_secret "$BETA_TOKEN"))..."
echo "Sentry metadata: release=$SENTRY_RELEASE dist=$SENTRY_DIST"

# Clean app bundle only (preserve previously built DMGs)
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"
mkdir -p "$APP_BUNDLE/Contents/Helpers"

# Bundle Parakeet CoreML models
PARAKEET_SRC="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml"
if [ "$BUNDLE_PARAKEET_MODELS" = "0" ]; then
    echo "⚠️  Skipping bundled Parakeet models because BUNDLE_PARAKEET_MODELS=0"
    echo "   Runtime model download may occur on first launch."
elif [ -d "$PARAKEET_SRC/Encoder.mlmodelc" ]; then
    echo "Bundling Parakeet models..."
    mkdir -p "$APP_BUNDLE/Contents/Resources/parakeet-models"
    cp -R "$PARAKEET_SRC" "$APP_BUNDLE/Contents/Resources/parakeet-models/"
else
    if [ "$REQUIRE_BUNDLED_PARAKEET_MODELS" = "0" ]; then
        echo "⚠️  Parakeet models not found — proceeding because REQUIRE_BUNDLED_PARAKEET_MODELS=0"
        echo "   Runtime model download may still occur on first launch."
    else
        echo "❌ Missing local Parakeet models: $PARAKEET_SRC"
        echo "   build-beta.sh now requires bundled Parakeet models by default so"
        echo "   distribution builds do not fall back to a runtime download on first launch."
        echo "   If you intentionally want a thin local test build, rerun with:"
        echo "   REQUIRE_BUNDLED_PARAKEET_MODELS=0 BUNDLE_PARAKEET_MODELS=0 bash build-beta.sh <beta-token> <user-name>"
        exit 1
    fi
fi

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Copy bundled app resources (custom sounds, etc.) when present
if [ -d "Resources" ]; then
    cp -R Resources/. "$APP_BUNDLE/Contents/Resources/"
fi

bundle_mcp_server

# Unified dependencies (FluidAudio + mlx-swift-lm + WhisperKit)
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
echo "Swift compiler threads: $SWIFTC_NUM_THREADS"
SOURCE_FILES=$(find Sources -name '*.swift' -not -path 'Sources/TranscriptedCore/*')
rm -f "$STAGED_APP_BINARY"
swiftc \
    -O \
    -whole-module-optimization \
    -num-threads "$SWIFTC_NUM_THREADS" \
    -D BETA_BUILD \
    -o "$STAGED_APP_BINARY" \
    -framework AVFoundation \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework EventKit \
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
    -target arm64-apple-macos26.0 \
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

echo "Checking performance budget..."
PERFORMANCE_BUDGET_ARGS=(--app "$APP_BUNDLE")
if [ "$BUNDLE_PARAKEET_MODELS" = "0" ]; then
    PERFORMANCE_BUDGET_ARGS+=(--allow-missing-parakeet-model --max-app-mb 220 --max-resources-mb 80)
fi
scripts/ops/performance-budget.rb "${PERFORMANCE_BUDGET_ARGS[@]}"

# Create DMG
echo "Creating DMG..."
rm -f "$BUILD_DIR/$DMG_NAME"

if command -v create-dmg >/dev/null 2>&1; then
    DMG_BG_FLAGS=()
    if [ -f "$DMG_BACKGROUND_PATH" ]; then
        DMG_BG_FLAGS+=(--background "$DMG_BACKGROUND_PATH")
    fi

    create-dmg \
        --volname "$DMG_VOLUME_NAME" \
        --window-pos 200 120 \
        --window-size "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT" \
        --icon-size "$DMG_ICON_SIZE" \
        --icon "$APP_NAME.app" "$DMG_APP_ICON_X" "$DMG_APP_ICON_Y" \
        --hide-extension "$APP_NAME.app" \
        --app-drop-link "$DMG_APPLICATIONS_ICON_X" "$DMG_APPLICATIONS_ICON_Y" \
        --no-internet-enable \
        "${DMG_BG_FLAGS[@]}" \
        "$BUILD_DIR/$DMG_NAME" \
        "$APP_BUNDLE" \
        2>&1 || true
else
    create_finder_layout_dmg "$BUILD_DIR/$DMG_NAME"
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

if [ "$REGISTER_SENTRY_RELEASE" = "1" ]; then
    echo "Registering Sentry release..."
    bash scripts/release/register-sentry-release.sh "$APP_VERSION"
fi

echo ""
echo "✅ Done! DMG ready: $BUILD_DIR/$DMG_NAME"
echo "   Size: $(du -sh "$BUILD_DIR/$DMG_NAME" | cut -f1)"
echo "   User: $USER_NAME"
echo "   Sentry release: $SENTRY_RELEASE"
echo "   Sentry dist: $SENTRY_DIST"
if [ "$REGISTER_SENTRY_RELEASE" != "1" ]; then
    echo "   Sentry registration: bash scripts/release/register-sentry-release.sh $APP_VERSION"
fi
if [ "$SKIP_NOTARIZATION" = "1" ] || [[ ! "$SIGNING_DISPLAY_NAME" == Developer\ ID* ]]; then
    echo "   Note: this build is not notarized yet, so Gatekeeper rejection is still expected."
else
    echo "   Note: notarized downloads still show the standard macOS first-open confirmation once."
fi
echo "   If this build should update existing installs, regenerate docs/appcast.xml after you upload the DMG."
