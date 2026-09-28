#!/usr/bin/env bash
# Type-check the app with the hill-climb lab control channel compiled in
# (#if TRANSCRIPTED_LAB_CONTROL, normally only set by `build.sh --lab`).
# Normal and release builds leave that code out, so without this nothing in CI
# notices API drift that breaks lab builds. Produces no binary, so nothing it
# checks can ship. Needs the prebuilt deps from build-deps.sh.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO_ROOT"

# shellcheck source=../entrypoints/lib/swiftc-app-args.sh
source scripts/entrypoints/lib/swiftc-app-args.sh
build_app_swiftc_args

# Only the module/framework search paths matter for type-checking; linker
# inputs are dropped so the driver doesn't warn about unused flags.
search_flags=()
for arg in "${APP_SWIFTC_LINK_ARGS[@]}"; do
    case "$arg" in
        -I*|-F*) search_flags+=("$arg") ;;
    esac
done

echo "Type-checking ${#APP_SOURCE_FILES[@]} app sources with -D TRANSCRIPTED_LAB_CONTROL..."
swiftc -typecheck \
    "${search_flags[@]}" \
    "${APP_SOURCE_FILES[@]}" \
    -parse-as-library \
    -target arm64-apple-macos26.0 \
    -D TRANSCRIPTED_LAB_CONTROL
echo "Lab build type-check passed."
