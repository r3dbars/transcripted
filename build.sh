#!/bin/bash
# Build Draft - minimal voice-to-text utility

APP_NAME="Draft"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building Draft..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Bundle Whisper model
MODEL_SRC="$HOME/Library/Application Support/Draft/models/ggml-large-v3-turbo-q5_0.bin"
if [ -f "$MODEL_SRC" ]; then
    echo "Bundling Whisper model..."
    mkdir -p "$APP_BUNDLE/Contents/Resources/models"
    cp "$MODEL_SRC" "$APP_BUNDLE/Contents/Resources/models/"
else
    echo "⚠️  Whisper model not found at $MODEL_SRC"
    echo "   Run build-whisper.sh first to download the model."
fi

# Bundle Parakeet CoreML models (if downloaded)
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

# Create entitlements
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
</dict>
</plist>
EOF

# FluidAudio (optional — Parakeet STT engine)
# Run build-fluidaudio.sh first to build these artifacts
FLUID_FLAGS=""
if [ -f "fluidaudio-libs/libFluidAudioAll.a" ] && [ -d "fluidaudio-modules/FluidAudio.swiftmodule" ]; then
    echo "FluidAudio found — enabling Parakeet engine"
    FLUID_FLAGS="-DPARAKEET_AVAILABLE -Ifluidaudio-modules -Ifluidaudio-modules/FastClusterWrapper -Ifluidaudio-modules/MachTaskSelfWrapper -Ifluidaudio-modules/yyjson -Lfluidaudio-libs -lFluidAudioAll -framework CoreML -framework CoreAudio"
else
    echo "FluidAudio not found — Whisper only (run build-fluidaudio.sh to enable Parakeet)"
fi

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
    -lsqlite3 \
    -lc++ \
    -Iinclude \
    -Llibs \
    -lwhisper -lggml-base -lggml-cpu -lggml-metal -lggml-blas -lggml \
    -import-objc-header Sources/Speech/WhisperBridge.h \
    $FLUID_FLAGS \
    $(find Sources -name '*.swift') \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    2>&1

if [ $? -ne 0 ]; then
    echo "❌ Build failed!"
    exit 1
fi

# Sign
echo "Signing..."
codesign --force --deep --sign "Apple Development: r3dbars (LZRN6W4R74)" \
    --entitlements "$BUILD_DIR/Draft.entitlements" \
    "$APP_BUNDLE" 2>&1

echo "✅ Build complete!"
echo "Launching Draft..."
open "$APP_BUNDLE"
