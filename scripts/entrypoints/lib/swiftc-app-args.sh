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
#
# Outputs (bash arrays — expand with "${ARR[@]}" so paths with spaces survive):
#   APP_SWIFTC_LINK_ARGS — frameworks, libraries, and prebuilt-deps flags
#   APP_SOURCE_FILES     — app sources (Sources/TranscriptedCore excluded;
#                          Core links in via libDraftDeps.a, never directly)
#   APP_SWIFTC_TAIL_ARGS — parse/target/rpath flags placed after the sources

build_app_swiftc_args() {
    local module_root="${DEPS_MODULE_ROOT:-deps-modules}"
    local framework_root="${DEPS_FRAMEWORK_ROOT:-deps-frameworks}"

    local module_flags=("-I$module_root")
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
        -framework Sentry
        -framework Sparkle
        -lsqlite3
        -lc++
        "${module_flags[@]}"
        "-F$framework_root"
        -Ldeps-libs
        -lDraftDeps
        -framework CoreML
        -framework CoreAudio
        -framework CoreMediaIO
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
    done < <(find Sources -name '*.swift' -not -path 'Sources/TranscriptedCore/*' -print0 | sort -z)

    if [ "${#APP_SOURCE_FILES[@]}" -eq 0 ]; then
        echo "[swiftc-app-args] ERROR: no app sources found under Sources/" >&2
        return 1
    fi
}
