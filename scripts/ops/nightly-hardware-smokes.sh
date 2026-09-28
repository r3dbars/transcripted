#!/bin/bash
# nightly-hardware-smokes.sh — run the real-world checks on this Mac on a schedule.
#
# The bugs users actually hit (AirPods garble, silent call audio, paste-back
# into Electron apps) live where hosted CI can't reach: a real mic, real system
# audio and real apps. This runs those checks unattended and keeps a dated log:
#
#   1. bash check.sh hardware   (app build, live capture smoke, slow paste-back smoke)
#   2. bash run-daily-audio-reliability.sh --synthetic
#
# Usage:
#   bash scripts/ops/nightly-hardware-smokes.sh                 # run once now
#   bash scripts/ops/nightly-hardware-smokes.sh --install 03:30 # LaunchAgent, daily at 03:30
#   bash scripts/ops/nightly-hardware-smokes.sh --uninstall
#   bash scripts/ops/nightly-hardware-smokes.sh --status
#
# Before installing:
#   - Run it once by hand first, so macOS asks for Microphone and System Audio
#     Recording permission while you're there to answer. A scheduled run can't
#     answer a permission prompt.
#   - The live capture smoke plays a short test tone out loud. Pick a time when
#     that's fine.
#   - Point it at a checkout that tracks main. It tests whatever is checked out;
#     it never pulls, switches branches, or pushes.
#
# Logs: build/nightly-hardware/<timestamp>.log in this checkout, plus
# build/nightly-hardware/latest.txt with a one-line PASS/FAIL. On failure it
# posts a macOS notification. It never writes to the real capture library or
# app preferences (the smokes use their own temp dirs).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LABEL="com.transcripted.nightly-hardware-smokes"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="$REPO_ROOT/build/nightly-hardware"

usage() {
    # The header comment, up to the first line that isn't a comment.
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

install_agent() {
    local at="$1"
    if ! [[ "$at" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]]; then
        echo "--install needs a 24-hour time like 03:30" >&2
        exit 2
    fi
    local hour=$((10#${BASH_REMATCH[1]})) minute=$((10#${BASH_REMATCH[2]}))
    mkdir -p "$(dirname "$PLIST")" "$LOG_DIR"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$REPO_ROOT/scripts/ops/nightly-hardware-smokes.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>$REPO_ROOT</string>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>$hour</integer>
        <key>Minute</key>
        <integer>$minute</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>$LOG_DIR/launchd.out.log</string>
    <key>StandardErrorPath</key>
    <string>$LOG_DIR/launchd.err.log</string>
</dict>
</plist>
PLIST
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    echo "Installed $LABEL: daily at $at, testing $REPO_ROOT"
    echo "Logs: $LOG_DIR"
}

uninstall_agent() {
    launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    echo "Removed $LABEL"
}

status_agent() {
    if [ -f "$PLIST" ]; then
        echo "Installed: $PLIST"
    else
        echo "Not installed"
    fi
    if [ -f "$LOG_DIR/latest.txt" ]; then
        echo "Last run: $(cat "$LOG_DIR/latest.txt")"
    fi
}

run_once() {
    mkdir -p "$LOG_DIR"
    local stamp log status=0
    stamp="$(date +%Y%m%d-%H%M%S)"
    log="$LOG_DIR/$stamp.log"
    cd "$REPO_ROOT"
    {
        echo "nightly hardware smokes $stamp at $(git rev-parse --short HEAD 2>/dev/null) ($(git rev-parse --abbrev-ref HEAD 2>/dev/null))"
        bash check.sh hardware --keep-going || status=1
        echo ""
        echo "==> synthetic daily audio reliability"
        bash run-daily-audio-reliability.sh --synthetic || status=1
    } > "$log" 2>&1

    local verdict="PASS"
    [ "$status" -ne 0 ] && verdict="FAIL"
    echo "$verdict $stamp $(git rev-parse --short HEAD 2>/dev/null) $log" > "$LOG_DIR/latest.txt"
    echo "$verdict — log: $log"
    if [ "$verdict" = "FAIL" ]; then
        osascript -e 'display notification "A real-hardware smoke failed. See build/nightly-hardware/latest.txt" with title "Transcripted nightly check"' >/dev/null 2>&1 || true
    fi
    # Keep the last 30 logs.
    ls -1t "$LOG_DIR"/2*.log 2>/dev/null | tail -n +31 | while read -r old; do rm -f "$old"; done
    return "$status"
}

case "${1:-}" in
    --install) install_agent "${2:-}" ;;
    --uninstall) uninstall_agent ;;
    --status) status_agent ;;
    -h|--help) usage ;;
    "") run_once ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 2 ;;
esac
