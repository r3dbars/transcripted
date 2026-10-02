# shellcheck shell=bash
# Shared swiftc argument construction for the Transcripted app target.
# Sourced by build.sh and build-beta.sh so the dev build and the shipped
# build cannot silently diverge on frameworks, linker inputs, or the source
# list. (They had already diverged once: build.sh linked ScreenCaptureKit but
# not sqlite3, build-beta.sh the reverse — each worked only via autolink.)
#
# Inputs (optional; default to the repo-root-relative layout):
#   DEPS_MODULE_ROOT     — deps-modules directory
#   DEPS_FRAMEWORK_ROOT  — deps-frameworks directory
#   WRITING_CORE_BUILD_DIR    — where the WritingCore module lands
#                               (default build/modules)
#   WRITING_CORE_SWIFTC_FLAGS — bash array of optimization/debug flags for
#                               WritingCore (default: -O -whole-module-optimization).
#                               build-beta.sh passes its debug-info flags so the
#                               dSYM covers WritingCore too.
#
# Outputs (bash arrays — expand with "${ARR[@]}" so paths with spaces survive):
#   APP_SWIFTC_LINK_ARGS — frameworks, libraries, and prebuilt-deps flags
#   APP_SOURCE_FILES     — app sources (Sources/TranscriptedCore excluded;
#                          Core links in via libDraftDeps.a, never directly.
#                          Sources/TranscriptedWriting/Core excluded: it's the
#                          TranscriptedWritingCore module, built first by
#                          build_writing_core_module and linked statically.
#                          Sources/TranscriptedKeyboard excluded too: the
#                          Writing keyboard is its own IMKit executable, built
#                          by lib/bundle-input-method.sh into Contents/Library)
#   APP_SWIFTC_TAIL_ARGS — parse/target/rpath flags placed after the sources

# WritingCore (Sources/TranscriptedWriting/Core) is pure Foundation/CryptoKit
# policy with no edges back into the app, so it compiles as its own static
# Swift module, TranscriptedWritingCore. App files reach it with
# `#if canImport(TranscriptedWritingCore) import TranscriptedWritingCore`; the
# guard keeps the fast-test runner and smokes working, since they compile the
# few Core files they need straight into their own module.
build_writing_core_module() {
    local out_dir="$1"
    local opt_flags=(-O -whole-module-optimization)
    if [ -n "${WRITING_CORE_SWIFTC_FLAGS+x}" ]; then
        opt_flags=(${WRITING_CORE_SWIFTC_FLAGS[@]+"${WRITING_CORE_SWIFTC_FLAGS[@]}"})
    fi

    local core_sources=()
    local file
    while IFS= read -r -d '' file; do
        core_sources+=("$file")
    done < <(find Sources/TranscriptedWriting/Core -name '*.swift' -print0 | sort -z)
    if [ "${#core_sources[@]}" -eq 0 ]; then
        echo "[swiftc-app-args] ERROR: no WritingCore sources under Sources/TranscriptedWriting/Core" >&2
        return 1
    fi

    mkdir -p "$out_dir"
    rm -f "$out_dir/libTranscriptedWritingCore.a" "$out_dir"/TranscriptedWritingCore.*
    echo "Compiling TranscriptedWritingCore module (${#core_sources[@]} files)..."
    if ! swiftc \
        -module-name TranscriptedWritingCore \
        -parse-as-library \
        -target arm64-apple-macos26.0 \
        ${opt_flags[@]+"${opt_flags[@]}"} \
        -emit-module \
        -emit-module-path "$out_dir/TranscriptedWritingCore.swiftmodule" \
        -emit-library -static \
        -o "$out_dir/libTranscriptedWritingCore.a" \
        "${core_sources[@]}"; then
        echo "[swiftc-app-args] ERROR: TranscriptedWritingCore failed to compile" >&2
        return 1
    fi
}

build_app_swiftc_args() {
    local module_root="${DEPS_MODULE_ROOT:-deps-modules}"
    local framework_root="${DEPS_FRAMEWORK_ROOT:-deps-frameworks}"

    local writing_core_dir="${WRITING_CORE_BUILD_DIR:-build/modules}"
    build_writing_core_module "$writing_core_dir" || return 1

    local module_flags=("-I$module_root" "-I$writing_core_dir")
    local dir
    for dir in "$module_root"/*/; do
        [ -d "$dir" ] || continue
        case "$(basename "$dir")" in
            *.swiftmodule) continue ;;
        esac
        module_flags+=("-I$dir")
    done

    APP_SWIFTC_LINK_ARGS=(
        -framework AVFoundation
        -framework AppKit
        -framework SwiftUI
        -framework Combine
        -framework EventKit
        -framework Security
        -framework Carbon
        -framework Metal
        -framework MetalKit
        -framework Accelerate
        -framework Vision
        -framework FoundationModels
        -framework MetalPerformanceShaders
        -framework MetalPerformanceShadersGraph
        -framework Network
        -framework ScreenCaptureKit
        -framework Speech
        -framework Sentry
        -framework Sparkle
        -lsqlite3
        -lc++
        "${module_flags[@]}"
        "-F$framework_root"
        -Ldeps-libs
        -lDraftDeps
        "-L$writing_core_dir"
        -lTranscriptedWritingCore
        -framework CoreML
        -framework CoreAudio
        -framework CoreMediaIO
        -framework IOKit
    )

    APP_SWIFTC_TAIL_ARGS=(
        -parse-as-library
        -target arm64-apple-macos26.0
        -Xlinker -rpath -Xlinker @executable_path/../Frameworks
    )

    APP_SOURCE_FILES=()
    local file
    while IFS= read -r -d '' file; do
        APP_SOURCE_FILES+=("$file")
    done < <(find Sources -name '*.swift' \
        -not -path 'Sources/TranscriptedCore/*' \
        -not -path 'Sources/TranscriptedWriting/Core/*' \
        -not -path 'Sources/TranscriptedKeyboard/*' \
        -print0 | sort -z)

    if [ "${#APP_SOURCE_FILES[@]}" -eq 0 ]; then
        echo "[swiftc-app-args] ERROR: no app sources found under Sources/" >&2
        return 1
    fi
}
