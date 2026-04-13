#!/bin/bash

set -euo pipefail

BUNDLE_ID="${TRANSCRIPTED_BUNDLE_ID:-com.justinbetker.draft}"
COMPLETION_KEY="permissionsOnboardingCompleted"
FORCE_KEY="forcePermissionsOnboarding"

read_bool() {
    local key="$1"
    if defaults read "$BUNDLE_ID" "$key" >/dev/null 2>&1; then
        defaults read "$BUNDLE_ID" "$key"
    else
        echo "<unset>"
    fi
}

case "${1:-status}" in
    status)
        echo "Bundle ID: $BUNDLE_ID"
        echo "$COMPLETION_KEY=$(read_bool "$COMPLETION_KEY")"
        echo "$FORCE_KEY=$(read_bool "$FORCE_KEY")"
        ;;
    reset)
        defaults delete "$BUNDLE_ID" "$COMPLETION_KEY" >/dev/null 2>&1 || true
        echo "Reset onboarding completion for $BUNDLE_ID"
        ;;
    force-on)
        defaults write "$BUNDLE_ID" "$FORCE_KEY" -bool true
        echo "Forced onboarding on for $BUNDLE_ID"
        ;;
    force-off)
        defaults delete "$BUNDLE_ID" "$FORCE_KEY" >/dev/null 2>&1 || true
        echo "Forced onboarding off for $BUNDLE_ID"
        ;;
    fresh)
        defaults delete "$BUNDLE_ID" "$COMPLETION_KEY" >/dev/null 2>&1 || true
        defaults delete "$BUNDLE_ID" "$FORCE_KEY" >/dev/null 2>&1 || true
        echo "Set onboarding back to normal first-run behavior for $BUNDLE_ID"
        ;;
    *)
        echo "Usage: scripts/dev/onboarding.sh [status|reset|force-on|force-off|fresh]"
        exit 1
        ;;
esac
