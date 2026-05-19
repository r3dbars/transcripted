#!/bin/bash

set -euo pipefail

usage() {
    echo "Usage: bash scripts/release/register-sentry-release.sh [version]"
    echo ""
    echo "Creates and finalizes the Sentry release matching Info.plist."
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

echo "Sentry release registration complete."
