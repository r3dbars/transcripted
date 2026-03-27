#!/bin/bash
# UI Smoke Tests for Transcripted
# Runs AppleScript-based checks against the live app.
# Requires: Transcripted running, Accessibility permissions for Terminal/Claude Code.
#
# Usage: ./scripts/ui-smoke-test.sh [--json]
# Exit code: 0 = all pass, 1 = failures found

set -uo pipefail

FORMAT="text"
[ "${1:-}" = "--json" ] && FORMAT="json"

PASS=0
FAIL=0
WARN=0
RESULTS=()

# --- Helpers ---

result() {
    local status="$1" check="$2" detail="${3:-}"
    case "$status" in
        PASS) ((PASS++)) ;;
        FAIL) ((FAIL++)) ;;
        WARN) ((WARN++)) ;;
    esac
    if [ "$FORMAT" = "json" ]; then
        local json="{\"status\":\"$status\",\"check\":\"$check\""
        [ -n "$detail" ] && json+=",\"detail\":\"$detail\""
        json+="}"
        RESULTS+=("$json")
    else
        printf "%-5s %-40s %s\n" "$status" "$check" "$detail"
    fi
}

# --- Pre-flight ---

APP_RUNNING=$(pgrep -x Transcripted > /dev/null 2>&1 && echo "yes" || echo "no")
if [ "$APP_RUNNING" = "no" ]; then
    echo "Transcripted is not running. Attempting to launch..."
    open -a Transcripted
    sleep 3
    APP_RUNNING=$(pgrep -x Transcripted > /dev/null 2>&1 && echo "yes" || echo "no")
    if [ "$APP_RUNNING" = "no" ]; then
        result "FAIL" "ui/app-launch" "Transcripted failed to launch"
        # Can't continue without the app
        if [ "$FORMAT" = "json" ]; then
            echo "{\"results\":[$(IFS=,; echo "${RESULTS[*]}")],\"summary\":{\"passed\":$PASS,\"failed\":$FAIL,\"warnings\":$WARN}}"
        else
            echo ""
            echo "Summary: $PASS passed, $FAIL failed, $WARN warnings"
        fi
        exit 1
    fi
fi
result "PASS" "ui/app-running" "PID $(pgrep -x Transcripted)"

# Check accessibility permission early — test a menu bar query which requires full access
ACCESSIBILITY_OK=$(osascript -e '
tell application "System Events"
    tell process "Transcripted"
        return count of menu bars
    end tell
end tell' 2>&1)

if [[ "$ACCESSIBILITY_OK" == *"-25211"* ]] || [[ "$ACCESSIBILITY_OK" == *"not allowed assistive"* ]] || [[ "$ACCESSIBILITY_OK" == *"error"* ]]; then
    result "WARN" "ui/accessibility" "Accessibility not granted — grant to Terminal/Claude in System Settings > Privacy > Accessibility"
    HAS_ACCESSIBILITY=false
else
    result "PASS" "ui/accessibility" "Accessibility access confirmed"
    HAS_ACCESSIBILITY=true
fi

# --- T1: App Process & Menu Bar Presence ---

if [ "$HAS_ACCESSIBILITY" = "false" ]; then
    # Skip AppleScript-based tests, run only non-accessibility checks
    result "WARN" "ui/menu-bar-only" "Skipped — no accessibility"
    result "WARN" "ui/menu-bar-item" "Skipped — no accessibility"
    result "WARN" "ui/idle-no-windows" "Skipped — no accessibility"
    result "WARN" "ui/hotkey-responsive" "Skipped — no accessibility"
    result "WARN" "ui/settings-window" "Skipped — no accessibility"
    result "WARN" "ui/context-menu" "Skipped — no accessibility"
else

# Check the app is an accessory (menu bar only, no dock icon)
DOCK_ICON=$(osascript -e '
tell application "System Events"
    set appList to name of every process whose visible is true and background only is false
    if appList contains "Transcripted" then
        return "visible"
    else
        return "hidden"
    end if
end tell' 2>/dev/null || echo "error")

if [ "$DOCK_ICON" = "hidden" ]; then
    result "PASS" "ui/menu-bar-only" "No dock icon (accessory mode)"
elif [ "$DOCK_ICON" = "visible" ]; then
    result "WARN" "ui/menu-bar-only" "App visible in dock — expected accessory mode"
else
    result "WARN" "ui/menu-bar-only" "Could not check dock visibility"
fi

# --- T2: Menu Bar Item Exists ---

MENU_EXISTS=$(osascript -e '
tell application "System Events"
    tell process "Transcripted"
        set menuCount to count of menu bar items of menu bar 2
        return menuCount
    end tell
end tell' 2>/dev/null || echo "0")

if [ "$MENU_EXISTS" -gt 0 ] 2>/dev/null; then
    result "PASS" "ui/menu-bar-item" "Menu bar item found ($MENU_EXISTS items)"
else
    result "FAIL" "ui/menu-bar-item" "No menu bar item found"
fi

# --- T3: Window State (no windows should be open at idle) ---

WINDOW_COUNT=$(osascript -e '
tell application "System Events"
    tell process "Transcripted"
        return count of windows
    end tell
end tell' 2>/dev/null || echo "-1")

if [ "$WINDOW_COUNT" = "0" ]; then
    result "PASS" "ui/idle-no-windows" "No windows open at idle"
elif [ "$WINDOW_COUNT" -gt 0 ] 2>/dev/null; then
    result "WARN" "ui/idle-no-windows" "$WINDOW_COUNT window(s) open — expected none at idle"
else
    result "WARN" "ui/idle-no-windows" "Could not check window count"
fi

# --- T4: Global Hotkey Registration ---

# Check if the hotkey shortcut is registered by looking at the app's carbon events
# We can verify indirectly: try the hotkey and check if app state changes
BEFORE_LOG_COUNT=$(wc -l < ~/Library/Logs/Transcripted/app.jsonl 2>/dev/null || echo "0")

osascript -e '
tell application "System Events"
    key code 15 using {command down, shift down}
end tell' 2>/dev/null

sleep 2

AFTER_LOG_COUNT=$(wc -l < ~/Library/Logs/Transcripted/app.jsonl 2>/dev/null || echo "0")

if [ "$AFTER_LOG_COUNT" -gt "$BEFORE_LOG_COUNT" ]; then
    result "PASS" "ui/hotkey-responsive" "Cmd+Shift+R triggered log activity (+$((AFTER_LOG_COUNT - BEFORE_LOG_COUNT)) entries)"

    # Stop recording immediately if we started one
    sleep 1
    osascript -e '
    tell application "System Events"
        key code 15 using {command down, shift down}
    end tell' 2>/dev/null
    result "PASS" "ui/hotkey-stop" "Stop hotkey sent"
else
    result "WARN" "ui/hotkey-responsive" "Hotkey did not produce log activity (may need accessibility permission)"
fi

# --- T5: Settings Window Opens ---

SETTINGS_OPENED=$(osascript -e '
tell application "System Events"
    tell process "Transcripted"
        -- Click the menu bar item to get context menu, then look for Settings
        try
            click menu bar item 1 of menu bar 2
            delay 0.5
            -- Look for Settings menu item
            set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
            -- Click Settings if found
            if menuItems contains "Settings…" then
                click menu item "Settings…" of menu 1 of menu bar item 1 of menu bar 2
                delay 1
                set winCount to count of windows
                -- Close it
                if winCount > 0 then
                    keystroke "w" using command down
                end if
                return "opened"
            else if menuItems contains "Settings" then
                click menu item "Settings" of menu 1 of menu bar item 1 of menu bar 2
                delay 1
                set winCount to count of windows
                if winCount > 0 then
                    keystroke "w" using command down
                end if
                return "opened"
            else
                return "no-settings-item"
            end if
        on error errMsg
            return "error: " & errMsg
        end try
    end tell
end tell' 2>/dev/null || echo "error")

if [ "$SETTINGS_OPENED" = "opened" ]; then
    result "PASS" "ui/settings-window" "Settings window opened and closed"
elif [[ "$SETTINGS_OPENED" == error* ]]; then
    result "WARN" "ui/settings-window" "Could not test — $SETTINGS_OPENED"
else
    result "WARN" "ui/settings-window" "Settings item not found in menu: $SETTINGS_OPENED"
fi

# --- T6: Context Menu Items ---

MENU_ITEMS=$(osascript -e '
tell application "System Events"
    tell process "Transcripted"
        try
            click menu bar item 1 of menu bar 2
            delay 0.5
            set menuItems to name of every menu item of menu 1 of menu bar item 1 of menu bar 2
            -- Dismiss menu
            key code 53
            return menuItems as text
        on error errMsg
            return "error: " & errMsg
        end try
    end tell
end tell' 2>/dev/null || echo "error")

if [[ "$MENU_ITEMS" == *"Quit"* ]]; then
    result "PASS" "ui/context-menu" "Menu contains Quit item"
    # Check for expected items
    for item in "Start Recording" "Settings" "Quit"; do
        if [[ "$MENU_ITEMS" == *"$item"* ]]; then
            result "PASS" "ui/menu-item-${item// /-}" "Found: $item"
        else
            result "WARN" "ui/menu-item-${item// /-}" "Missing: $item"
        fi
    done
elif [[ "$MENU_ITEMS" == error* ]]; then
    result "WARN" "ui/context-menu" "Could not read menu — $MENU_ITEMS"
else
    result "FAIL" "ui/context-menu" "Menu items not readable"
fi

# End of accessibility-gated tests
fi

# --- T7: App Not Consuming Excessive CPU at Idle ---

CPU=$(ps -p "$(pgrep -x Transcripted)" -o %cpu= 2>/dev/null | tr -d ' ')
if [ -n "$CPU" ]; then
    CPU_INT=${CPU%.*}
    if [ "$CPU_INT" -lt 5 ] 2>/dev/null; then
        result "PASS" "ui/idle-cpu" "CPU at idle: ${CPU}%"
    elif [ "$CPU_INT" -lt 20 ] 2>/dev/null; then
        result "WARN" "ui/idle-cpu" "CPU at idle: ${CPU}% — elevated"
    else
        result "FAIL" "ui/idle-cpu" "CPU at idle: ${CPU}% — excessive"
    fi
fi

# --- T8: App Memory Usage ---

MEM=$(ps -p "$(pgrep -x Transcripted)" -o rss= 2>/dev/null | tr -d ' ')
if [ -n "$MEM" ]; then
    MEM_MB=$((MEM / 1024))
    if [ "$MEM_MB" -lt 500 ]; then
        result "PASS" "ui/idle-memory" "Memory at idle: ${MEM_MB}MB"
    elif [ "$MEM_MB" -lt 1000 ]; then
        result "WARN" "ui/idle-memory" "Memory at idle: ${MEM_MB}MB — elevated"
    else
        result "FAIL" "ui/idle-memory" "Memory at idle: ${MEM_MB}MB — excessive"
    fi
fi

# --- T9: UserDefaults Sanity ---

DEFAULTS_OK=true
for key in "enableUISounds" "enableQwenSpeakerInference"; do
    VAL=$(defaults read com.transcripted.app "$key" 2>/dev/null)
    if [ $? -eq 0 ]; then
        result "PASS" "ui/defaults-$key" "Value: $VAL"
    else
        result "WARN" "ui/defaults-$key" "Key not set (using default)"
    fi
done

# --- T10: App Responds to Accessibility Queries ---

if [ "$HAS_ACCESSIBILITY" = "true" ]; then
    APP_ROLE=$(osascript -e '
    tell application "System Events"
        tell process "Transcripted"
            return role description
        end tell
    end tell' 2>/dev/null || echo "error")

    if [ "$APP_ROLE" != "error" ] && [ -n "$APP_ROLE" ]; then
        result "PASS" "ui/accessibility" "App role: $APP_ROLE"
    else
        result "WARN" "ui/accessibility" "Could not query app role"
    fi
fi

# --- Output ---

echo ""
if [ "$FORMAT" = "json" ]; then
    echo "{\"results\":[$(IFS=,; echo "${RESULTS[*]}")],\"summary\":{\"passed\":$PASS,\"failed\":$FAIL,\"warnings\":$WARN}}"
else
    echo "Summary: $PASS passed, $FAIL failed, $WARN warnings"
fi

exit $((FAIL > 0 ? 1 : 0))
