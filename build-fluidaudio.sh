#!/bin/bash
# Build FluidAudio as linkable artifacts for Transcripted
# Run once — artifacts go into fluidaudio-libs/ and fluidaudio-modules/
# Adapted from Draft's build-fluidaudio.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
FA_BUILD="$PROJECT_DIR/.fluidaudio-build"
FA_LIBS="$PROJECT_DIR/fluidaudio-libs"
FA_MODULES="$PROJECT_DIR/fluidaudio-modules"

# Skip if already built (use --force to rebuild)
if [ -f "$FA_LIBS/libFluidAudioAll.a" ] && [ -d "$FA_MODULES/FluidAudio.swiftmodule" ] && [ "$1" != "--force" ]; then
    echo "FluidAudio already built. Use --force to rebuild."
    echo "  libs:    $FA_LIBS/libFluidAudioAll.a"
    echo "  modules: $FA_MODULES/"
    exit 0
fi

echo "Building FluidAudio via SPM..."

# Create minimal SPM package
mkdir -p "$FA_BUILD/Sources"

cat > "$FA_BUILD/Package.swift" << 'PACKAGE_EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "FluidAudioBuild",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9")
    ],
    targets: [
        .target(
            name: "Shim",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio")
            ],
            path: "Sources"
        )
    ]
)
PACKAGE_EOF

echo "import FluidAudio" > "$FA_BUILD/Sources/Shim.swift"

# Build in release mode
cd "$FA_BUILD"
echo "Resolving dependencies..."
swift package resolve
echo "Building (this takes ~2 minutes on first run)..."
swift build -c release

# Paths
BUILD_RELEASE="$FA_BUILD/.build/arm64-apple-macosx/release"
MODULES_SRC="$FA_BUILD/.build/release/Modules"
CHECKOUTS="$FA_BUILD/.build/checkouts"

# Create output directories
rm -rf "$FA_LIBS" "$FA_MODULES"
mkdir -p "$FA_LIBS" "$FA_MODULES"

# --- Static library: combine all .o files into one .a ---
echo "Creating static library..."
cd "$BUILD_RELEASE"

NEEDED_MODULES=(
    Crypto.build
    FastClusterWrapper.build
    FluidAudio.build
    Hub.build
    InternalCollectionsUtilities.build
    Jinja.build
    MachTaskSelfWrapper.build
    OrderedCollections.build
    Tokenizers.build
    yyjson.build
)

find "${NEEDED_MODULES[@]}" -name "*.o" -print0 | xargs -0 ar rcs "$FA_LIBS/libFluidAudioAll.a"
echo "  $(ar t "$FA_LIBS/libFluidAudioAll.a" | wc -l | tr -d ' ') object files archived"

# --- Swift modules: wrap in directory structure for swiftc ---
echo "Copying Swift modules..."
for mod in "$MODULES_SRC"/*.swiftmodule; do
    name=$(basename "$mod" .swiftmodule)
    # Skip Shim — that's our build helper, not needed
    [ "$name" = "Shim" ] && continue
    mkdir -p "$FA_MODULES/${name}.swiftmodule"
    cp "$mod" "$FA_MODULES/${name}.swiftmodule/arm64-apple-macos.swiftmodule"
    if [ -f "$MODULES_SRC/${name}.swiftdoc" ]; then
        cp "$MODULES_SRC/${name}.swiftdoc" "$FA_MODULES/${name}.swiftmodule/arm64-apple-macos.swiftdoc"
    fi
done

# --- C module maps: needed for C wrapper targets ---
echo "Copying C module maps..."

# FastClusterWrapper
mkdir -p "$FA_MODULES/FastClusterWrapper"
cp "$CHECKOUTS/FluidAudio/Sources/FastClusterWrapper/include/module.modulemap" "$FA_MODULES/FastClusterWrapper/"
cp "$CHECKOUTS/FluidAudio/Sources/FastClusterWrapper/include/"*.h "$FA_MODULES/FastClusterWrapper/" 2>/dev/null || true

# MachTaskSelfWrapper
mkdir -p "$FA_MODULES/MachTaskSelfWrapper"
cp "$CHECKOUTS/FluidAudio/Sources/MachTaskSelfWrapper/include/module.modulemap" "$FA_MODULES/MachTaskSelfWrapper/"
cp "$CHECKOUTS/FluidAudio/Sources/MachTaskSelfWrapper/include/"*.h "$FA_MODULES/MachTaskSelfWrapper/" 2>/dev/null || true

# yyjson
mkdir -p "$FA_MODULES/yyjson"
cp "$CHECKOUTS/yyjson/src/yyjson.h" "$FA_MODULES/yyjson/"
cat > "$FA_MODULES/yyjson/module.modulemap" << 'MODULEMAP_EOF'
module yyjson {
    umbrella header "yyjson.h"
    export *
}
MODULEMAP_EOF

echo ""
echo "=== Results ==="
echo "Static library:"
ls -lh "$FA_LIBS/libFluidAudioAll.a"
echo ""
echo "Modules:"
ls "$FA_MODULES/"
echo ""
echo "Done. Xcode will use these artifacts via build settings."
