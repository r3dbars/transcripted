#!/bin/bash
# Build Draft's native speech + meeting dependencies as a unified static library.
# Resolves shared dependencies (Hub, Tokenizers, Jinja, Crypto, etc.) once
# to prevent duplicate symbol conflicts.
#
# Run once — artifacts go into deps-libs/ and deps-modules/
# Pattern follows build-fluidaudio.sh: expensive build runs once, build.sh reuses cached artifacts

set -e

DRAFT_DIR="$(cd "$(dirname "$0")" && pwd)"
TMP_ROOT="${TMPDIR%/}"
if [ -z "$TMP_ROOT" ]; then
    TMP_ROOT="/tmp"
fi
DEPS_BUILD="$(mktemp -d "$TMP_ROOT/transcripted-deps-build.XXXXXX")"
DEPS_LIBS="$DRAFT_DIR/deps-libs"
DEPS_MODULES="$DRAFT_DIR/deps-modules"
DEPS_FRAMEWORKS="$DRAFT_DIR/deps-frameworks"
DEPS_TOOLS="$DRAFT_DIR/deps-tools"
FLUID_AUDIO_VERSION="${FLUID_AUDIO_VERSION:-0.7.9}"
MLX_SWIFT_LM_REVISION="${MLX_SWIFT_LM_REVISION:-25b00d4}"
SWIFT_TRANSFORMERS_VERSION="${SWIFT_TRANSFORMERS_VERSION:-1.2.1}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.1}"
SENTRY_COCOA_VERSION="${SENTRY_COCOA_VERSION:-9.10.0}"

download_sparkle_distribution() {
    local sparkle_root="$DEPS_BUILD/sparkle"
    local sparkle_zip="$sparkle_root/Sparkle-for-Swift-Package-Manager.zip"
    local sparkle_url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
    local unpacked_root="$sparkle_root/unpacked"
    local framework_src="$unpacked_root/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

    echo "Downloading Sparkle $SPARKLE_VERSION..."
    mkdir -p "$sparkle_root"
    curl --fail --location --silent --show-error "$sparkle_url" -o "$sparkle_zip"
    unzip -q "$sparkle_zip" -d "$unpacked_root"

    if [ ! -d "$framework_src" ]; then
        echo "[build-deps] ERROR: Sparkle.framework not found in downloaded distribution"
        exit 1
    fi

    rm -rf "$DEPS_FRAMEWORKS/Sparkle.framework"
    ditto "$framework_src" "$DEPS_FRAMEWORKS/Sparkle.framework"

    rm -rf "$DEPS_TOOLS/sparkle"
    mkdir -p "$DEPS_TOOLS/sparkle"
    ditto "$unpacked_root/bin" "$DEPS_TOOLS/sparkle/bin"
    if [ -f "$unpacked_root/SampleAppcast.xml" ]; then
        ditto "$unpacked_root/SampleAppcast.xml" "$DEPS_TOOLS/sparkle/SampleAppcast.xml"
    fi

    chmod +x "$DEPS_TOOLS/sparkle/bin/"*
}

download_sentry_distribution() {
    local sentry_root="$DEPS_BUILD/sentry"
    local sentry_zip="$sentry_root/Sentry-Dynamic.xcframework.zip"
    local sentry_url="https://github.com/getsentry/sentry-cocoa/releases/download/${SENTRY_COCOA_VERSION}/Sentry-Dynamic.xcframework.zip"
    local unpacked_root="$sentry_root/unpacked"
    local framework_src="$unpacked_root/Sentry-Dynamic.xcframework/macos-arm64_x86_64/Sentry.framework"

    echo "Downloading Sentry Cocoa $SENTRY_COCOA_VERSION..."
    mkdir -p "$sentry_root"
    curl --fail --location --silent --show-error "$sentry_url" -o "$sentry_zip"
    unzip -q "$sentry_zip" -d "$unpacked_root"

    if [ ! -d "$framework_src" ]; then
        echo "[build-deps] ERROR: Sentry.framework not found in downloaded distribution"
        exit 1
    fi

    rm -rf "$DEPS_FRAMEWORKS/Sentry.framework"
    ditto "$framework_src" "$DEPS_FRAMEWORKS/Sentry.framework"
}

resolve_package_graph() {
    local resolve_cmd=("swift" "package" "resolve" "--disable-dependency-cache")

    echo "Resolving dependencies..."
    echo "  FluidAudio:         $FLUID_AUDIO_VERSION"
    echo "  mlx-swift-lm rev:   $MLX_SWIFT_LM_REVISION"
    echo "  swift-transformers: $SWIFT_TRANSFORMERS_VERSION"

    if "${resolve_cmd[@]}"; then
        return 0
    fi

    echo "[build-deps] WARNING: initial resolve failed; retrying from a clean SwiftPM state"
    rm -rf .build Package.resolved
    "${resolve_cmd[@]}"
}

ensure_mlx_swift_submodules() {
    local mlx_swift_checkout="$DEPS_BUILD/.build/checkouts/mlx-swift"
    if [ -d "$mlx_swift_checkout/.git" ]; then
        echo "Ensuring mlx-swift submodules are present..."
        git -C "$mlx_swift_checkout" submodule sync --recursive
        git -C "$mlx_swift_checkout" submodule update --init --recursive --jobs 1
    fi
}

build_release_graph() {
    echo "Building (this takes several minutes on first run)..."

    ensure_mlx_swift_submodules
    if swift build --disable-dependency-cache -c release; then
        return 0
    fi

    echo "[build-deps] WARNING: release build failed; clearing package state and retrying once"
    rm -rf .build Package.resolved
    resolve_package_graph
    ensure_mlx_swift_submodules
    swift build --disable-dependency-cache -c release
}
# ---------------------------------------------------------------------------
# Discover the TranscriptedCore source tree to inline into the unified deps build.
# ---------------------------------------------------------------------------
# In the public `r3dbars/transcripted` repo, Draft and TranscriptedCore now live
# together. Prefer the in-repo `Sources/TranscriptedCore` first so a fresh clone
# builds without a sibling checkout.
#
# For private/legacy Draft-only checkouts, keep the old sibling-repo discovery as
# a fallback.
#
# Previously this path was a committed symlink at $DRAFT_DIR/Transcripted ->
# ../../../../Transcripted/.claude/worktrees/core-extract. That broke whenever
# Draft was checked out to a different depth (e.g. a non-worktree clone) and
# required callers to place both repos at matching positions. Replace it with
# runtime discovery:
#
#   1. This repo itself (if it already contains Sources/TranscriptedCore)
#   2. $DRAFT_TRANSCRIPTED_ROOT             — explicit override
#   3. Sibling worktree with the same name  — e.g. both at .claude/worktrees/X
#   4. Transcripted/.claude/worktrees/core-extract (canonical merge worktree)
#   5. Transcripted main checkout (sibling dir to Draft)

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

    try_root "$DRAFT_DIR" && return 0

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
    echo "[build-deps] TranscriptedCore alongside Draft (e.g. merged repo root, or ~/code/Draft and ~/code/Transcripted)."
    exit 1
}

discover_transcripted
echo "[build-deps] Using TranscriptedCore from: $TRANSCRIPTED_ROOT"

# Skip if already built (use --force to rebuild).
# libExternalDeps.a was added later for SPM-based `swift test`, so require it too;
# otherwise legacy worktrees would keep skipping while missing the archive.
if [ -f "$DEPS_LIBS/libDraftDeps.a" ] && [ -f "$DEPS_LIBS/libExternalDeps.a" ] && [ -d "$DEPS_MODULES" ] && [ -d "$DEPS_FRAMEWORKS/ESpeakNG.framework" ] && [ -d "$DEPS_FRAMEWORKS/Sentry.framework" ] && [ -d "$DEPS_FRAMEWORKS/Sparkle.framework" ] && [ -x "$DEPS_TOOLS/sparkle/bin/generate_appcast" ] && [ "${1:-}" != "--force" ]; then
    echo "Dependencies already built. Use --force to rebuild."
    echo "  libs:    $DEPS_LIBS/libDraftDeps.a"
    echo "           $DEPS_LIBS/libExternalDeps.a"
    echo "  modules: $DEPS_MODULES/"
    echo "  frameworks: $DEPS_FRAMEWORKS/ESpeakNG.framework"
    echo "              $DEPS_FRAMEWORKS/Sentry.framework"
    echo "              $DEPS_FRAMEWORKS/Sparkle.framework"
    echo "  tools:      $DEPS_TOOLS/sparkle/bin/generate_appcast"
    exit 0
fi

echo "Building FluidAudio + mlx-swift-lm (unified)..."

# Clean previous build
rm -rf "$DEPS_LIBS" "$DEPS_MODULES" "$DEPS_FRAMEWORKS" "$DEPS_TOOLS"
mkdir -p "$DEPS_BUILD/Sources"

# Copy TranscriptedCore's source tree into $DEPS_BUILD so SPM sees a stable,
# self-contained package root. A live symlink back into the worktree can make
# long dependency builds fail with "input file ... was modified during the build"
# if the repo changes while SwiftPM is compiling.
ditto "$TRANSCRIPTED_ROOT/Sources/TranscriptedCore" "$DEPS_BUILD/TranscriptedCore"

# Create unified Package.swift — both dependencies resolved together
cat > "$DEPS_BUILD/Package.swift" << 'PACKAGE_EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "DraftDeps",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "FLUID_AUDIO_VERSION_PLACEHOLDER"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "MLX_SWIFT_LM_REVISION_PLACEHOLDER"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "SWIFT_TRANSFORMERS_VERSION_PLACEHOLDER"),
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
            path: "TranscriptedCore",
            exclude: ["CLAUDE.md"]
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

FLUID_AUDIO_VERSION="$FLUID_AUDIO_VERSION" \
MLX_SWIFT_LM_REVISION="$MLX_SWIFT_LM_REVISION" \
SWIFT_TRANSFORMERS_VERSION="$SWIFT_TRANSFORMERS_VERSION" \
perl -0pi \
    -e 's/FLUID_AUDIO_VERSION_PLACEHOLDER/$ENV{FLUID_AUDIO_VERSION}/g; s/MLX_SWIFT_LM_REVISION_PLACEHOLDER/$ENV{MLX_SWIFT_LM_REVISION}/g; s/SWIFT_TRANSFORMERS_VERSION_PLACEHOLDER/$ENV{SWIFT_TRANSFORMERS_VERSION}/g' \
    "$DEPS_BUILD/Package.swift"

cat > "$DEPS_BUILD/Sources/Shim.swift" << 'SWIFT_EOF'
import FluidAudio
import MLXLLM
import MLXLMCommon
import TranscriptedCore
SWIFT_EOF

# Build in release mode
cd "$DEPS_BUILD"
export FLUID_AUDIO_VERSION
export MLX_SWIFT_LM_REVISION
export SWIFT_TRANSFORMERS_VERSION
resolve_package_graph
build_release_graph

# Paths
BUILD_RELEASE="$DEPS_BUILD/.build/arm64-apple-macosx/release"
MODULES_SRC="$DEPS_BUILD/.build/release/Modules"
CHECKOUTS="$DEPS_BUILD/.build/checkouts"

# Create output directories
mkdir -p "$DEPS_LIBS" "$DEPS_MODULES" "$DEPS_FRAMEWORKS"

# --- Static library: combine all .o files into one .a ---
echo "Creating static library..."
cd "$BUILD_RELEASE"

# Find all .build directories except our Shim target
ALL_BUILD_DIRS=$(find . -maxdepth 1 -name "*.build" -type d | grep -v "Shim.build" | sort)
echo "Build directories found:"
echo "$ALL_BUILD_DIRS" | while read -r dir; do echo "  $dir"; done

# Archive all .o files into libDraftDeps.a (includes TranscriptedCore — used by build.sh which
# excludes Sources/TranscriptedCore from its swiftc invocation to avoid name-collision issues).
find $ALL_BUILD_DIRS -name "*.o" -print0 | xargs -0 ar rcs "$DEPS_LIBS/libDraftDeps.a"
OBJ_COUNT=$(ar t "$DEPS_LIBS/libDraftDeps.a" | wc -l | tr -d ' ')
echo "  $OBJ_COUNT object files archived"

# Also create libExternalDeps.a — same as libDraftDeps.a but without TranscriptedCore objects.
# Package.swift links against this for `swift test`, which compiles TranscriptedCore from
# source via SPM. Using libDraftDeps.a there causes duplicate-symbol linker errors because
# Core appears in both the SPM-compiled objects and the static archive.
EXTERNAL_DIRS=$(find . -maxdepth 1 -name "*.build" -type d | grep -v "Shim.build" | grep -v "TranscriptedCore.build" | sort)
find $EXTERNAL_DIRS -name "*.o" -print0 | xargs -0 ar rcs "$DEPS_LIBS/libExternalDeps.a"
EXT_COUNT=$(ar t "$DEPS_LIBS/libExternalDeps.a" | wc -l | tr -d ' ')
echo "  $EXT_COUNT object files archived (external-only, no TranscriptedCore)"

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
    rm -rf "$DEPS_MODULES/_NumericsShims"
    ditto "$NUMERICS_SHIMS" "$DEPS_MODULES/_NumericsShims"
fi

# FastClusterWrapper (from FluidAudio)
if [ -d "$CHECKOUTS/FluidAudio/Sources/FastClusterWrapper/include" ]; then
    rm -rf "$DEPS_MODULES/FastClusterWrapper"
    ditto "$CHECKOUTS/FluidAudio/Sources/FastClusterWrapper/include" "$DEPS_MODULES/FastClusterWrapper"
fi

# MachTaskSelfWrapper (from FluidAudio)
if [ -d "$CHECKOUTS/FluidAudio/Sources/MachTaskSelfWrapper/include" ]; then
    rm -rf "$DEPS_MODULES/MachTaskSelfWrapper"
    ditto "$CHECKOUTS/FluidAudio/Sources/MachTaskSelfWrapper/include" "$DEPS_MODULES/MachTaskSelfWrapper"
fi

# yyjson
YYJSON_H=$(find "$CHECKOUTS" -name "yyjson.h" -path "*/src/yyjson.h" 2>/dev/null | head -1)
if [ -n "$YYJSON_H" ]; then
    rm -rf "$DEPS_MODULES/yyjson"
    mkdir -p "$DEPS_MODULES/yyjson"
    ditto "$YYJSON_H" "$DEPS_MODULES/yyjson/yyjson.h"
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
    rm -rf "$DEPS_MODULES/Cmlx"
    ditto "$CMLX_INCLUDE" "$DEPS_MODULES/Cmlx"
fi

# Also check for Cmlx module map in the build output
CMLX_MODULEMAP=$(find "$BUILD_RELEASE" -path "*Cmlx*module.modulemap" 2>/dev/null | head -1)
if [ -n "$CMLX_MODULEMAP" ] && [ ! -f "$DEPS_MODULES/Cmlx/module.modulemap" ]; then
    mkdir -p "$DEPS_MODULES/Cmlx"
    ditto "$CMLX_MODULEMAP" "$DEPS_MODULES/Cmlx/module.modulemap"
fi

# Export the binary-target framework needed by FluidAudio and package recompiles.
echo "Copying ESpeakNG.framework..."
ESPEAK_FRAMEWORK_SRC="$(
    find "$CHECKOUTS" \
        -path "*/ESpeakNG.framework" \
        -type d 2>/dev/null | \
        grep '/macos' | \
        head -1 || true
)"
if [ -z "$ESPEAK_FRAMEWORK_SRC" ]; then
    ESPEAK_FRAMEWORK_SRC="$(
        find "$CHECKOUTS" \
            -path "*/ESpeakNG.framework" \
            -type d 2>/dev/null | \
            head -1 || true
    )"
fi
if [ -z "$ESPEAK_FRAMEWORK_SRC" ]; then
    echo "[build-deps] ERROR: ESpeakNG.framework not found in resolved dependencies"
    exit 1
fi
rm -rf "$DEPS_FRAMEWORKS/ESpeakNG.framework"
ditto "$ESPEAK_FRAMEWORK_SRC" "$DEPS_FRAMEWORKS/ESpeakNG.framework"

download_sentry_distribution
download_sparkle_distribution

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
echo "Frameworks:"
ls "$DEPS_FRAMEWORKS/"
echo ""
echo "Sparkle tools:"
ls "$DEPS_TOOLS/sparkle/bin"
echo ""
echo "Done. build.sh will detect these artifacts automatically."
