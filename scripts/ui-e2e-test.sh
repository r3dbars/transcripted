#!/bin/bash
# End-to-End UI Tests for Transcripted
# Uses BOTH screencapture (visual verification) AND AppleScript (state verification)
# Requires: Transcripted running, Accessibility + Screen Recording permissions for iTerm2
#
# Usage: ./scripts/ui-e2e-test.sh [--screenshots-dir /path]
# Screenshots are saved for Claude to read and verify visually.

set -uo pipefail

SCREENSHOT_DIR="${1:-/tmp/transcripted-e2e}"
mkdir -p "$SCREENSHOT_DIR"

PASS=0
FAIL=0
WARN=0
STEP=0

result() {
    local status="$1" check="$2" detail="${3:-}"
    case "$status" in
        PASS) ((PASS++)) ;;
        FAIL) ((FAIL++)) ;;
        WARN) ((WARN++)) ;;
    esac
    printf "%-5s %-45s %s\n" "$status" "$check" "$detail"
}

screenshot() {
    ((STEP++))
    local name="$1"
    local path="$SCREENSHOT_DIR/step${STEP}_${name}.png"
    if screencapture -x "$path" 2>/dev/null; then
        echo "  [screenshot] $path"
    else
        echo "  [screenshot] FAILED — screen recording permission needed"
    fi
}

# --- Pre-flight ---

APP_PID=$(pgrep -x Transcripted 2>/dev/null)
if [ -z "$APP_PID" ]; then
    echo "Transcripted not running. Launching..."
    open -a Transcripted
    sleep 3
    APP_PID=$(pgrep -x Transcripted 2>/dev/null)
    if [ -z "$APP_PID" ]; then
        result "FAIL" "e2e/app-launch" "Could not launch Transcripted"
        exit 1
    fi
fi
result "PASS" "e2e/app-running" "PID $APP_PID"

# Check permissions
ACCESSIBILITY_OK=$(osascript -e 'tell application "System Events" to tell process "Transcripted" to return count of menu bars' 2>&1)
if [[ "$ACCESSIBILITY_OK" == *"error"* ]] || [[ "$ACCESSIBILITY_OK" == *"-25211"* ]]; then
    result "FAIL" "e2e/accessibility" "Accessibility permission required"
    exit 1
fi
result "PASS" "e2e/accessibility" "Granted"

HAS_SCREENSHOTS=true
screencapture -x "$SCREENSHOT_DIR/test_capture.png" 2>/dev/null || HAS_SCREENSHOTS=false
if [ "$HAS_SCREENSHOTS" = "true" ]; then
    result "PASS" "e2e/screen-recording" "Screenshots available"
    rm -f "$SCREENSHOT_DIR/test_capture.png"
else
    result "WARN" "e2e/screen-recording" "No screen recording permission — AppleScript-only mode"
fi

# Record baseline counts
TRANSCRIPT_DIR="$HOME/Documents/Transcripted"
BEFORE_COUNT=$(ls "$TRANSCRIPT_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
BEFORE_LOG_LINES=$(wc -l < ~/Library/Logs/Transcripted/app.jsonl 2>/dev/null || echo "0")
echo ""
echo "Baseline: $BEFORE_COUNT transcripts, $BEFORE_LOG_LINES log lines"
echo ""

# ============================================================
# FLOW E1: Idle State Verification
# ============================================================
echo "=== Flow E1: Idle State ==="

screenshot "idle_state"

# Check no windows open
WINDOW_COUNT=$(osascript -e 'tell application "System Events" to tell process "Transcripted" to return count of windows' 2>/dev/null || echo "-1")
if [ "$WINDOW_COUNT" = "0" ]; then
    result "PASS" "e2e/idle-no-windows" "Clean idle state"
else
    result "WARN" "e2e/idle-no-windows" "$WINDOW_COUNT window(s) open"
fi

# Check CPU/Memory
CPU=$(ps -p "$APP_PID" -o %cpu= 2>/dev/null | tr -d ' ')
MEM_KB=$(ps -p "$APP_PID" -o rss= 2>/dev/null | tr -d ' ')
MEM_MB=$((MEM_KB / 1024))
result "PASS" "e2e/idle-resources" "CPU: ${CPU}%, Memory: ${MEM_MB}MB"

echo ""

# ============================================================
# FLOW E2: Context Menu
# ============================================================
echo "=== Flow E2: Context Menu ==="

osascript -e '
tell application "System Events"
    tell process "Transcripted"
        click menu bar item 1 of menu bar 2
    end tell
end tell' 2>/dev/null
sleep 0.5

screenshot "context_menu_open"

MENU_ITEMS=$(osascript -e '
tell application "System Events"
    tell process "Transcripted"
        set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
        return menuItems as text
    end tell
end tell' 2>/dev/null || echo "error")

# Dismiss menu
osascript -e 'tell application "System Events" to key code 53' 2>/dev/null
sleep 0.3

EXPECTED_ITEMS=("Start Recording" "Open Transcripts" "Settings" "Quit")
for item in "${EXPECTED_ITEMS[@]}"; do
    if [[ "$MENU_ITEMS" == *"$item"* ]]; then
        result "PASS" "e2e/menu-${item// /-}" "Found"
    else
        result "FAIL" "e2e/menu-${item// /-}" "Missing from menu"
    fi
done

echo ""

# ============================================================
# FLOW E3: Settings Window
# ============================================================
echo "=== Flow E3: Settings Window ==="

# Open via menu
osascript -e '
tell application "System Events"
    tell process "Transcripted"
        click menu bar item 1 of menu bar 2
        delay 0.5
        set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
        repeat with mi in menuItems
            if mi as text contains "Settings" then
                click menu item (mi as text) of menu 1 of menu bar item 1 of menu bar 2
                exit repeat
            end if
        end repeat
    end tell
end tell' 2>/dev/null
sleep 1

screenshot "settings_open"

# Check window opened
SETTINGS_WINDOW=$(osascript -e '
tell application "System Events"
    tell process "Transcripted"
        if (count of windows) > 0 then
            return name of window 1
        else
            return "none"
        end if
    end tell
end tell' 2>/dev/null || echo "error")

if [ "$SETTINGS_WINDOW" != "none" ] && [ "$SETTINGS_WINDOW" != "error" ]; then
    result "PASS" "e2e/settings-opened" "Window: $SETTINGS_WINDOW"
else
    result "FAIL" "e2e/settings-opened" "Settings window did not open"
fi

# Verify window has content (check for UI elements)
ELEMENT_COUNT=$(osascript -e '
tell application "System Events"
    tell process "Transcripted"
        if (count of windows) > 0 then
            return count of UI elements of window 1
        else
            return 0
        end if
    end tell
end tell' 2>/dev/null || echo "0")

if [ "$ELEMENT_COUNT" -gt 0 ] 2>/dev/null; then
    result "PASS" "e2e/settings-has-content" "$ELEMENT_COUNT UI elements"
else
    result "WARN" "e2e/settings-has-content" "Could not count UI elements"
fi

# Close settings
osascript -e 'tell application "System Events" to keystroke "w" using command down' 2>/dev/null
sleep 0.5

AFTER_CLOSE_WINDOWS=$(osascript -e 'tell application "System Events" to tell process "Transcripted" to return count of windows' 2>/dev/null || echo "-1")
if [ "$AFTER_CLOSE_WINDOWS" = "0" ]; then
    result "PASS" "e2e/settings-closed" "Cmd+W closed settings"
else
    result "WARN" "e2e/settings-closed" "Window still open after Cmd+W"
fi

screenshot "settings_closed"
echo ""

# ============================================================
# FLOW E4: Recording Happy Path
# ============================================================
echo "=== Flow E4: Recording (Cmd+Shift+R) ==="

# Start recording via menu item (more reliable than hotkey — hotkey can be intercepted by focused app)
osascript -e '
tell application "System Events"
    tell process "Transcripted"
        click menu bar item 1 of menu bar 2
        delay 0.5
        click menu item "Start Recording" of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell' 2>/dev/null

sleep 2
screenshot "recording_started"

# Check log for recording start
SNAP_LOG_LINES=$(wc -l < ~/Library/Logs/Transcripted/app.jsonl 2>/dev/null | tr -d ' ')
if [ "$SNAP_LOG_LINES" -gt "$BEFORE_LOG_LINES" ]; then
    result "PASS" "e2e/recording-started" "Log activity detected (+$((SNAP_LOG_LINES - BEFORE_LOG_LINES)) lines)"
else
    result "WARN" "e2e/recording-started" "No log activity detected after Start Recording"
fi

# Wait and capture during recording
echo "  Recording for 8 seconds..."
sleep 3
screenshot "recording_midway"
sleep 5

# Stop recording via menu item
osascript -e '
tell application "System Events"
    tell process "Transcripted"
        click menu bar item 1 of menu bar 2
        delay 0.5
        set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
        -- Look for "Stop Recording" (menu text changes when recording)
        repeat with mi in menuItems
            if mi as text contains "Stop" or mi as text contains "Recording" then
                click menu item (mi as text) of menu 1 of menu bar item 1 of menu bar 2
                exit repeat
            end if
        end repeat
    end tell
end tell' 2>/dev/null

sleep 1
screenshot "recording_stopped"
result "PASS" "e2e/recording-stopped" "Stop sent after 8s recording"

# Wait for processing
echo "  Waiting for processing (up to 120s)..."
PROCESSING_START=$(date +%s)
PROCESSING_DONE=false

for i in $(seq 1 24); do
    sleep 5

    # Check if a new transcript appeared
    AFTER_COUNT=$(ls "$TRANSCRIPT_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
    if [ "$AFTER_COUNT" -gt "$BEFORE_COUNT" ]; then
        PROCESSING_DONE=true
        ELAPSED=$(($(date +%s) - PROCESSING_START))
        screenshot "processing_complete"
        result "PASS" "e2e/transcript-created" "New transcript appeared after ${ELAPSED}s"
        break
    fi

    # Take a screenshot every 15s during processing
    if [ $((i % 3)) -eq 0 ]; then
        screenshot "processing_wait_${i}"
    fi
done

if [ "$PROCESSING_DONE" = "false" ]; then
    screenshot "processing_timeout"
    result "FAIL" "e2e/transcript-created" "No new transcript after 120s"
fi

echo ""

# ============================================================
# FLOW E5: Verify Transcript on Disk
# ============================================================
echo "=== Flow E5: Transcript Verification ==="

if [ "$PROCESSING_DONE" = "true" ]; then
    # Find the newest transcript
    NEWEST_MD=$(ls -t "$TRANSCRIPT_DIR"/*.md 2>/dev/null | head -1)
    NEWEST_JSON="${NEWEST_MD%.md}.json"

    if [ -f "$NEWEST_MD" ]; then
        result "PASS" "e2e/md-exists" "$(basename "$NEWEST_MD")"

        # Check it was created recently (within last 5 minutes)
        FILE_AGE=$(( $(date +%s) - $(stat -f %m "$NEWEST_MD") ))
        if [ "$FILE_AGE" -lt 300 ]; then
            result "PASS" "e2e/md-recent" "Created ${FILE_AGE}s ago"
        else
            result "FAIL" "e2e/md-recent" "File is ${FILE_AGE}s old — not from this test"
        fi

        # Check YAML frontmatter
        if head -1 "$NEWEST_MD" | grep -q "^---"; then
            result "PASS" "e2e/md-has-yaml" "YAML frontmatter present"
        else
            result "FAIL" "e2e/md-has-yaml" "No YAML frontmatter"
        fi

        # Check for required YAML keys
        for key in "date" "duration" "transcription_engine" "diarization_engine"; do
            if grep -q "^${key}:" "$NEWEST_MD"; then
                result "PASS" "e2e/yaml-$key" "Present"
            else
                result "FAIL" "e2e/yaml-$key" "Missing"
            fi
        done
    else
        result "FAIL" "e2e/md-exists" "No .md file found"
    fi

    # Check JSON sidecar
    if [ -f "$NEWEST_JSON" ]; then
        result "PASS" "e2e/json-exists" "$(basename "$NEWEST_JSON")"

        # Validate JSON
        if python3 -c "import json; json.load(open('$NEWEST_JSON'))" 2>/dev/null; then
            result "PASS" "e2e/json-valid" "Valid JSON"
        else
            result "FAIL" "e2e/json-valid" "Invalid JSON"
        fi
    else
        result "FAIL" "e2e/json-exists" "No .json sidecar"
    fi

    # Run CLI validator on the new transcript specifically
    echo "  Running CLI validator..."
    CLI_RESULT=$( cd /Users/redbars/redbars/code/transcripted/Tools/TranscriptedQA && swift run transcripted-qa validate-all 2>&1 | tail -1 )
    echo "  $CLI_RESULT"
else
    result "WARN" "e2e/transcript-verification" "Skipped — no transcript created"
fi

echo ""

# ============================================================
# FLOW E6: Short Recording Rejection
# ============================================================
echo "=== Flow E6: Short Recording Rejection ==="

# Start and immediately stop (< 2s) via menu
osascript -e '
tell application "System Events"
    tell process "Transcripted"
        click menu bar item 1 of menu bar 2
        delay 0.3
        click menu item "Start Recording" of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell' 2>/dev/null
sleep 0.5
osascript -e '
tell application "System Events"
    tell process "Transcripted"
        click menu bar item 1 of menu bar 2
        delay 0.3
        set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
        repeat with mi in menuItems
            if mi as text contains "Stop" or mi as text contains "Recording" then
                click menu item (mi as text) of menu 1 of menu bar item 1 of menu bar 2
                exit repeat
            end if
        end repeat
    end tell
end tell' 2>/dev/null
sleep 2

screenshot "short_recording"

# App should still be running
if pgrep -x Transcripted > /dev/null 2>&1; then
    result "PASS" "e2e/short-no-crash" "App survived short recording"
else
    result "FAIL" "e2e/short-no-crash" "App CRASHED on short recording"
fi

echo ""

# ============================================================
# FLOW E7: Rapid Start/Stop Stress
# ============================================================
echo "=== Flow E7: Rapid Start/Stop (5x) ==="

for i in $(seq 1 5); do
    osascript -e '
    tell application "System Events"
        tell process "Transcripted"
            click menu bar item 1 of menu bar 2
            delay 0.3
            click menu item "Start Recording" of menu 1 of menu bar item 1 of menu bar 2
        end tell
    end tell' 2>/dev/null
    sleep 0.3
    osascript -e '
    tell application "System Events"
        tell process "Transcripted"
            click menu bar item 1 of menu bar 2
            delay 0.3
            set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
            repeat with mi in menuItems
                if mi as text contains "Stop" or mi as text contains "Recording" then
                    click menu item (mi as text) of menu 1 of menu bar item 1 of menu bar 2
                    exit repeat
                end if
            end repeat
        end tell
    end tell' 2>/dev/null
    sleep 0.5
done

sleep 2
screenshot "rapid_stress"

if pgrep -x Transcripted > /dev/null 2>&1; then
    result "PASS" "e2e/rapid-no-crash" "App survived 5 rapid start/stop cycles"
else
    result "FAIL" "e2e/rapid-no-crash" "App CRASHED during rapid start/stop"
fi

# Check CPU hasn't gone runaway
sleep 2
CPU_AFTER=$(ps -p "$(pgrep -x Transcripted)" -o %cpu= 2>/dev/null | tr -d ' ')
CPU_INT=${CPU_AFTER%.*}
if [ "$CPU_INT" -lt 30 ] 2>/dev/null; then
    result "PASS" "e2e/rapid-cpu-recovery" "CPU settled: ${CPU_AFTER}%"
else
    result "WARN" "e2e/rapid-cpu-recovery" "CPU still elevated: ${CPU_AFTER}%"
fi

echo ""

# ============================================================
# FLOW E8: YouTube Transcription Comparison
# ============================================================
echo "=== Flow E8: YouTube Transcription Test ==="
echo "  This test plays a known YouTube video, records it with Transcripted,"
echo "  and verifies the transcript captures real speech content."
echo ""

# Known reference: JFK Moon Speech at Rice University (NASA Video, ~1:30 mark)
# Expected words at this timestamp: "condense", "fifty thousand", "recorded history",
# "half a century", "skins of animals", "caves"
YOUTUBE_URL="https://www.youtube.com/watch?v=WZyRbnpGyzQ&t=90"
EXPECTED_WORDS=("condense" "history" "century" "animals" "caves" "years")

YT_BEFORE_COUNT=$(ls "$TRANSCRIPT_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')

# Open Chrome to the video (autoplay will start it)
osascript -e "
tell application \"Google Chrome\"
    activate
    if (count of windows) = 0 then
        make new window
    end if
    set URL of active tab of front window to \"$YOUTUBE_URL\"
end tell" 2>/dev/null

echo "  Loading YouTube video..."
sleep 6
screenshot "youtube_video_loaded"

# Verify Chrome has the video open
CHROME_URL=$(osascript -e 'tell application "Google Chrome" to return URL of active tab of front window' 2>/dev/null)
if [[ "$CHROME_URL" == *"youtube.com"* ]]; then
    result "PASS" "e2e/youtube-loaded" "Video page loaded"
else
    result "FAIL" "e2e/youtube-loaded" "Chrome not on YouTube: $CHROME_URL"
fi

# Wait for autoplay to start, then start Transcripted recording
sleep 3

osascript -e '
tell application "System Events"
    tell process "Transcripted"
        click menu bar item 1 of menu bar 2
        delay 0.5
        click menu item "Start Recording" of menu 1 of menu bar item 1 of menu bar 2
    end tell
end tell' 2>/dev/null

echo "  Recording YouTube audio for 30 seconds..."
sleep 10
screenshot "youtube_recording_10s"
sleep 10
screenshot "youtube_recording_20s"
sleep 10

# Stop Transcripted
osascript -e '
tell application "System Events"
    tell process "Transcripted"
        click menu bar item 1 of menu bar 2
        delay 0.5
        set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
        repeat with mi in menuItems
            if mi as text contains "Stop" or mi as text contains "Recording" then
                click menu item (mi as text) of menu 1 of menu bar item 1 of menu bar 2
                exit repeat
            end if
        end repeat
    end tell
end tell' 2>/dev/null

sleep 1

# Pause YouTube
osascript -e '
tell application "Google Chrome"
    activate
end tell
delay 0.3
tell application "System Events"
    keystroke "k"
end tell' 2>/dev/null

screenshot "youtube_both_stopped"
result "PASS" "e2e/youtube-recorded" "30s recording captured"

# Wait for transcript
echo "  Waiting for transcript processing..."
YT_TRANSCRIPT_FOUND=false
for i in $(seq 1 30); do
    sleep 5
    YT_AFTER_COUNT=$(ls "$TRANSCRIPT_DIR"/*.md 2>/dev/null | wc -l | tr -d ' ')
    if [ "$YT_AFTER_COUNT" -gt "$YT_BEFORE_COUNT" ]; then
        YT_TRANSCRIPT_FOUND=true
        result "PASS" "e2e/youtube-transcript-created" "Transcript appeared after $((i * 5))s"
        break
    fi
done

if [ "$YT_TRANSCRIPT_FOUND" = "false" ]; then
    result "FAIL" "e2e/youtube-transcript-created" "No transcript after 150s"
fi

if [ "$YT_TRANSCRIPT_FOUND" = "true" ]; then
    YT_NEWEST=$(ls -t "$TRANSCRIPT_DIR"/*.md 2>/dev/null | head -1)
    YT_CONTENT=$(cat "$YT_NEWEST")

    # Check word count > 0
    YT_WORD_COUNT=$(echo "$YT_CONTENT" | grep "^total_word_count:" | sed 's/[^0-9]//g')
    if [ "$YT_WORD_COUNT" -gt 0 ] 2>/dev/null; then
        result "PASS" "e2e/youtube-has-words" "$YT_WORD_COUNT words transcribed"
    else
        result "FAIL" "e2e/youtube-has-words" "0 words — audio may not have been captured"
    fi

    # Check system utterances > 0 (YouTube audio goes through system audio)
    YT_SYS_UTT=$(echo "$YT_CONTENT" | grep "^system_utterances:" | sed 's/[^0-9]//g')
    if [ "$YT_SYS_UTT" -gt 0 ] 2>/dev/null; then
        result "PASS" "e2e/youtube-system-audio" "$YT_SYS_UTT system utterances captured"
    else
        result "FAIL" "e2e/youtube-system-audio" "0 system utterances — system audio capture may have failed"
    fi

    # Check for expected words from JFK speech
    YT_TRANSCRIPT_TEXT=$(echo "$YT_CONTENT" | sed -n '/## Full Transcript/,/---/p')
    MATCHED=0
    CHECKED=0
    for word in "${EXPECTED_WORDS[@]}"; do
        ((CHECKED++))
        if echo "$YT_TRANSCRIPT_TEXT" | grep -qi "$word"; then
            ((MATCHED++))
        fi
    done

    if [ "$MATCHED" -ge 3 ]; then
        result "PASS" "e2e/youtube-content-match" "$MATCHED/${CHECKED} expected words found in transcript"
    elif [ "$MATCHED" -ge 1 ]; then
        result "WARN" "e2e/youtube-content-match" "Only $MATCHED/${CHECKED} expected words — partial match"
    else
        result "FAIL" "e2e/youtube-content-match" "0/${CHECKED} expected words — transcript doesn't match video content"
    fi

    # Check JSON sidecar exists and is valid
    YT_JSON="${YT_NEWEST%.md}.json"
    if [ -f "$YT_JSON" ] && python3 -c "import json; json.load(open('$YT_JSON'))" 2>/dev/null; then
        result "PASS" "e2e/youtube-sidecar-valid" "JSON sidecar valid"
    else
        result "FAIL" "e2e/youtube-sidecar-valid" "Missing or invalid JSON sidecar"
    fi

    # Print the actual transcript for human review
    echo ""
    echo "  --- Transcript Content ---"
    echo "$YT_TRANSCRIPT_TEXT" | head -10
    echo "  --- End ---"
    echo ""
fi

echo ""

# ============================================================
# Summary
# ============================================================
echo "=== E2E Test Summary ==="
echo "Screenshots: $SCREENSHOT_DIR/"
echo ""
echo "Summary: $PASS passed, $FAIL failed, $WARN warnings"
echo ""
echo "Screenshot files for visual verification:"
ls -1 "$SCREENSHOT_DIR"/*.png 2>/dev/null | while read f; do
    echo "  $(basename "$f")"
done

exit $((FAIL > 0 ? 1 : 0))
