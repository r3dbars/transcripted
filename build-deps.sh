#!/bin/bash
# Build Draft's native speech + meeting dependencies as a unified static library.
# Resolves shared dependencies (Hub, Tokenizers, Jinja, Crypto, etc.) once
# to prevent duplicate symbol conflicts.
#
# Run once — artifacts go into deps-libs/ and deps-modules/
# Pattern follows build-fluidaudio.sh: expensive build runs once, build.sh reuses cached artifacts

set -e

DRAFT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEPS_BUILD="$DRAFT_DIR/.deps-build"
DEPS_LIBS="$DRAFT_DIR/deps-libs"
DEPS_MODULES="$DRAFT_DIR/deps-modules"

# ---------------------------------------------------------------------------
# Discover the Transcripted checkout that supplies Sources/TranscriptedCore
# ---------------------------------------------------------------------------
# TranscriptedCore is the SPM library extracted from the Transcripted repo at
# tag `extract/core-v1`. Draft's unified deps build inlines it as a target so
# FluidAudio + MLX become normal SPM dependency edges (see the heredoc below).
#
# Previously this path was a committed symlink at $DRAFT_DIR/Transcripted ->
# ../../../../Transcripted/.claude/worktrees/core-extract. That broke whenever
# Draft was checked out to a different depth (e.g. a non-worktree clone) and
# required callers to place both repos at matching positions. Replace it with
# runtime discovery:
#
#   1. $DRAFT_TRANSCRIPTED_ROOT             — explicit override
#   2. Sibling worktree with the same name  — e.g. both at .claude/worktrees/X
#   3. Transcripted/.claude/worktrees/core-extract (canonical merge worktree)
#   4. Transcripted main checkout (sibling dir to Draft)

discover_transcripted() {
    local searched=()

    try_root() {
        local candidate="$1"
        searched+=("$candidate")
        if [ -d "$candidate/Sources/TranscriptedCore" ] && [ -f "$candidate/Package.swift" ]; then
            TRANSCRIPTED_ROOT="$candidate"
            return 0
        fi
        return 1
    }

    if [ -n "$DRAFT_TRANSCRIPTED_ROOT" ]; then
        try_root "$DRAFT_TRANSCRIPTED_ROOT" && return 0
        echo "[build-deps] ERROR: DRAFT_TRANSCRIPTED_ROOT='$DRAFT_TRANSCRIPTED_ROOT' does not contain Sources/TranscriptedCore"
        exit 1
    fi

    local code_parent
    case "$DRAFT_DIR" in
        */.claude/worktrees/*)
            # <code>/Draft/.claude/worktrees/<name> -> <code>
            code_parent="$(cd "$DRAFT_DIR/../../../.." && pwd)"
            local worktree_name
            worktree_name="$(basename "$DRAFT_DIR")"
            try_root "$code_parent/Transcripted/.claude/worktrees/$worktree_name" && return 0
            ;;
        *)
            code_parent="$(cd "$DRAFT_DIR/.." && pwd)"
            ;;
    esac

    try_root "$code_parent/Transcripted/.claude/worktrees/core-extract" && return 0
    try_root "$code_parent/Transcripted" && return 0

    echo "[build-deps] ERROR: Could not locate a Transcripted checkout with Sources/TranscriptedCore. Searched:"
    for path in "${searched[@]}"; do
        echo "[build-deps]   - $path"
    done
    echo "[build-deps]"
    echo "[build-deps] Set DRAFT_TRANSCRIPTED_ROOT=/path/to/Transcripted to override, or clone"
    echo "[build-deps] Transcripted alongside Draft (e.g. ~/code/Draft and ~/code/Transcripted)."
    exit 1
}

discover_transcripted
echo "[build-deps] Using TranscriptedCore from: $TRANSCRIPTED_ROOT"

# Skip if already built (use --force to rebuild)
if [ -f "$DEPS_LIBS/libDraftDeps.a" ] && [ -d "$DEPS_MODULES" ] && [ "$1" != "--force" ]; then
    echo "Dependencies already built. Use --force to rebuild."
    echo "  libs:    $DEPS_LIBS/libDraftDeps.a"
    echo "  modules: $DEPS_MODULES/"
    exit 0
fi

echo "Building FluidAudio + mlx-swift-lm (unified)..."

# Clean previous build
rm -rf "$DEPS_BUILD" "$DEPS_LIBS" "$DEPS_MODULES"
mkdir -p "$DEPS_BUILD/Sources"

# Symlink TranscriptedCore's source tree into $DEPS_BUILD so SPM's target
# path validation accepts it (SPM forbids target paths that escape the
# package root). The symlink lets us build Core from Draft's unified
# package graph with proper FluidAudio/MLX dependency edges.
ln -sfn "$TRANSCRIPTED_ROOT/Sources/TranscriptedCore" "$DEPS_BUILD/TranscriptedCore"

# Create unified Package.swift — both dependencies resolved together
cat > "$DEPS_BUILD/Package.swift" << 'PACKAGE_EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "DraftDeps",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "25b00d4"),
    ],
    targets: [
        // TranscriptedCore is built directly from its source tree rather than
        // consumed via .package(path:) because Core's own Package.swift uses
        // relative unsafeFlags (-I ./.deps-modules) that assume a prebuilt
        // mega-library. Inlining as a target here makes FluidAudio + MLX
        // available through normal SPM dependency edges, producing a real
        // TranscriptedCore.swiftmodule that build-deps.sh copies into
        // deps-modules/ for build.sh to consume.
        .target(
            name: "TranscriptedCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            path: "TranscriptedCore"
        ),
        .target(
            name: "Shim",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                "TranscriptedCore",
            ],
            path: "Sources"
        )
    ]
)
PACKAGE_EOF

cat > "$DEPS_BUILD/Sources/Shim.swift" << 'SWIFT_EOF'
import FluidAudio
import MLXLLM
import MLXLMCommon
import TranscriptedCore
SWIFT_EOF

# Build in release mode
cd "$DEPS_BUILD"
echo "Resolving dependencies..."
swift package resolve
echo "Building (this takes several minutes on first run)..."
swift build -c release

# Paths
BUILD_RELEASE="$DEPS_BUILD/.build/arm64-apple-macosx/release"
MODULES_SRC="$DEPS_BUILD/.build/release/Modules"
CHECKOUTS="$DEPS_BUILD/.build/checkouts"

# Create output directories
mkdir -p "$DEPS_LIBS" "$DEPS_MODULES"

# --- Static library: combine all .o files into one .a ---
echo "Creating static library..."
cd "$BUILD_RELEASE"

# Find all .build directories except our Shim target
ALL_BUILD_DIRS=$(find . -maxdepth 1 -name "*.build" -type d | grep -v "Shim.build" | sort)
echo "Build directories found:"
echo "$ALL_BUILD_DIRS" | while read -r dir; do echo "  $dir"; done

# Archive all .o files
find $ALL_BUILD_DIRS -name "*.o" -print0 | xargs -0 ar rcs "$DEPS_LIBS/libDraftDeps.a"
OBJ_COUNT=$(ar t "$DEPS_LIBS/libDraftDeps.a" | wc -l | tr -d ' ')
echo "  $OBJ_COUNT object files archived"

# --- Swift modules ---
echo "Copying Swift modules..."
for mod in "$MODULES_SRC"/*.swiftmodule; do
    name=$(basename "$mod" .swiftmodule)
    # Skip Shim — that's our build helper
    [ "$name" = "Shim" ] && continue
    mkdir -p "$DEPS_MODULES/${name}.swiftmodule"
    cp "$mod" "$DEPS_MODULES/${name}.swiftmodule/arm64-apple-macos.swiftmodule"
    if [ -f "$MODULES_SRC/${name}.swiftdoc" ]; then
        cp "$MODULES_SRC/${name}.swiftdoc" "$DEPS_MODULES/${name}.swiftmodule/arm64-apple-macos.swiftdoc"
    fi
    # Copy .swiftinterface if present (for resilient modules)
    if [ -f "$MODULES_SRC/${name}.swiftinterface" ]; then
        cp "$MODULES_SRC/${name}.swiftinterface" "$DEPS_MODULES/${name}.swiftmodule/arm64-apple-macos.swiftinterface"
    fi
done

# --- C module maps: needed for C/C++ wrapper targets ---
echo "Copying C module maps..."

# _NumericsShims (from swift-numerics)
NUMERICS_SHIMS=$(find "$CHECKOUTS" -path "*/_NumericsShims/include" -type d 2>/dev/null | head -1)
if [ -n "$NUMERICS_SHIMS" ]; then
    mkdir -p "$DEPS_MODULES/_NumericsShims"
    cp "$NUMERICS_SHIMS/"* "$DEPS_MODULES/_NumericsShims/"
fi

# FastClusterWrapper (from FluidAudio)
if [ -d "$CHECKOUTS/FluidAudio/Sources/FastClusterWrapper/include" ]; then
    mkdir -p "$DEPS_MODULES/FastClusterWrapper"
    cp "$CHECKOUTS/FluidAudio/Sources/FastClusterWrapper/include/module.modulemap" "$DEPS_MODULES/FastClusterWrapper/"
    cp "$CHECKOUTS/FluidAudio/Sources/FastClusterWrapper/include/"*.h "$DEPS_MODULES/FastClusterWrapper/" 2>/dev/null || true
fi

# MachTaskSelfWrapper (from FluidAudio)
if [ -d "$CHECKOUTS/FluidAudio/Sources/MachTaskSelfWrapper/include" ]; then
    mkdir -p "$DEPS_MODULES/MachTaskSelfWrapper"
    cp "$CHECKOUTS/FluidAudio/Sources/MachTaskSelfWrapper/include/module.modulemap" "$DEPS_MODULES/MachTaskSelfWrapper/"
    cp "$CHECKOUTS/FluidAudio/Sources/MachTaskSelfWrapper/include/"*.h "$DEPS_MODULES/MachTaskSelfWrapper/" 2>/dev/null || true
fi

# yyjson
YYJSON_H=$(find "$CHECKOUTS" -name "yyjson.h" -path "*/src/yyjson.h" 2>/dev/null | head -1)
if [ -n "$YYJSON_H" ]; then
    mkdir -p "$DEPS_MODULES/yyjson"
    cp "$YYJSON_H" "$DEPS_MODULES/yyjson/"
    cat > "$DEPS_MODULES/yyjson/module.modulemap" << 'MODULEMAP_EOF'
module yyjson {
    umbrella header "yyjson.h"
    export *
}
MODULEMAP_EOF
fi

# Cmlx (from mlx-swift) — C++ bridge to MLX
# Look for Cmlx module in build output or source checkouts
CMLX_INCLUDE=$(find "$CHECKOUTS" -path "*/Cmlx/include" -type d 2>/dev/null | head -1)
if [ -n "$CMLX_INCLUDE" ]; then
    echo "  Copying Cmlx headers..."
    mkdir -p "$DEPS_MODULES/Cmlx"
    cp -R "$CMLX_INCLUDE/"* "$DEPS_MODULES/Cmlx/"
fi

# Also check for Cmlx module map in the build output
CMLX_MODULEMAP=$(find "$BUILD_RELEASE" -path "*Cmlx*module.modulemap" 2>/dev/null | head -1)
if [ -n "$CMLX_MODULEMAP" ] && [ ! -f "$DEPS_MODULES/Cmlx/module.modulemap" ]; then
    mkdir -p "$DEPS_MODULES/Cmlx"
    cp "$CMLX_MODULEMAP" "$DEPS_MODULES/Cmlx/"
fi

# --- Metal libraries: compile MLX Metal shaders ---
# SPM's `swift build` doesn't compile .metal files — only Xcode does.
# We manually compile them with xcrun metal → .air, then xcrun metallib → .metallib.
echo "Compiling MLX Metal shaders..."
CMLX_SRC=$(find "$CHECKOUTS" -path "*/Source/Cmlx" -type d 2>/dev/null | head -1)
if [ -n "$CMLX_SRC" ]; then
    METAL_GENERATED="$CMLX_SRC/mlx-generated/metal"
    METAL_KERNELS="$CMLX_SRC/mlx/mlx/backend/metal/kernels"
    METAL_OUT="$DEPS_BUILD/.metal-air"
    mkdir -p "$METAL_OUT"

    METAL_FILES=$(find "$METAL_GENERATED" -name "*.metal" 2>/dev/null)
    if [ -n "$METAL_FILES" ]; then
        for metal_file in $METAL_FILES; do
            name=$(basename "$metal_file" .metal)
            echo "  Compiling $name.metal..."
            xcrun metal -c \
                -I "$METAL_GENERATED" \
                -I "$METAL_KERNELS" \
                -I "$METAL_KERNELS/steel" \
                -I "$METAL_KERNELS/steel/gemm" \
                -I "$METAL_KERNELS/steel/attn" \
                -I "$METAL_KERNELS/steel/conv" \
                -target air64-apple-macos14.0 \
                "$metal_file" -o "$METAL_OUT/$name.air" 2>&1
        done

        AIR_COUNT=$(ls "$METAL_OUT"/*.air 2>/dev/null | wc -l | tr -d ' ')
        if [ "$AIR_COUNT" -gt 0 ]; then
            echo "  Linking $AIR_COUNT .air files into mlx.metallib..."
            xcrun metallib -o "$DEPS_LIBS/mlx.metallib" "$METAL_OUT"/*.air
            ls -lh "$DEPS_LIBS/mlx.metallib"
        else
            echo "  WARNING: No .air files produced — Metal shaders not compiled"
        fi
    else
        echo "  No generated Metal files found in $METAL_GENERATED"
    fi
else
    echo "  WARNING: Cmlx source not found — cannot compile Metal shaders"
fi

echo ""
echo "=== Results ==="
echo "Static library:"
ls -lh "$DEPS_LIBS/libDraftDeps.a"
echo ""
echo "Modules:"
ls "$DEPS_MODULES/" | head -30
MOD_COUNT=$(ls "$DEPS_MODULES/" | wc -l | tr -d ' ')
if [ "$MOD_COUNT" -gt 30 ]; then
    echo "  ... and $((MOD_COUNT - 30)) more"
fi
echo ""
echo "Done. build.sh will detect these artifacts automatically."
