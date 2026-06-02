#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: bash scripts/release/register-sentry-release.sh [version]"
    echo ""
    echo "Creates and finalizes the Sentry release matching Info.plist."
    echo "Requires and uploads the matching release dSYM by default."
    echo "Defaults: SENTRY_ORG=r3dbars, SENTRY_PROJECT=apple-macos"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

VERSION_ARG="${1:-}"
ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

INFO_PLIST_PATH="${INFO_PLIST_PATH:-Info.plist}"
SENTRY_ORG="${SENTRY_ORG:-r3dbars}"
SENTRY_PROJECT="${SENTRY_PROJECT:-apple-macos}"
SENTRY_REPOSITORY="${SENTRY_REPOSITORY:-r3dbars/transcripted}"
SENTRY_SET_COMMITS="${SENTRY_SET_COMMITS:-1}"
SENTRY_UPLOAD_DEBUG_FILES="${SENTRY_UPLOAD_DEBUG_FILES:-1}"
SENTRY_REQUIRE_DEBUG_FILES="${SENTRY_REQUIRE_DEBUG_FILES:-1}"
SENTRY_DEBUG_FILES_PATH="${SENTRY_DEBUG_FILES_PATH:-build/Transcripted.app.dSYM}"
SENTRY_APP_BINARY_PATH="${SENTRY_APP_BINARY_PATH:-build/Transcripted.app/Contents/MacOS/Transcripted}"

if ! command -v sentry-cli >/dev/null 2>&1; then
    echo "Missing sentry-cli."
    echo "Install it, or run build-deps/release setup on a machine that has it."
    exit 1
fi

if [ ! -f "$INFO_PLIST_PATH" ]; then
    echo "Info.plist not found: $INFO_PLIST_PATH"
    exit 1
fi

SENTRY_METADATA="$(python3 scripts/release/sentry-release-metadata.py --format shell "$INFO_PLIST_PATH")"
eval "$SENTRY_METADATA"

if [ -n "$VERSION_ARG" ] && [ "$VERSION_ARG" != "$APP_VERSION" ]; then
    echo "Version mismatch."
    echo "  requested: $VERSION_ARG"
    echo "  Info.plist: $APP_VERSION"
    exit 1
fi

sentry_release_exists() {
    sentry-cli releases info \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        "$SENTRY_RELEASE" >/dev/null 2>&1
}

sentry_commit_spec() {
    local release_tag="v${APP_VERSION}"
    local release_commit
    local previous_tag
    local previous_commit

    if ! release_commit="$(git rev-parse --verify "${release_tag}^{commit}" 2>/dev/null)"; then
        echo "Missing release tag: ${release_tag}" >&2
        echo "Publish or fetch the matching tag before setting Sentry commits, or set SENTRY_SET_COMMITS=0." >&2
        return 1
    fi

    previous_tag="$(
        {
            git tag --merged "$release_commit" --sort=-v:refname 'v[0-9]*' \
                | grep -v -F -x "$release_tag" \
                | head -n 1
        } || true
    )"
    if [ -n "$previous_tag" ] && previous_commit="$(git rev-parse --verify "${previous_tag}^{commit}" 2>/dev/null)"; then
        echo "${SENTRY_REPOSITORY}@${previous_commit}..${release_commit}"
    else
        echo "${SENTRY_REPOSITORY}@${release_commit}"
    fi
}

uuid_set_for_path() {
    local path="$1"
    dwarfdump --uuid "$path" 2>/dev/null | awk '/^UUID:/ { print $2 }' | sort -u
}

print_uuid_set() {
    local value="$1"

    if [ -n "$value" ]; then
        printf '%s\n' "$value" | sed 's/^/    /' >&2
    else
        echo "    [none]" >&2
    fi
}

verify_debug_file_match() {
    local binary_path="$1"
    local debug_files_path="$2"
    local binary_uuids
    local debug_file_uuids

    if ! command -v dwarfdump >/dev/null 2>&1; then
        echo "Missing dwarfdump; cannot verify that Sentry debug files match the app binary." >&2
        echo "Install Xcode command line tools before registering a shipped release." >&2
        return 1
    fi

    if [ ! -e "$binary_path" ]; then
        echo "Missing app binary for Sentry debug-file match verification: $binary_path" >&2
        echo "Keep the release app bundle next to the dSYM, or set SENTRY_APP_BINARY_PATH to the matching app binary." >&2
        return 1
    fi

    if ! binary_uuids="$(uuid_set_for_path "$binary_path")"; then
        echo "Could not read UUIDs from app binary: $binary_path" >&2
        return 1
    fi

    if ! debug_file_uuids="$(uuid_set_for_path "$debug_files_path")"; then
        echo "Could not read UUIDs from Sentry debug files: $debug_files_path" >&2
        return 1
    fi

    if [ -z "$binary_uuids" ] || [ -z "$debug_file_uuids" ]; then
        echo "Sentry debug-file UUID verification failed." >&2
        echo "  app binary: $binary_path" >&2
        echo "  app UUID(s):" >&2
        print_uuid_set "$binary_uuids"
        echo "  debug files: $debug_files_path" >&2
        echo "  debug UUID(s):" >&2
        print_uuid_set "$debug_file_uuids"
        return 1
    fi

    if [ "$binary_uuids" != "$debug_file_uuids" ]; then
        echo "Sentry debug files do not match the app binary." >&2
        echo "  app binary: $binary_path" >&2
        echo "  app UUID(s):" >&2
        print_uuid_set "$binary_uuids"
        echo "  debug files: $debug_files_path" >&2
        echo "  debug UUID(s):" >&2
        print_uuid_set "$debug_file_uuids"
        echo "Rebuild with build-beta.sh, or point SENTRY_DEBUG_FILES_PATH and SENTRY_APP_BINARY_PATH at the matching artifact pair." >&2
        return 1
    fi

    echo "Verified Sentry debug files match the app binary UUID(s):"
    printf '%s\n' "$binary_uuids" | sed 's/^/  /'
}

echo "Sentry release: $SENTRY_RELEASE"
echo "Sentry dist: $SENTRY_DIST"
echo "Sentry project: $SENTRY_ORG/$SENTRY_PROJECT"

if sentry_release_exists; then
    echo "Sentry release already exists."
    echo "Skipping finalize so reruns do not change the existing release date."
else
    sentry-cli releases new \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        --finalize \
        "$SENTRY_RELEASE"
fi

if [ "$SENTRY_SET_COMMITS" = "1" ]; then
    COMMIT_SPEC="$(sentry_commit_spec)"
    echo "Sentry commit spec: $COMMIT_SPEC"
    sentry-cli releases set-commits \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        --ignore-missing \
        --commit "$COMMIT_SPEC" \
        "$SENTRY_RELEASE"
else
    echo "Skipping Sentry commit association because SENTRY_SET_COMMITS=$SENTRY_SET_COMMITS."
fi

if [ "$SENTRY_UPLOAD_DEBUG_FILES" = "1" ]; then
    if [ -e "$SENTRY_DEBUG_FILES_PATH" ]; then
        verify_debug_file_match "$SENTRY_APP_BINARY_PATH" "$SENTRY_DEBUG_FILES_PATH"
        echo "Uploading Sentry debug files: $SENTRY_DEBUG_FILES_PATH"
        sentry-cli debug-files upload \
            --org "$SENTRY_ORG" \
            --project "$SENTRY_PROJECT" \
            --type dsym \
            --no-sources \
            "$SENTRY_DEBUG_FILES_PATH"
    elif [ "$SENTRY_REQUIRE_DEBUG_FILES" = "1" ]; then
        echo "Missing Sentry debug files: $SENTRY_DEBUG_FILES_PATH" >&2
        echo "Build with build-beta.sh first, or set SENTRY_DEBUG_FILES_PATH to the release dSYM." >&2
        exit 1
    else
        echo "Sentry debug files not found: $SENTRY_DEBUG_FILES_PATH"
        echo "Skipping debug-file upload. Release is yellow unless matching dSYM was uploaded separately; crash reports may be missing app frames."
    fi
else
    echo "Skipping Sentry debug-file upload because SENTRY_UPLOAD_DEBUG_FILES=$SENTRY_UPLOAD_DEBUG_FILES."
    echo "Release is yellow unless matching dSYM was uploaded separately."
fi

echo "Sentry release registration complete."
