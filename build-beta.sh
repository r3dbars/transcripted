#!/bin/bash
# Build Draft for beta distribution
# Usage: ./build-beta.sh <beta-token> <user-name>
# Example: ./build-beta.sh draft-beta-nate Nate
#
# Prerequisites:
# - Developer ID Application certificate installed
# - Notarization credentials stored: xcrun notarytool store-credentials "Draft-Notarize" ...
# - brew install create-dmg

set -e

BETA_TOKEN="$1"
USER_NAME="${2:-beta}"

if [ -z "$BETA_TOKEN" ]; then
    echo "Usage: ./build-beta.sh <beta-token> <user-name>"
    echo "Example: ./build-beta.sh draft-beta-nate Nate"
    exit 1
fi

APP_NAME="Draft"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
DMG_NAME="Draft-${USER_NAME}.dmg"
SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
SIGNING_DISPLAY_NAME=""
NOTARY_PROFILE="${NOTARY_PROFILE:-draft-notary}"
BETA_CONFIG_PATH="Sources/API/BetaConfig.swift"
BETA_CONFIG_BACKUP="$(mktemp -t draft-beta-config)"

if [ -z "$SIGNING_IDENTITY" ]; then
    SIGNING_IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}')
    SIGNING_DISPLAY_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
else
    SIGNING_DISPLAY_NAME="$SIGNING_IDENTITY"
fi

echo "🔨 Building Draft Beta for $USER_NAME (token: $BETA_TOKEN)..."

# Clean app bundle only (preserve previously built DMGs)
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

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

# Create entitlements (hardened runtime compatible)
cat > "$BUILD_DIR/Draft.entitlements" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.speech.recognition</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
</dict>
</plist>
EOF

# Inject the user's beta token
echo "Injecting token for $USER_NAME..."
cp "$BETA_CONFIG_PATH" "$BETA_CONFIG_BACKUP"
trap 'mv "$BETA_CONFIG_BACKUP" "$BETA_CONFIG_PATH" 2>/dev/null || true' EXIT
sed -i '' "s/BETA_TOKEN_PLACEHOLDER/$BETA_TOKEN/" "$BETA_CONFIG_PATH"

# Unified dependency check
if [ ! -f "deps-libs/libDraftDeps.a" ] || [ ! -d "deps-modules" ]; then
    echo "❌ Dependencies not found — required for Parakeet STT + meeting diarization"
    echo "   Run build-deps.sh first to build dependencies."
    exit 1
fi
echo "Dependencies found"

DEPS_MODULE_FLAGS="-Ideps-modules"
for dir in deps-modules/*/; do
    [ -d "$dir" ] && DEPS_MODULE_FLAGS="$DEPS_MODULE_FLAGS -I$dir"
done
DEPS_FLAGS="$DEPS_MODULE_FLAGS -Ldeps-libs -lDraftDeps -framework CoreML -framework CoreAudio"

# MLX searches for mlx.metallib next to the binary first (Contents/MacOS/)
for metallib in deps-libs/*.metallib; do
    [ -f "$metallib" ] && cp "$metallib" "$APP_BUNDLE/Contents/MacOS/"
done

# Compile with BETA_BUILD flag
echo "Compiling (beta build)..."
SOURCE_FILES=$(find Sources -name '*.swift' -not -path 'Sources/TranscriptedCore/*')
swiftc \
    -O \
    -D BETA_BUILD \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
    -framework AVFoundation \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework Speech \
    -framework Security \
    -framework Carbon \
    -framework Metal \
    -framework MetalKit \
    -framework Accelerate \
    -framework Vision \
    -framework MetalPerformanceShaders \
    -framework MetalPerformanceShadersGraph \
    -lc++ \
    $DEPS_FLAGS \
    $SOURCE_FILES \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    2>&1

COMPILE_STATUS=$?

if [ $COMPILE_STATUS -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

# Sign with Developer ID + hardened runtime
if [ -z "$SIGNING_IDENTITY" ]; then
    echo "❌ No Developer ID Application certificate found."
    echo "   Set SIGNING_IDENTITY explicitly or install a Developer ID certificate."
    exit 1
fi

echo "Signing with: ${SIGNING_DISPLAY_NAME:-$SIGNING_IDENTITY}"
codesign --force --deep \
    --sign "$SIGNING_IDENTITY" \
    --options runtime \
    --timestamp \
    --entitlements "$BUILD_DIR/Draft.entitlements" \
    "$APP_BUNDLE" 2>&1

if [ $? -ne 0 ]; then
    echo "❌ Signing failed! Make sure you have a Developer ID Application certificate."
    echo "   Open Xcode → Settings → Accounts → Manage Certificates"
    exit 1
fi

# Create DMG
echo "Creating DMG..."
rm -f "$BUILD_DIR/$DMG_NAME"

# Check for custom background
DMG_BG_FLAGS=""
if [ -f "assets/dmg-background.png" ]; then
    DMG_BG_FLAGS="--background assets/dmg-background.png"
fi

create-dmg \
    --volname "Draft Beta" \
    --window-pos 200 120 \
    --window-size 600 400 \
    --icon-size 100 \
    --icon "Draft.app" 175 190 \
    --hide-extension "Draft.app" \
    --app-drop-link 425 190 \
    --no-internet-enable \
    $DMG_BG_FLAGS \
    "$BUILD_DIR/$DMG_NAME" \
    "$APP_BUNDLE" \
    2>&1 || true  # create-dmg returns non-zero on "already exists" even after rm

# Sign the DMG
echo "Signing DMG..."
codesign --force --timestamp --sign "$SIGNING_IDENTITY" "$BUILD_DIR/$DMG_NAME"

# Notarize (only with Developer ID — Apple Development certs can't be notarized)
if [[ "${SIGNING_DISPLAY_NAME:-$SIGNING_IDENTITY}" == Developer\ ID* ]]; then
    echo "Submitting for notarization (this takes 1-5 minutes)..."
    xcrun notarytool submit "$BUILD_DIR/$DMG_NAME" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    # Staple
    echo "Stapling notarization ticket..."
    xcrun stapler staple "$BUILD_DIR/$DMG_NAME"
else
    echo "⚠️  Skipping notarization (using development cert — local testing only)"
fi

echo ""
echo "✅ Done! DMG ready: $BUILD_DIR/$DMG_NAME"
echo "   Size: $(du -sh "$BUILD_DIR/$DMG_NAME" | cut -f1)"
echo "   Token: $BETA_TOKEN"
echo "   User: $USER_NAME"
