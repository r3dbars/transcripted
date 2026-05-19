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
    sentry-cli releases set-commits \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        --auto \
        --ignore-missing \
        "$SENTRY_RELEASE"
else
    echo "Skipping Sentry commit association because SENTRY_SET_COMMITS=$SENTRY_SET_COMMITS."
fi

echo "Sentry release registration complete."
