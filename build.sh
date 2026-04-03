#!/bin/bash
# Build Draft - minimal voice-to-text utility

APP_NAME="Draft"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "Building Draft..."

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

# Bundle Parakeet EOU streaming model (live transcription display)
# DownloadUtils nests inside the cache dir as <folderName>/, so check both possible paths
EOU_SRC="$HOME/Library/Application Support/FluidAudio/Models/parakeet-eou-streaming/320ms"
if [ -d "$EOU_SRC/streaming_encoder.mlmodelc" ]; then
    true  # use as-is
elif [ -d "$EOU_SRC/parakeet-eou-streaming/320ms/streaming_encoder.mlmodelc" ]; then
    EOU_SRC="$EOU_SRC/parakeet-eou-streaming/320ms"
fi
if [ -d "$EOU_SRC/streaming_encoder.mlmodelc" ]; then
    echo "Bundling Parakeet EOU streaming model..."
    mkdir -p "$APP_BUNDLE/Contents/Resources/parakeet-models/parakeet-eou-120m-coreml"
    cp -R "$EOU_SRC/"* "$APP_BUNDLE/Contents/Resources/parakeet-models/parakeet-eou-120m-coreml/"
else
    echo "Parakeet EOU model not found — will attempt runtime download"
fi

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Create entitlements
cat > "$BUILD_DIR/Draft.entitlements" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <false/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.speech.recognition</key>
    <true/>
</dict>
</plist>
EOF

# Unified dependencies (FluidAudio + mlx-swift-lm)
# Run build-deps.sh first to build these artifacts
if [ ! -f "deps-libs/libDraftDeps.a" ] || [ ! -d "deps-modules" ]; then
    echo "Dependencies not found — required for Parakeet STT + local LLM inference"
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
swiftc \
    -O \
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
    $(find Sources -name '*.swift') \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    2>&1

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Sign — auto-detect the first valid Developer ID on this machine
SIGN_ID=$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 | sed 's/.*"\(.*\)"/\1/')
if [ -n "$SIGN_ID" ]; then
    echo "Signing with: $SIGN_ID"
    codesign --force --deep --sign "$SIGN_ID" \
        --entitlements "$BUILD_DIR/Draft.entitlements" \
        "$APP_BUNDLE" 2>&1
else
    echo "No Developer ID found — signing ad-hoc (permissions may not persist)"
    codesign --force --deep --sign - \
        --entitlements "$BUILD_DIR/Draft.entitlements" \
        "$APP_BUNDLE" 2>&1
fi

echo "Build complete!"
echo "Launching Draft..."
open "$APP_BUNDLE"
