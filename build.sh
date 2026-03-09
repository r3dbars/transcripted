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

# Bundle GGUF LLM models
LLM_MODELS_DIR="$APP_BUNDLE/Contents/Resources/llm-models"
mkdir -p "$LLM_MODELS_DIR"
if [ -f "models/vision-parser.gguf" ]; then
    echo "Bundling vision model..."
    cp "models/vision-parser.gguf" "$LLM_MODELS_DIR/"
else
    echo "vision-parser.gguf not found in models/ — app will fail to load vision model"
fi
if [ -f "models/draft-model.gguf" ]; then
    echo "Bundling draft model..."
    cp "models/draft-model.gguf" "$LLM_MODELS_DIR/"
else
    echo "draft-model.gguf not found in models/ — app will fail to load draft model"
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

# FluidAudio (required — Parakeet STT engine)
# Run build-fluidaudio.sh first to build these artifacts
if [ ! -f "fluidaudio-libs/libFluidAudioAll.a" ] || [ ! -d "fluidaudio-modules/FluidAudio.swiftmodule" ]; then
    echo "FluidAudio not found — required for Parakeet STT engine"
    echo "   Run build-fluidaudio.sh first to build FluidAudio."
    exit 1
fi
echo "FluidAudio found"
FLUID_FLAGS="-Ifluidaudio-modules -Ifluidaudio-modules/FastClusterWrapper -Ifluidaudio-modules/MachTaskSelfWrapper -Ifluidaudio-modules/yyjson -Lfluidaudio-libs -lFluidAudioAll -framework CoreML -framework CoreAudio"

# llama.cpp (required — local LLM inference)
# Run build-llamacpp.sh first to build these artifacts
if [ ! -f "llamacpp-libs/libLlamaCppAll.a" ] || [ ! -d "llamacpp-modules/include" ]; then
    echo "llama.cpp not found — required for local LLM inference"
    echo "   Run build-llamacpp.sh first to build llama.cpp."
    exit 1
fi
echo "llama.cpp found"
LLAMA_FLAGS="-Illamacpp-modules/include -Lllamacpp-libs -lLlamaCppAll"

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
    -lsqlite3 \
    -lc++ \
    $FLUID_FLAGS \
    $LLAMA_FLAGS \
    $(find Sources -name '*.swift') \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    2>&1

if [ $? -ne 0 ]; then
    echo "Build failed!"
    exit 1
fi

# Sign
echo "Signing..."
codesign --force --deep --sign "Apple Development: r3dbars (LZRN6W4R74)" \
    --entitlements "$BUILD_DIR/Draft.entitlements" \
    "$APP_BUNDLE" 2>&1

echo "Build complete!"
echo "Launching Draft..."
open "$APP_BUNDLE"
