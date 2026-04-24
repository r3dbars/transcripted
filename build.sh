#!/bin/bash
# Build Transcripted - local dictation + meeting transcription app

set -euo pipefail

APP_NAME="Transcripted"
BUILD_DIR="build"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
STAGED_APP_BINARY="$BUILD_DIR/$APP_NAME-bin"
LOCAL_ENTITLEMENTS="config/entitlements/local.plist"
SIGN_IDENTITY="${SIGN_IDENTITY:-${SIGNING_IDENTITY:-}}"
DEPS_ARCHIVE="deps-libs/libDraftDeps.a"
DEPS_MODULE_ROOT="deps-modules"
DEPS_FRAMEWORK_ROOT="deps-frameworks"
ESPEAK_FRAMEWORK="$DEPS_FRAMEWORK_ROOT/ESpeakNG.framework"
TRANSCRIPTED_CORE_MODULE="$DEPS_MODULE_ROOT/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"

ensure_build_prerequisites() {
    if [ ! -f "$LOCAL_ENTITLEMENTS" ]; then
        echo "Missing entitlements file: $LOCAL_ENTITLEMENTS"
        exit 1
    fi
}

ensure_deps_ready() {
    if [ -f "$DEPS_ARCHIVE" ] && [ -d "$DEPS_MODULE_ROOT" ] && [ -f "$TRANSCRIPTED_CORE_MODULE" ] && [ -d "$ESPEAK_FRAMEWORK" ]; then
        return 0
    fi

    echo "Dependencies missing or stale for TranscriptedCore."
    echo "Expected:"
    echo "  $DEPS_ARCHIVE"
    echo "  $DEPS_MODULE_ROOT/"
    echo "  $TRANSCRIPTED_CORE_MODULE"
    echo "  $ESPEAK_FRAMEWORK"
    echo ""
    echo "Run: bash build-deps.sh --force"
    exit 1
}

resolve_sign_identity() {
    local requested_identity="$1"
    local found_line

    if [ -n "$requested_identity" ]; then
        found_line="$(security find-identity -v -p codesigning 2>/dev/null | grep -F "$requested_identity" | head -1 || true)"
        if [ -z "$found_line" ]; then
            echo "Requested signing identity not found: $requested_identity"
            echo "Available identities:"
            security find-identity -v -p codesigning || true
            exit 1
        fi
        printf '%s\n' "$found_line"
        return 0
    fi

    found_line="$(security find-identity -v -p codesigning 2>/dev/null | grep "Developer ID Application" | head -1 || true)"
    if [ -n "$found_line" ]; then
        printf '%s\n' "$found_line"
        return 0
    fi

    printf '%s\n' ""
}

verify_signature() {
    codesign --verify --deep --strict --verbose=4 "$APP_BUNDLE"
    codesign -dvvv --entitlements - "$APP_BUNDLE"
}

sign_embedded_frameworks() {
    local sign_hash="$1"
    local framework_path

    for framework_path in "$APP_BUNDLE"/Contents/Frameworks/*.framework; do
        [ -d "$framework_path" ] || continue
        codesign --force --sign "$sign_hash" "$framework_path"
    done
}

sign_embedded_runtime_assets() {
    local sign_hash="$1"
    local asset_path

    for asset_path in "$APP_BUNDLE"/Contents/MacOS/*.metallib; do
        [ -f "$asset_path" ] || continue
        codesign --force --sign "$sign_hash" "$asset_path"
    done
}

echo "Building Transcripted..."

ensure_build_prerequisites
ensure_deps_ready

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$APP_BUNDLE/Contents/Frameworks"

# Bundle Parakeet model directories used by FluidAudio.
# The runtime loader can resolve files from both the `-coreml` and legacy
# `parakeet-tdt-0.6b-v3` layouts, so ship both when present.
PARAKEET_MODELS_ROOT="$HOME/Library/Application Support/FluidAudio/Models"
PARAKEET_BUNDLE_DIR="$APP_BUNDLE/Contents/Resources/parakeet-models"
PARAKEET_MODEL_DIRS=(
    "parakeet-tdt-0.6b-v3-coreml"
    "parakeet-tdt-0.6b-v3"
)

bundled_parakeet_models=false
mkdir -p "$PARAKEET_BUNDLE_DIR"
for model_dir in "${PARAKEET_MODEL_DIRS[@]}"; do
    model_src="$PARAKEET_MODELS_ROOT/$model_dir"
    if [ -d "$model_src/Encoder.mlmodelc" ]; then
        echo "Bundling Parakeet models from $model_dir..."
        rm -rf "$PARAKEET_BUNDLE_DIR/$model_dir"
        ditto "$model_src" "$PARAKEET_BUNDLE_DIR/$model_dir"
        bundled_parakeet_models=true
    fi
done

if [ "$bundled_parakeet_models" = false ]; then
    echo "Parakeet models not found — Parakeet engine will attempt runtime download"
fi

# Copy Info.plist
cp Info.plist "$APP_BUNDLE/Contents/"

# Copy bundled app resources (custom sounds, etc.) when present
if [ -d "Resources" ]; then
    cp -R Resources/. "$APP_BUNDLE/Contents/Resources/"
fi

# Unified dependencies (FluidAudio + mlx-swift-lm)
echo "Dependencies found"

# Build the -I flags for all module directories
DEPS_MODULE_FLAGS="-I$DEPS_MODULE_ROOT"
for dir in "$DEPS_MODULE_ROOT"/*/; do
    [ -d "$dir" ] || continue
    case "$(basename "$dir")" in
        *.swiftmodule) continue ;;
    esac
    DEPS_MODULE_FLAGS="$DEPS_MODULE_FLAGS -I$dir"
done

DEPS_FLAGS="$DEPS_MODULE_FLAGS -F$DEPS_FRAMEWORK_ROOT -Ldeps-libs -lDraftDeps -framework ESpeakNG -framework CoreML -framework CoreAudio"

# Bundle Metal libraries if present
# MLX searches for mlx.metallib next to the binary first (Contents/MacOS/)
for metallib in deps-libs/*.metallib; do
    [ -f "$metallib" ] && cp "$metallib" "$APP_BUNDLE/Contents/MacOS/"
done

# Bundle FluidAudio's binary framework dependency.
cp -R "$ESPEAK_FRAMEWORK" "$APP_BUNDLE/Contents/Frameworks/"

# Compile
echo "Compiling..."
SOURCE_FILES=$(find Sources -name '*.swift' -not -path 'Sources/TranscriptedCore/*')
rm -f "$STAGED_APP_BINARY"
swiftc \
    -O \
    -o "$STAGED_APP_BINARY" \
    -framework AVFoundation \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework EventKit \
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
    $SOURCE_FILES \
    -parse-as-library \
    -target arm64-apple-macos14.0 \
    -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    2>&1

mv "$STAGED_APP_BINARY" "$APP_BINARY"

if [ ! -x "$APP_BINARY" ]; then
    echo "Build finished without a runnable app binary: $APP_BINARY"
    exit 1
fi

SIGN_MATCH="$(resolve_sign_identity "$SIGN_IDENTITY")"
SIGN_HASH=""
SIGN_NAME=""
if [ -n "$SIGN_MATCH" ]; then
    SIGN_HASH="$(echo "$SIGN_MATCH" | awk '{print $2}')"
    SIGN_NAME="$(echo "$SIGN_MATCH" | sed 's/.*"\(.*\)"/\1/')"
fi

if [ -n "$SIGN_HASH" ]; then
    echo "Signing with: ${SIGN_NAME:-$SIGN_HASH} ($SIGN_HASH)"
    sign_embedded_frameworks "$SIGN_HASH"
    sign_embedded_runtime_assets "$SIGN_HASH"
    codesign --force --sign "$SIGN_HASH" \
        --entitlements "$LOCAL_ENTITLEMENTS" \
        "$APP_BUNDLE"
else
    echo "No Developer ID found — signing ad-hoc (permissions may not persist)"
    sign_embedded_frameworks "-"
    sign_embedded_runtime_assets "-"
    codesign --force --sign - \
        --entitlements "$LOCAL_ENTITLEMENTS" \
        "$APP_BUNDLE"
fi

echo "Verifying signature..."
verify_signature

if [ -n "$SIGN_HASH" ] && codesign -dv "$APP_BUNDLE" 2>&1 | grep -q "Signature=adhoc"; then
    echo "Expected Developer ID signature but binary is ad-hoc."
    exit 1
fi

echo "Build complete!"
echo "Launching Transcripted..."
open "$APP_BUNDLE"
