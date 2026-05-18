#!/bin/bash
# run-live-capture-smoke.sh - local live mic + system-audio smoke for release confidence.

set -euo pipefail

ENTRYPOINT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$ENTRYPOINT_DIR/../.." && pwd)"
cd "$REPO_ROOT"

RUN_BUILD=1
DURATION="${TRANSCRIPTED_LIVE_CAPTURE_DURATION:-2.0}"
KEEP="${TRANSCRIPTED_LIVE_CAPTURE_KEEP:-0}"

usage() {
    cat <<USAGE
Usage: bash run-live-capture-smoke.sh [--skip-build] [--duration seconds] [--keep]

Runs the local hardware/TCC smoke for live meeting capture.

This is intentionally not part of the default fast suite because it requires:
  - a local microphone
  - microphone permission for the test runner
  - System Audio Recording permission for ScreenCaptureKit audio

Options:
  --skip-build        Do not run bash build.sh --no-open first.
  --duration seconds  Recording duration for the live capture check. Default: ${DURATION}
  --keep              Keep temporary smoke artifacts.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build)
            RUN_BUILD=0
            shift
            ;;
        --duration)
            if [[ $# -lt 2 ]]; then
                echo "--duration requires a value" >&2
                exit 2
            fi
            DURATION="$2"
            shift 2
            ;;
        --keep)
            KEEP=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$RUN_BUILD" -eq 1 ]]; then
    echo "Building and running app launch smoke..."
    bash build.sh --no-open
fi

echo "Running live mic + system-audio capture smoke..."
TRANSCRIPTED_LIVE_CAPTURE_SMOKE=1 \
TRANSCRIPTED_LIVE_CAPTURE_DURATION="$DURATION" \
TRANSCRIPTED_LIVE_CAPTURE_KEEP="$KEEP" \
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 \
swift test --filter LiveCaptureSmokeTests
