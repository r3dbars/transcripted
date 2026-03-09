#!/bin/bash
# Build llama.cpp as linkable artifacts for Draft
# Run once — artifacts go into llamacpp-libs/ and llamacpp-modules/
# Pattern follows build-fluidaudio.sh: expensive build runs once, build.sh reuses cached artifacts

set -e

DRAFT_DIR="$(cd "$(dirname "$0")" && pwd)"
LC_BUILD="$DRAFT_DIR/.llamacpp-build"
LC_LIBS="$DRAFT_DIR/llamacpp-libs"
LC_MODULES="$DRAFT_DIR/llamacpp-modules"

# Pinned tag — update this to upgrade llama.cpp
LLAMA_CPP_TAG="b5270"

# Skip if already built (use --force to rebuild)
if [ -f "$LC_LIBS/libLlamaCppAll.a" ] && [ -d "$LC_MODULES/include" ] && [ "$1" != "--force" ]; then
    echo "llama.cpp already built. Use --force to rebuild."
    echo "  libs:    $LC_LIBS/libLlamaCppAll.a"
    echo "  modules: $LC_MODULES/include/"
    exit 0
fi

echo "Building llama.cpp..."

# Clean previous build
rm -rf "$LC_BUILD" "$LC_LIBS" "$LC_MODULES"
mkdir -p "$LC_BUILD"

# Clone at pinned tag
echo "Cloning llama.cpp at tag $LLAMA_CPP_TAG..."
cd "$LC_BUILD"
git clone --depth 1 --branch "$LLAMA_CPP_TAG" https://github.com/ggerganov/llama.cpp.git source

# Build with CMake — static libs, Metal ON, no examples/tests
echo "Building with CMake (this takes ~2 minutes)..."
mkdir -p "$LC_BUILD/build"
cd "$LC_BUILD/build"

cmake "$LC_BUILD/source" \
    -DCMAKE_OSX_ARCHITECTURES="arm64" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="14.0" \
    -DGGML_METAL=ON \
    -DLLAMA_BUILD_EXAMPLES=OFF \
    -DLLAMA_BUILD_TESTS=OFF \
    -DLLAMA_BUILD_SERVER=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DCMAKE_BUILD_TYPE=Release

cmake --build . --config Release -j$(sysctl -n hw.ncpu)

# Create output directories
mkdir -p "$LC_LIBS" "$LC_MODULES/include"

# Merge all static libraries into one archive
echo "Creating static library..."
STATIC_LIBS=$(find "$LC_BUILD/build" -name "*.a" -not -path "*/CMakeFiles/*")
if [ -z "$STATIC_LIBS" ]; then
    echo "No static libraries found!"
    exit 1
fi
libtool -static -o "$LC_LIBS/libLlamaCppAll.a" $STATIC_LIBS
echo "  $(ar t "$LC_LIBS/libLlamaCppAll.a" | wc -l | tr -d ' ') object files archived"

# Copy Metal shader library if present
METALLIB=$(find "$LC_BUILD/build" -name "default.metallib" -o -name "ggml-metal.metallib" 2>/dev/null | head -1)
if [ -n "$METALLIB" ]; then
    cp "$METALLIB" "$LC_LIBS/default.metallib"
    echo "  Metal shaders: $LC_LIBS/default.metallib"
else
    echo "  No precompiled Metal shaders found (will use runtime compilation)"
fi

# Copy C headers
echo "Copying headers..."
cp "$LC_BUILD/source/include/llama.h" "$LC_MODULES/include/"
# ggml headers — location varies by version
for header in ggml.h ggml-backend.h ggml-alloc.h ggml-metal.h ggml-cpu.h; do
    found=$(find "$LC_BUILD/source" -name "$header" -path "*/include/*" | head -1)
    if [ -z "$found" ]; then
        found=$(find "$LC_BUILD/source" -name "$header" -not -path "*/build/*" | head -1)
    fi
    if [ -n "$found" ]; then
        cp "$found" "$LC_MODULES/include/"
    fi
done

# Create module map for Swift interop
cat > "$LC_MODULES/include/module.modulemap" << 'MODULEMAP_EOF'
module llamacpp [system] {
    header "llama.h"
    export *
}
MODULEMAP_EOF

echo ""
echo "=== Results ==="
echo "Static library:"
ls -lh "$LC_LIBS/libLlamaCppAll.a"
echo ""
echo "Headers:"
ls "$LC_MODULES/include/"
echo ""
echo "Done. build.sh will detect these artifacts automatically."
