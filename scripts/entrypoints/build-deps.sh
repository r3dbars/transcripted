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
# Dual-archive naming contract (do NOT rename without updating every site):
#   libDraftDeps.a    — APP-path archive (TranscriptedCore objects + external deps).
#                       build.sh / build-beta.sh / run-integration-smoke.sh link it via
#                       `-lDraftDeps`, and exclude Sources/TranscriptedCore from their own
#                       swiftc compile so Core enters the app only through this archive.
#   libExternalDeps.a — SPM-path archive (external deps only, TranscriptedCore EXCLUDED).
#                       Package.swift links it for `swift test`, which compiles Core from
#                       source; including Core here would cause duplicate-symbol errors.
# The `libDraftDeps` filename and the `-lDraftDeps` linker flag are historical (Draft-era)
# names kept intentionally for compatibility — they are load-bearing in linker flags across
# build.sh, build-beta.sh, run-integration-smoke.sh, scripts/entrypoints/lib/swiftc-app-args.sh,
# and the two SPM manifests (Package.swift, Tools/TranscriptedCLI/Package.swift). If you ever
# rename them, grep -rn 'lDraftDeps' and grep -rn 'libDraftDeps' and update ALL sites.
DEPS_LIBS="$DRAFT_DIR/deps-libs"
DEPS_BUILD_STAMP="$DEPS_LIBS/.build-deps-stamp"
DEPS_MODULES="$DRAFT_DIR/deps-modules"
DEPS_FRAMEWORKS="$DRAFT_DIR/deps-frameworks"
DEPS_TOOLS="$DRAFT_DIR/deps-tools"
TRANSCRIPTED_CORE_MODULE="$DEPS_MODULES/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
ARGMAX_CORE_MODULE="$DEPS_MODULES/ArgmaxCore.swiftmodule/arm64-apple-macos.swiftmodule"
WHISPERKIT_MODULE="$DEPS_MODULES/WhisperKit.swiftmodule/arm64-apple-macos.swiftmodule"
FLUID_AUDIO_VERSION="${FLUID_AUDIO_VERSION:-0.15.4}"
SWIFT_TRANSFORMERS_VERSION="${SWIFT_TRANSFORMERS_VERSION:-1.2.1}"
SWIFT_JINJA_VERSION="${SWIFT_JINJA_VERSION:-2.3.6}"
SWIFT_ARGUMENT_PARSER_VERSION="${SWIFT_ARGUMENT_PARSER_VERSION:-1.7.1}"
ARGMAX_OSS_SWIFT_VERSION="${ARGMAX_OSS_SWIFT_VERSION:-v0.18.0}"
ARGMAX_OSS_SWIFT_REVISION="${ARGMAX_OSS_SWIFT_REVISION:-e2adabbe7d98dc4d0ab9a5b75424ecc42a9cdbef}"
SPARKLE_VERSION="${SPARKLE_VERSION:-2.9.1}"
SENTRY_COCOA_VERSION="${SENTRY_COCOA_VERSION:-9.10.0}"
SPARKLE_SHA256="${SPARKLE_SHA256:-9fec2b888e6e2940b1bfbd5d3d010b9f67076b52170923549095cbb74132403b}"
SENTRY_COCOA_SHA256="${SENTRY_COCOA_SHA256:-1dd70512f3b5af6c74f1b8f11279531900173fb638d7d541320a7cbc00ed06bc}"

source "$ENTRYPOINT_DIR/lib/deps-staleness.sh"

write_deps_build_stamp() {
    {
        printf 'dependency_inputs_sha256=%s\n' "$(dependency_input_digest)"
        printf 'built_at_unix=%s\n' "$(date +%s)"
    } > "$DEPS_BUILD_STAMP"
}

deps_are_ready() {
    local newest_input
    local build_stamp
    local newest_input_mtime
    local newest_input_path
    local build_stamp_mtime
    local build_stamp_path
    local current_digest
    local stamp_digest

    if [ ! -f "$DEPS_LIBS/libDraftDeps.a" ] \
        || [ ! -f "$DEPS_LIBS/libExternalDeps.a" ] \
        || [ ! -f "$DEPS_BUILD_STAMP" ] \
        || [ ! -d "$DEPS_MODULES" ] \
        || [ ! -f "$TRANSCRIPTED_CORE_MODULE" ] \
        || [ ! -f "$ARGMAX_CORE_MODULE" ] \
        || [ ! -f "$WHISPERKIT_MODULE" ] \
        || [ ! -f "$DEPS_MODULES/ArgumentParser.swiftmodule/arm64-apple-macos.swiftmodule" ] \
        || [ ! -f "$DEPS_MODULES/ArgumentParserToolInfo.swiftmodule/arm64-apple-macos.swiftmodule" ] \
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

    current_digest="$(dependency_input_digest)"
    stamp_digest="$(deps_build_stamp_digest)"
    if [ -z "$stamp_digest" ] || [ "$current_digest" != "$stamp_digest" ]; then
        echo "[build-deps] Dependencies are stale for TranscriptedCore."
        echo "[build-deps] Dependency input digest changed."
        echo "[build-deps]   current: ${current_digest:-missing}"
        echo "[build-deps]   stamp:   ${stamp_digest:-missing}"
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
    curl --fail --location --silent --show-error \
        --connect-timeout 20 --max-time 180 --retry 2 --retry-delay 2 --retry-all-errors \
        "$sparkle_url" -o "$sparkle_zip"
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
    curl --fail --location --silent --show-error \
        --connect-timeout 20 --max-time 180 --retry 2 --retry-delay 2 --retry-all-errors \
        "$sentry_url" -o "$sentry_zip"
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
    echo "  swift-transformers: $SWIFT_TRANSFORMERS_VERSION"
    echo "  swift-jinja:        $SWIFT_JINJA_VERSION"
    echo "  argument-parser:    $SWIFT_ARGUMENT_PARSER_VERSION"
    echo "  Argmax WhisperKit:  $ARGMAX_OSS_SWIFT_VERSION ($ARGMAX_OSS_SWIFT_REVISION)"

    if "${resolve_cmd[@]}"; then
        return 0
    fi

    echo "[build-deps] WARNING: initial resolve failed; retrying from a clean SwiftPM state"
    rm -rf .build Package.resolved
    "${resolve_cmd[@]}"
}

build_release_graph() {
    echo "Building (this takes several minutes on first run)..."

    if swift build --disable-dependency-cache -c release; then
        return 0
    fi

    echo "[build-deps] WARNING: release build failed; clearing package state and retrying once"
    rm -rf .build Package.resolved
    resolve_package_graph
    swift build --disable-dependency-cache -c release
}

# BEGIN dependency archive helpers
# SwiftPM also builds dependency executables (for example the encuda Metal
# build tool). Their objects are not library inputs. Inspect the entire target
# so excluding its entry point cannot leave the rest of an executable behind.
filter_library_build_dirs() {
    local directory object symbols scan_complete
    local object_files=()
    while IFS= read -r directory; do
        [ -n "$directory" ] || continue
        object_files=()
        scan_complete=false
        while IFS= read -r -d '' object; do
            if [ -z "$object" ]; then
                scan_complete=true
            else
                object_files+=("$object")
            fi
        # An empty NUL record cannot be a path. Emit this completion marker
        # only on success so process substitution cannot hide a find failure.
        done < <(find "$directory" -type f -name '*.o' -print0 && printf '\0')
        if [ "$scan_complete" != true ]; then
            echo "[build-deps] ERROR: Could not enumerate target objects: $directory" >&2
            return 1
        fi
        [ "${#object_files[@]}" -gt 0 ] || continue

        # -U: defined only; -g: external only; -j: symbol names only.
        # Both llvm-nm and Apple's nm support these flags. Never treat an nm
        # failure as evidence that a target has no executable entry point.
        if ! symbols=$("$NM_BIN" -U -g -j "${object_files[@]}"); then
            echo "[build-deps] ERROR: Could not inspect target objects: $directory" >&2
            return 1
        fi
        if printf '%s\n' "$symbols" | grep -x '_main' >/dev/null; then
            echo "[build-deps] Excluding executable target: $directory" >&2
        else
            printf '%s\n' "$directory"
        fi
    done <<< "$1"
}

assert_no_archive_entry_point() {
    local archive="$1"
    local symbols
    if ! symbols=$("$NM_BIN" -U -g -j "$archive"); then
        echo "[build-deps] ERROR: Could not inspect dependency archive: $archive" >&2
        return 1
    fi
    if printf '%s\n' "$symbols" | grep -x '_main' >/dev/null; then
        echo "[build-deps] ERROR: Dependency archive defines executable entry point _main: $archive" >&2
        return 1
    fi
}
# END dependency archive helpers

# BEGIN dependency module helpers
copy_swift_module_artifact() {
    local module_input="$1"
    local name module_file source_file suffix
    name=$(basename "$module_input" .swiftmodule)
    if [ -d "$module_input" ]; then
        module_file="$module_input/arm64-apple-macos.swiftmodule"
    else
        module_file="$module_input"
    fi
    if [ ! -f "$module_file" ]; then
        echo "[build-deps] ERROR: Module file missing for $name: $module_file" >&2
        return 1
    fi
    mkdir -p "$DEPS_MODULES/$name.swiftmodule" || return 1
    for suffix in swiftmodule swiftdoc swiftinterface; do
        if [ -d "$module_input" ]; then
            source_file="$module_input/arm64-apple-macos.$suffix"
        else
            source_file="${module_input%.swiftmodule}.$suffix"
        fi
        if [ -f "$source_file" ]; then
            cp "$source_file" "$DEPS_MODULES/$name.swiftmodule/arm64-apple-macos.$suffix" || return 1
        fi
    done
}

argument_parser_module_source() {
    local name="$1"
    local directory target_directory target_name
    local normal_target=false tool_target=false
    # Use the filtered object inputs, not module-file presence: native SwiftPM
    # can compile these libraries only for a host tool and place their modules
    # in Modules-tool while the matching objects live in *-tool.build.
    while IFS= read -r directory; do
        target_directory="${directory%/Objects-normal/arm64}"
        target_name="${target_directory##*/}"
        case "$target_name" in
            "$name.build"|"$name-t.build") normal_target=true ;;
            "$name-tool.build"|"$name-tool-t.build") tool_target=true ;;
        esac
    done <<< "$ALL_BUILD_DIRS"
    if [ "$normal_target" = true ] && [ "$tool_target" = true ]; then
        echo "[build-deps] ERROR: Ambiguous normal/tool archive inputs for $name" >&2
        return 1
    fi
    if [ "$tool_target" = true ]; then
        if [ "$SPM_OUTPUT_LAYOUT" != legacy ]; then
            echo "[build-deps] ERROR: Unsupported host-tool module layout for $name: $SPM_OUTPUT_LAYOUT" >&2
            return 1
        fi
        printf '%s\n' "$BUILD_PRODUCTS/Modules-tool/$name.swiftmodule"
    elif [ "$normal_target" = true ]; then
        printf '%s\n' "$MODULES_SRC/$name.swiftmodule"
    else
        echo "[build-deps] ERROR: No archived library target found for $name" >&2
        return 1
    fi
}

export_argument_parser_modules() {
    local name module_input
    for name in ArgumentParser ArgumentParserToolInfo; do
        module_input="$(argument_parser_module_source "$name")" || return 1
        echo "[build-deps] Exporting $name from $module_input"
        copy_swift_module_artifact "$module_input" || return 1
    done
}
# END dependency module helpers

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

echo "Building FluidAudio + WhisperKit (unified)..."

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
TRANSCRIPTED_CORE_MODULE="$DEPS_MODULES/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
ARGMAX_CORE_MODULE="$DEPS_MODULES/ArgmaxCore.swiftmodule/arm64-apple-macos.swiftmodule"
WHISPERKIT_MODULE="$DEPS_MODULES/WhisperKit.swiftmodule/arm64-apple-macos.swiftmodule"
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
        .package(url: "https://github.com/huggingface/swift-transformers", exact: "SWIFT_TRANSFORMERS_VERSION_PLACEHOLDER"),
        // The bundled CLI builds against the ArgumentParser modules exported
        // from this graph (export_argument_parser_modules).
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "SWIFT_ARGUMENT_PARSER_VERSION_PLACEHOLDER"),
        // swift-transformers 1.2.1 still uses String-keyed Jinja objects.
        // swift-jinja 2.4.0 changed those keys to ObjectKey and does not compile
        // with that pinned transformers release, so keep the last compatible tag.
        .package(url: "https://github.com/huggingface/swift-jinja.git", exact: "SWIFT_JINJA_VERSION_PLACEHOLDER"),
    ],
    targets: [
        // WhisperKit is vendored from argmaxinc/argmax-oss-swift instead of
        // consumed as a package dependency so the bundle keeps one pinned
        // swift-transformers.
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
        // mega-library. Inlining as a target here makes FluidAudio
        // available through normal SPM dependency edges, producing a real
        // TranscriptedCore.swiftmodule that build-deps.sh copies into
        // deps-modules/ for build.sh to consume.
        .target(
            name: "TranscriptedCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "TranscriptedCore",
            exclude: ["CLAUDE.md"]
        ),
        .target(
            name: "Shim",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                "WhisperKit",
                "TranscriptedCore",
            ],
            path: "Sources"
        )
    ]
)
PACKAGE_EOF

FLUID_AUDIO_VERSION="$FLUID_AUDIO_VERSION" \
SWIFT_TRANSFORMERS_VERSION="$SWIFT_TRANSFORMERS_VERSION" \
SWIFT_JINJA_VERSION="$SWIFT_JINJA_VERSION" \
SWIFT_ARGUMENT_PARSER_VERSION="$SWIFT_ARGUMENT_PARSER_VERSION" \
perl -0pi \
    -e 's/FLUID_AUDIO_VERSION_PLACEHOLDER/$ENV{FLUID_AUDIO_VERSION}/g; s/SWIFT_TRANSFORMERS_VERSION_PLACEHOLDER/$ENV{SWIFT_TRANSFORMERS_VERSION}/g; s/SWIFT_JINJA_VERSION_PLACEHOLDER/$ENV{SWIFT_JINJA_VERSION}/g; s/SWIFT_ARGUMENT_PARSER_VERSION_PLACEHOLDER/$ENV{SWIFT_ARGUMENT_PARSER_VERSION}/g' \
    "$DEPS_BUILD/Package.swift"

cat > "$DEPS_BUILD/Sources/Shim.swift" << 'SWIFT_EOF'
import ArgumentParser
import FluidAudio
import TranscriptedCore
import WhisperKit
SWIFT_EOF

# Build in release mode
cd "$DEPS_BUILD"
export FLUID_AUDIO_VERSION
export SWIFT_TRANSFORMERS_VERSION
export SWIFT_JINJA_VERSION
export SWIFT_ARGUMENT_PARSER_VERSION
resolve_package_graph
build_release_graph

# Ask SwiftPM for its release products instead of assuming one output layout.
# Swift 6.4 can put products under .build/out/Products/Release and objects under
# .build/out/Intermediates.noindex; older toolchains keep both in the release dir.
BUILD_PRODUCTS="$(swift build -c release --show-bin-path)"
if [ -d "$DEPS_BUILD/.build/out/Intermediates.noindex" ]; then
    BUILD_RELEASE="$DEPS_BUILD/.build/out/Intermediates.noindex"
    MODULES_SRC="$BUILD_PRODUCTS"
    SPM_OUTPUT_LAYOUT="xcode"
else
    BUILD_RELEASE="$BUILD_PRODUCTS"
    MODULES_SRC="$BUILD_PRODUCTS/Modules"
    SPM_OUTPUT_LAYOUT="legacy"
fi
if [ ! -d "$BUILD_RELEASE" ] || [ ! -d "$MODULES_SRC" ]; then
    echo "[build-deps] ERROR: SwiftPM release objects or modules directory is missing" >&2
    echo "[build-deps] objects: $BUILD_RELEASE" >&2
    echo "[build-deps] modules: $MODULES_SRC" >&2
    exit 1
fi
echo "[build-deps] SwiftPM output layout: $SPM_OUTPUT_LAYOUT"
CHECKOUTS="$DEPS_BUILD/.build/checkouts"

# Create output directories
mkdir -p "$DEPS_LIBS" "$DEPS_MODULES" "$DEPS_FRAMEWORKS"

# --- Static library: combine all .o files into one .a ---
echo "Creating static library..."
cd "$BUILD_RELEASE"

# Find compiled target objects, excluding the import-only Shim target.
NM_BIN="$(xcrun --find llvm-nm 2>/dev/null || command -v nm)"
if [ "$SPM_OUTPUT_LAYOUT" = "xcode" ]; then
    ALL_BUILD_DIRS=$(find . -type d -path "*/Release/*.build/Objects-normal/arm64" \
        ! -path "*/Release/Shim*.build/Objects-normal/arm64" | sort)
    EXTERNAL_DIRS=$(find . -type d -path "*/Release/*.build/Objects-normal/arm64" \
        ! -path "*/Release/Shim*.build/Objects-normal/arm64" \
        ! -path "*/Release/TranscriptedCore*.build/Objects-normal/arm64" | sort)
else
    ALL_BUILD_DIRS=$(find . -maxdepth 1 -name "*.build" -type d | grep -v "Shim.build" | sort)
    EXTERNAL_DIRS=$(find . -maxdepth 1 -name "*.build" -type d \
        | grep -v "Shim.build" | grep -v "TranscriptedCore.build" | sort)
fi
ALL_BUILD_DIRS="$(filter_library_build_dirs "$ALL_BUILD_DIRS")"
EXTERNAL_DIRS="$(filter_library_build_dirs "$EXTERNAL_DIRS")"
if [ -z "$ALL_BUILD_DIRS" ] || [ -z "$EXTERNAL_DIRS" ]; then
    echo "[build-deps] ERROR: No SwiftPM release target object directories found" >&2
    exit 1
fi
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
find $EXTERNAL_DIRS -name "*.o" -print0 | xargs -0 ar rcs "$DEPS_LIBS/libExternalDeps.a"
EXT_COUNT=$(ar t "$DEPS_LIBS/libExternalDeps.a" | wc -l | tr -d ' ')
echo "  $EXT_COUNT object files archived (external-only, no TranscriptedCore)"

# Validate the finished archives too: a future directory/layout change must
# fail here instead of surfacing later as a duplicate _main in a consumer.
assert_no_archive_entry_point "$DEPS_LIBS/libDraftDeps.a"
assert_no_archive_entry_point "$DEPS_LIBS/libExternalDeps.a"

# --- Object-count assertions ---
# The bare echoes above are not enough: an empty find/ar can produce a 0-object archive
# that still "looks" built. Fail fast if either archive is empty, and require the external
# archive to be strictly smaller than the app archive (it must lack TranscriptedCore's objects).
if [ "$OBJ_COUNT" -le 0 ]; then
    echo "[build-deps] ERROR: libDraftDeps.a contains $OBJ_COUNT object files — expected > 0."
    echo "[build-deps]        The app-path archive is empty; the release build under $BUILD_RELEASE produced no .o files."
    exit 1
fi
if [ "$EXT_COUNT" -le 0 ]; then
    echo "[build-deps] ERROR: libExternalDeps.a contains $EXT_COUNT object files — expected > 0."
    echo "[build-deps]        The SPM-path archive is empty; the EXTERNAL_DIRS find produced no .o files."
    exit 1
fi
if [ "$EXT_COUNT" -ge "$OBJ_COUNT" ]; then
    echo "[build-deps] ERROR: libExternalDeps.a ($EXT_COUNT objects) is not smaller than libDraftDeps.a ($OBJ_COUNT objects)."
    echo "[build-deps]        The external archive must exclude TranscriptedCore's objects, so it must contain strictly fewer."
    echo "[build-deps]        Check the EXTERNAL_DIRS 'grep -v TranscriptedCore.build' filter above."
    exit 1
fi

# --- Symbol-level validation gate ---
# Object counts only prove the archives are non-empty and differently sized. They do not prove
# TranscriptedCore actually landed in the app archive (and only the app archive). Validate the
# real symbol tables: libDraftDeps.a must define TranscriptedCore symbols, libExternalDeps.a
# must define NONE. '16TranscriptedCore' is the Swift mangled-name token for the module
# (16 = byte length of "TranscriptedCore"); if the Core module is ever renamed, update this
# token to '<len><NewModuleName>'. Count with --defined-only so the external archive's
# undefined references to Core (legitimate cross-archive links) are not miscounted as
# contamination.
echo "Validating TranscriptedCore symbol placement (nm: $NM_BIN)..."
# grep -c exits 1 on zero matches; under `set -euo pipefail` that would abort the
# command substitution, so swallow grep's exit status while keeping its "0" count.
APP_CORE_SYMBOLS=$({ "$NM_BIN" --defined-only "$DEPS_LIBS/libDraftDeps.a" 2>/dev/null | grep -c '16TranscriptedCore'; } || true)
EXT_CORE_SYMBOLS=$({ "$NM_BIN" --defined-only "$DEPS_LIBS/libExternalDeps.a" 2>/dev/null | grep -c '16TranscriptedCore'; } || true)
if [ "$APP_CORE_SYMBOLS" -le 0 ]; then
    echo "[build-deps] ERROR: libDraftDeps.a defines $APP_CORE_SYMBOLS TranscriptedCore symbols — expected > 0."
    echo "[build-deps]        The app-path archive is missing Core; build.sh excludes Sources/TranscriptedCore"
    echo "[build-deps]        from its own swiftc compile, so the app would fail to link Core symbols."
    exit 1
fi
if [ "$EXT_CORE_SYMBOLS" -gt 0 ]; then
    echo "[build-deps] ERROR: libExternalDeps.a defines $EXT_CORE_SYMBOLS TranscriptedCore symbols — expected 0."
    echo "[build-deps]        The SPM-path archive is contaminated with TranscriptedCore objects, which causes"
    echo "[build-deps]        duplicate-symbol linker errors under 'swift test' (Core also compiles from source there)."
    echo "[build-deps]        Check the EXTERNAL_DIRS 'grep -v TranscriptedCore.build' exclusion above."
    exit 1
fi
echo "  libDraftDeps.a defines $APP_CORE_SYMBOLS TranscriptedCore symbols; libExternalDeps.a defines $EXT_CORE_SYMBOLS"

# --- Swift modules ---
echo "Copying Swift modules..."
for mod in "$MODULES_SRC"/*.swiftmodule; do
    [ -e "$mod" ] || continue
    name=$(basename "$mod" .swiftmodule)
    # Shim is import-only. Parser modules are selected separately to match
    # their archived normal/tool targets, never whichever interface is first.
    case "$name" in Shim|ArgumentParser|ArgumentParserToolInfo) continue ;; esac
    copy_swift_module_artifact "$mod"
done
export_argument_parser_modules
if [ ! -f "$TRANSCRIPTED_CORE_MODULE" ]; then
    echo "[build-deps] ERROR: TranscriptedCore module was not copied from $MODULES_SRC" >&2
    exit 1
fi

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
# FluidAudio 0.15.x no longer vendors the ESpeakNG binary target; drop any stale
# copy from an older deps build instead of failing.
if [ -z "$ESPEAK_FRAMEWORK_SRC" ]; then
    echo "[build-deps] ESpeakNG.framework not in resolved dependencies (expected on FluidAudio >= 0.15); skipping copy"
    rm -rf "$DEPS_FRAMEWORKS/ESpeakNG.framework"
else
    rm -rf "$DEPS_FRAMEWORKS/ESpeakNG.framework"
    ditto "$ESPEAK_FRAMEWORK_SRC" "$DEPS_FRAMEWORKS/ESpeakNG.framework"
fi

download_sentry_distribution
download_sparkle_distribution

cd "$DRAFT_DIR"
write_deps_build_stamp
if ! deps_are_ready; then
    echo "[build-deps] ERROR: Staged dependency bundle is incomplete; retaining previous artifacts" >&2
    exit 1
fi

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
TRANSCRIPTED_CORE_MODULE="$DEPS_MODULES/TranscriptedCore.swiftmodule/arm64-apple-macos.swiftmodule"
ARGMAX_CORE_MODULE="$DEPS_MODULES/ArgmaxCore.swiftmodule/arm64-apple-macos.swiftmodule"
WHISPERKIT_MODULE="$DEPS_MODULES/WhisperKit.swiftmodule/arm64-apple-macos.swiftmodule"

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
