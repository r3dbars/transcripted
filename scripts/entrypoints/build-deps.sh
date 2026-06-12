#!/bin/bash
# Build Transcripted's native speech + meeting dependencies as a unified static library.
# Resolves shared dependencies (Hub, Tokenizers, Jinja, Crypto, etc.) once
# to prevent duplicate symbol conflicts.
#
# Run once — artifacts go into deps-libs/ and deps-modules/
# Pattern follows the cache-first build workflow: expensive build runs once, build.sh reuses cached artifacts

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
DRAFT_DIR="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$DRAFT_DIR"
TMP_ROOT="${TMPDIR:-}"
TMP_ROOT="${TMP_ROOT%/}"
if [ -z "$TMP_ROOT" ]; then
    TMP_ROOT="/tmp"
fi
DEPS_BUILD="$(mktemp -d "$TMP_ROOT/transcripted-deps-build.XXXXXX")"
DEPS_STAGING=""

# Always remove the multi-GB SwiftPM scratch tree, and any staging dirs that
# never got swapped into place, no matter how the script exits.
cleanup_scratch() {
    rm -rf "$DEPS_BUILD"
    if [ -n "$DEPS_STAGING" ]; then
        rm -rf "$DEPS_STAGING"
    fi
}
trap cleanup_scratch EXIT
DEPS_LIBS="$DRAFT_DIR/deps-libs"
DEPS_BUILD_STAMP="$DEPS_LIBS/.build-deps-stamp"
DEPS_MODULES="$DRAFT_DIR/deps-modules"
DEPS_FRAMEWORKS="$DRAFT_DIR/deps-frameworks"
DEPS_TOOLS="$DRAFT_DIR/deps-tools"
TRANSCRIPTED_CORE_MODULE="$DEPS_MODULES/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
ARGMAX_CORE_MODULE="$DEPS_MODULES/ArgmaxCore.swiftmodule/arm64-apple-macos.swiftmodule"
WHISPERKIT_MODULE="$DEPS_MODULES/WhisperKit.swiftmodule/arm64-apple-macos.swiftmodule"
FLUID_AUDIO_VERSION="${FLUID_AUDIO_VERSION:-0.7.9}"
MLX_SWIFT_LM_REVISION="${MLX_SWIFT_LM_REVISION:-25b00d4}"
SWIFT_TRANSFORMERS_VERSION="${SWIFT_TRANSFORMERS_VERSION:-1.2.1}"
ARGMAX_OSS_SWIFT_VERSION="${ARGMAX_OSS_SWIFT_VERSION:-v0.18.0}"
ARGMAX_OSS_SWIFT_REVISION="${ARGMAX_OSS_SWIFT_REVISION:-e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.1}"
SENTRY_COCOA_VERSION="${SENTRY_COCOA_VERSION:-9.10.0}"
SPARKLE_SHA256="${SPARKLE_SHA256:-9fec2b888e6e2940b1bfbd5d3d010b9f67076b52170923549095cbb74132403b}"
SENTRY_COCOA_SHA256="${SENTRY_COCOA_SHA256:-1dd70512f3b5af6c74f1b8f11279531900173fb638d7d541320a7cbc00ed06bc}"

dependency_input_listing() {
    {
        printf '%s\n' "Package.swift"
        printf '%s\n' "scripts/entrypoints/build-deps.sh"
        find "Sources/TranscriptedCore" -type f ! -name "CLAUDE.md"
    } | while IFS= read -r path; do
        [ -e "$path" ] || continue
        printf '%s\t%s\n' "$(stat -f '%m' "$path")" "$path"
    done
}

newest_dependency_input() {
    dependency_input_listing | awk 'NR == 1 || $1 > max { max = $1; line = $0 } END { if (line != "") print line }'
}

deps_build_stamp_info() {
    if [ -f "$DEPS_BUILD_STAMP" ]; then
        printf '%s\t%s\n' "$(stat -f '%m' "$DEPS_BUILD_STAMP")" "$DEPS_BUILD_STAMP"
    fi
}

deps_are_ready() {
    local newest_input
    local build_stamp
    local newest_input_mtime
    local newest_input_path
    local build_stamp_mtime
    local build_stamp_path

    if [ ! -f "$DEPS_LIBS/libDraftDeps.a" ] \
        || [ ! -f "$DEPS_LIBS/libExternalDeps.a" ] \
        || [ ! -f "$DEPS_BUILD_STAMP" ] \
        || [ ! -d "$DEPS_MODULES" ] \
        || [ ! -f "$TRANSCRIPTED_CORE_MODULE" ] \
        || [ ! -f "$ARGMAX_CORE_MODULE" ] \
        || [ ! -f "$WHISPERKIT_MODULE" ] \
        || [ ! -d "$DEPS_FRAMEWORKS/ESpeakNG.framework" ] \
        || [ ! -d "$DEPS_FRAMEWORKS/Sentry.framework" ] \
        || [ ! -d "$DEPS_FRAMEWORKS/Sparkle.framework" ] \
        || [ ! -x "$DEPS_TOOLS/sparkle/bin/generate_appcast" ]; then
        return 1
    fi

    newest_input="$(newest_dependency_input)"
    build_stamp="$(deps_build_stamp_info)"

    IFS=$'\t' read -r newest_input_mtime newest_input_path <<< "$newest_input"
    IFS=$'\t' read -r build_stamp_mtime build_stamp_path <<< "$build_stamp"

    if [ -n "$newest_input_mtime" ] && [ -n "$build_stamp_mtime" ] && [ "$newest_input_mtime" -gt "$build_stamp_mtime" ]; then
        echo "[build-deps] Dependencies are stale for TranscriptedCore."
        echo "[build-deps] Newest input:"
        echo "[build-deps]   $newest_input_path"
        echo "[build-deps] Built deps stamp:"
        echo "[build-deps]   $build_stamp_path"
        return 1
    fi

    return 0
}

verify_download_sha256() {
    local downloaded_file="$1"
    local expected_sha256="$2"
    local label="$3"
    local actual_sha256

    actual_sha256="$(shasum -a 256 "$downloaded_file" | awk '{print $1}')"
    if [ "$actual_sha256" != "$expected_sha256" ]; then
        echo "[build-deps] ERROR: SHA-256 mismatch for $label"
        echo "[build-deps]   expected: $expected_sha256"
        echo "[build-deps]   actual:   $actual_sha256"
        exit 1
    fi
}

download_sparkle_distribution() {
    local sparkle_root="$DEPS_BUILD/sparkle"
    local sparkle_zip="$sparkle_root/Sparkle-for-Swift-Package-Manager.zip"
    local sparkle_url="https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-for-Swift-Package-Manager.zip"
    local unpacked_root="$sparkle_root/unpacked"
    local framework_src="$unpacked_root/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

    echo "Downloading Sparkle $SPARKLE_VERSION..."
    mkdir -p "$sparkle_root"
    curl --fail --location --silent --show-error "$sparkle_url" -o "$sparkle_zip"
    verify_download_sha256 "$sparkle_zip" "$SPARKLE_SHA256" "Sparkle $SPARKLE_VERSION"
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
    verify_download_sha256 "$sentry_zip" "$SENTRY_COCOA_SHA256" "Sentry Cocoa $SENTRY_COCOA_VERSION"
    unzip -q "$sentry_zip" -d "$unpacked_root"

    if [ ! -d "$framework_src" ]; then
        echo "[build-deps] ERROR: Sentry.framework not found in downloaded distribution"
        exit 1
    fi

    rm -rf "$DEPS_FRAMEWORKS/Sentry.framework"
    ditto "$framework_src" "$DEPS_FRAMEWORKS/Sentry.framework"
}

fetch_argmax_whisperkit_sources() {
    local argmax_root="$DEPS_BUILD/argmax-oss-swift"
    local actual_revision

    echo "Fetching Argmax WhisperKit $ARGMAX_OSS_SWIFT_VERSION..."
    rm -rf "$argmax_root" "$DEPS_BUILD/ArgmaxCore" "$DEPS_BUILD/WhisperKit"
    git -c advice.detachedHead=false clone \
        --quiet \
        --depth 1 \
        --branch "$ARGMAX_OSS_SWIFT_VERSION" \
        https://github.com/argmaxinc/argmax-oss-swift.git \
        "$argmax_root"

    actual_revision="$(git -C "$argmax_root" rev-parse HEAD)"
    if [ "$actual_revision" != "$ARGMAX_OSS_SWIFT_REVISION" ]; then
        echo "[build-deps] ERROR: Argmax WhisperKit revision mismatch"
        echo "[build-deps]   expected: $ARGMAX_OSS_SWIFT_REVISION"
        echo "[build-deps]   actual:   $actual_revision"
        exit 1
    fi

    for target in ArgmaxCore WhisperKit; do
        if [ ! -d "$argmax_root/Sources/$target" ]; then
            echo "[build-deps] ERROR: Argmax source target missing: Sources/$target"
            exit 1
        fi
        ditto "$argmax_root/Sources/$target" "$DEPS_BUILD/$target"
    done
}

resolve_package_graph() {
    local resolve_cmd=("swift" "package" "resolve" "--disable-dependency-cache")

    echo "Resolving dependencies..."
    echo "  FluidAudio:         $FLUID_AUDIO_VERSION"
    echo "  mlx-swift-lm rev:   $MLX_SWIFT_LM_REVISION"
    echo "  swift-transformers: $SWIFT_TRANSFORMERS_VERSION"
    echo "  Argmax WhisperKit:  $ARGMAX_OSS_SWIFT_VERSION ($ARGMAX_OSS_SWIFT_REVISION)"

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
# Use this checkout's TranscriptedCore source tree in the unified deps build.
# ---------------------------------------------------------------------------

resolve_transcripted_core_root() {
    if [ -d "$DRAFT_DIR/Sources/TranscriptedCore" ] && [ -f "$DRAFT_DIR/Package.swift" ]; then
        TRANSCRIPTED_ROOT="$DRAFT_DIR"
        return 0
    fi

    echo "[build-deps] ERROR: Sources/TranscriptedCore is missing from this checkout."
    echo "[build-deps] Run build-deps.sh from a current r3dbars/transcripted clone."
    exit 1
}

resolve_transcripted_core_root
echo "[build-deps] Using TranscriptedCore from: $TRANSCRIPTED_ROOT"

# Skip if already built (use --force to rebuild). Keep this in lockstep with
# build.sh's required artifacts so a "ready" deps pass always means the app can build.
if [ "${1:-}" != "--force" ] && deps_are_ready; then
    echo "Dependencies already built. Use --force to rebuild."
    echo "  libs:    $DEPS_LIBS/libDraftDeps.a"
    echo "           $DEPS_LIBS/libExternalDeps.a"
    echo "  stamp:   $DEPS_BUILD_STAMP"
    echo "  modules: $DEPS_MODULES/"
    echo "           $TRANSCRIPTED_CORE_MODULE"
    echo "           $ARGMAX_CORE_MODULE"
    echo "           $WHISPERKIT_MODULE"
    echo "  frameworks: $DEPS_FRAMEWORKS/ESpeakNG.framework"
    echo "              $DEPS_FRAMEWORKS/Sentry.framework"
    echo "              $DEPS_FRAMEWORKS/Sparkle.framework"
    echo "  tools:      $DEPS_TOOLS/sparkle/bin/generate_appcast"
    exit 0
fi

echo "Building FluidAudio + mlx-swift-lm + WhisperKit (unified)..."

# Build into staging directories and swap them into place only after the whole
# build succeeds. A mid-build failure (network, checksum mismatch, compile
# error) must leave the previous artifacts usable — deleting them up front
# strands the checkout with no working build.sh/run-tests.sh until a full
# successful rebuild.
FINAL_DEPS_LIBS="$DEPS_LIBS"
FINAL_DEPS_MODULES="$DEPS_MODULES"
FINAL_DEPS_FRAMEWORKS="$DEPS_FRAMEWORKS"
FINAL_DEPS_TOOLS="$DEPS_TOOLS"
DEPS_STAGING="$DRAFT_DIR/.deps-staging"
rm -rf "$DEPS_STAGING"
DEPS_LIBS="$DEPS_STAGING/deps-libs"
DEPS_BUILD_STAMP="$DEPS_LIBS/.build-deps-stamp"
DEPS_MODULES="$DEPS_STAGING/deps-modules"
DEPS_FRAMEWORKS="$DEPS_STAGING/deps-frameworks"
DEPS_TOOLS="$DEPS_STAGING/deps-tools"
mkdir -p "$DEPS_BUILD/Sources"

# Copy TranscriptedCore's source tree into $DEPS_BUILD so SPM sees a stable,
# self-contained package root. A live symlink back into the worktree can make
# long dependency builds fail with "input file ... was modified during the build"
# if the repo changes while SwiftPM is compiling.
ditto "$TRANSCRIPTED_ROOT/Sources/TranscriptedCore" "$DEPS_BUILD/TranscriptedCore"
fetch_argmax_whisperkit_sources

# Create unified Package.swift — both dependencies resolved together
cat > "$DEPS_BUILD/Package.swift" << 'PACKAGE_EOF'
// swift-tools-version:5.9
import PackageDescription
let package = Package(
    name: "DraftDeps",
    platforms: [.macOS("26.0")],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "FLUID_AUDIO_VERSION_PLACEHOLDER"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", revision: "MLX_SWIFT_LM_REVISION_PLACEHOLDER"),
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "SWIFT_TRANSFORMERS_VERSION_PLACEHOLDER"),
    ],
    targets: [
        // WhisperKit is vendored from argmaxinc/argmax-oss-swift instead of
        // consumed as a package dependency so the bundle keeps a single
        // swift-transformers pin shared with mlx-swift-lm.
        .target(
            name: "ArgmaxCore",
            dependencies: [
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "ArgmaxCore"
        ),
        .target(
            name: "WhisperKit",
            dependencies: [
                "ArgmaxCore",
                .product(name: "Hub", package: "swift-transformers"),
                .product(name: "Tokenizers", package: "swift-transformers"),
            ],
            path: "WhisperKit"
        ),
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
                "WhisperKit",
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
import WhisperKit
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
                -target air64-apple-macos26.0 \
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

touch "$DEPS_BUILD_STAMP"

# Everything succeeded — swap staged artifacts into their final locations.
# The window where old artifacts are gone is now a few renames, not the
# entire multi-minute build.
swap_in_place() {
    local staged="$1"
    local final="$2"
    rm -rf "${final}.old"
    if [ -e "$final" ]; then
        mv "$final" "${final}.old"
    fi
    mv "$staged" "$final"
    rm -rf "${final}.old"
}
swap_in_place "$DEPS_LIBS" "$FINAL_DEPS_LIBS"
swap_in_place "$DEPS_MODULES" "$FINAL_DEPS_MODULES"
swap_in_place "$DEPS_FRAMEWORKS" "$FINAL_DEPS_FRAMEWORKS"
swap_in_place "$DEPS_TOOLS" "$FINAL_DEPS_TOOLS"
rmdir "$DEPS_STAGING" 2>/dev/null || true
DEPS_LIBS="$FINAL_DEPS_LIBS"
DEPS_MODULES="$FINAL_DEPS_MODULES"
DEPS_FRAMEWORKS="$FINAL_DEPS_FRAMEWORKS"
DEPS_TOOLS="$FINAL_DEPS_TOOLS"

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
