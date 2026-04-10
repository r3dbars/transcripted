#!/bin/bash
# Build Transcripted - local dictation + meeting transcription app

APP_NAME="Transcripted"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building Transcripted..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Bundle Parakeet CoreML models
PARAKEET_SRC="$HOME/Library/Application Support/FluidAudio/Models/parakeet-tdt-0.6b-v3-coreml"
if [ -d "$PARAKEET_SRC/Encoder.mlmodelc" ]; then
    echo "Bundling Parakeet models..."
    mkdir -p "$APP_BUNDLE/Contents/Resources/parakeet-models"
    cp -R "$PARAKEET_SRC" "$APP_BUNDLE/Contents/Resources/parakeet-models/"
else
    echo "Parakeet models not found — Parakeet engine will attempt runtime download"
fi

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Copy bundled app resources (custom sounds, etc.) when present
if [ -d "Resources" ]; then
    cp -R Resources/. "$APP_BUNDLE/Contents/Resources/"
fi

# Create entitlements
cat > "$BUILD_DIR/Transcripted.entitlements" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.device.audio-capture</key>
    <true/>
    <key>com.apple.security.speech.recognition</key>
    <true/>
</dict>
</plist>
EOF

# Unified dependencies (FluidAudio + mlx-swift-lm)
# Run build-deps.sh first to build these artifacts
if [ ! -f "deps-libs/libDraftDeps.a" ] || [ ! -d "deps-modules" ]; then
    echo "Dependencies not found — required for Parakeet STT + meeting diarization"
    echo "   Run build-deps.sh first to build dependencies."
    exit 1
fi
echo "Dependencies found"

# Build the -I flags for all module directories
DEPS_MODULE_FLAGS="-Ideps-modules"
for dir in deps-modules/*/; do
    [ -d "$dir" ] && DEPS_MODULE_FLAGS="$DEPS_MODULE_FLAGS -I$dir"
done

DEPS_FLAGS="$DEPS_MODULE_FLAGS -Ldeps-libs -lDraftDeps -framework CoreML -framework CoreAudio"

# Bundle Metal libraries if present
# MLX searches for mlx.metallib next to the binary first (Contents/MacOS/)
for metallib in deps-libs/*.metallib; do
    [ -f "$metallib" ] && cp "$metallib" "$APP_BUNDLE/Contents/MacOS/"
done

# Compile
echo "Compiling..."
SOURCE_FILES=$(find Sources -name '*.swift' -not -path 'Sources/TranscriptedCore/*')
swiftc \
    -O \
    -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
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
    -lc++ \
    $DEPS_FLAGS \
    $SOURCE_FILES \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    2>&1

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Sign — auto-detect the first valid Developer ID on this machine.
# We extract the SHA-1 hash (not the name) because the same cert may exist in
# both System.keychain and login.keychain, which makes name-based lookup
# ambiguous and silently fails codesign — leaving the binary ad-hoc signed and
# wiping TCC permissions on every rebuild. Hashes are unambiguous.
SIGN_HASH=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | awk '{print $2}')
SIGN_NAME=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -n "$SIGN_HASH" ]; then
    echo "Signing with: $SIGN_NAME ($SIGN_HASH)"
    if ! codesign --force --deep --sign "$SIGN_HASH" \
        --entitlements "$BUILD_DIR/Transcripted.entitlements" \
        "$APP_BUNDLE"; then
        echo "Codesign failed — aborting build"
        exit 1
    fi
else
    echo "No Developer ID found — signing ad-hoc (permissions may not persist)"
    codesign --force --deep --sign - \
        --entitlements "$BUILD_DIR/Transcripted.entitlements" \
        "$APP_BUNDLE" 2>&1
fi

# Verify the signature took — catches silent codesign failures that would
# otherwise leave behind a linker-stamped ad-hoc binary.
if codesign -dv "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
    if [ -n "$SIGN_HASH" ]; then
        echo "WARNING: expected Developer ID signature but binary is ad-hoc — permissions will reset on each build"
    fi
fi

echo "Build complete!"
echo "Launching Transcripted..."
open "$APP_BUNDLE"
