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
codesign --force --deep --sign "Apple Development: Justin Betker (LZRN6W4R74)" \
    --entitlements "$BUILD_DIR/Draft.entitlements" \
    "$APP_BUNDLE" 2>&1

echo "✅ Build complete!"
echo "Launching Draft..."
open "$APP_BUNDLE"
