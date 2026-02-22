#!/bin/bash
# Build whisper.cpp as static libraries for Draft
# Run once — artifacts go into libs/ and include/

set -e

WHISPER_SRC="$HOME/whisper.cpp"
BUILD_DIR="$WHISPER_SRC/build-draft"
DRAFT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ ! -d "$WHISPER_SRC" ]; then
    echo "Cloning whisper.cpp..."
    git clone https://github.com/ggml-org/whisper.cpp.git "$WHISPER_SRC"
fi

echo "Building whisper.cpp static libraries (Metal enabled)..."
rm -rf "$BUILD_DIR"

cmake -S "$WHISPER_SRC" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON \
    -DGGML_METAL_EMBED_LIBRARY=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_EXAMPLES=OFF \
    -DWHISPER_BUILD_SERVER=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0

cmake --build "$BUILD_DIR" --config Release -j$(sysctl -n hw.ncpu)

# Copy static libraries
echo "Copying static libraries..."
mkdir -p "$DRAFT_DIR/libs"

# whisper
cp "$BUILD_DIR/src/libwhisper.a" "$DRAFT_DIR/libs/"

# ggml libs — try multiple known paths (structure varies by version)
for lib in ggml ggml-base ggml-cpu ggml-metal ggml-blas; do
    # Try flat structure
    if [ -f "$BUILD_DIR/ggml/src/lib${lib}.a" ]; then
        cp "$BUILD_DIR/ggml/src/lib${lib}.a" "$DRAFT_DIR/libs/"
    fi
    # Try nested structure (newer versions)
    if [ -f "$BUILD_DIR/ggml/src/${lib}/lib${lib}.a" ]; then
        cp "$BUILD_DIR/ggml/src/${lib}/lib${lib}.a" "$DRAFT_DIR/libs/"
    fi
done

# Copy headers
echo "Copying headers..."
mkdir -p "$DRAFT_DIR/include"
cp "$WHISPER_SRC/include/whisper.h" "$DRAFT_DIR/include/"

# ggml headers
for header in ggml.h ggml-cpu.h ggml-backend.h ggml-alloc.h ggml-metal.h; do
    if [ -f "$WHISPER_SRC/ggml/include/$header" ]; then
        cp "$WHISPER_SRC/ggml/include/$header" "$DRAFT_DIR/include/"
    fi
done

# Download GGML model if not already present
MODEL_DIR="$HOME/Library/Application Support/Draft/models"
MODEL_FILE="$MODEL_DIR/ggml-large-v3-turbo-q5_0.bin"
mkdir -p "$MODEL_DIR"

if [ -f "$MODEL_FILE" ]; then
    echo "Model already exists at $MODEL_FILE"
else
    echo "Downloading Whisper large-v3-turbo model (~547 MB)..."
    curl -L --progress-bar \
        -o "$MODEL_FILE" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin"
    echo "Model downloaded."
fi

echo ""
echo "=== Results ==="
echo "Libraries:"
ls -lh "$DRAFT_DIR/libs/"*.a 2>/dev/null || echo "  (none found!)"
echo ""
echo "Headers:"
ls "$DRAFT_DIR/include/"*.h 2>/dev/null || echo "  (none found!)"
echo ""
echo "Done."
