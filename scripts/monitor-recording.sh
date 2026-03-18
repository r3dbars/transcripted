#!/bin/bash
# Transcripted 1-Hour Recording Monitor
# Run this in a separate terminal while testing
# Usage: ./monitor-recording.sh

# Configuration
DOCUMENTS_DIR="$HOME/Documents"
TRANSCRIPTS_DIR="$HOME/Documents/Transcripted"
APP_NAME="Transcripted"
INTERVAL=30

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║         TRANSCRIPTED 1-HOUR RELIABILITY TEST MONITOR          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "Started: $(date)"
echo "Checking every ${INTERVAL}s"
echo ""
echo "Press Ctrl+C to stop"
echo "────────────────────────────────────────────────────────────────────"

START_TIME=$(date +%s)
INITIAL_MEM=""

format_bytes() {
    local bytes=$1
    if [ -z "$bytes" ] || [ "$bytes" = "0" ]; then
        echo "0B"
    elif [ "$bytes" -ge 1073741824 ]; then
        printf "%.2fGB" $(echo "scale=2; $bytes/1073741824" | bc)
    elif [ "$bytes" -ge 1048576 ]; then
        printf "%.1fMB" $(echo "scale=1; $bytes/1048576" | bc)
    elif [ "$bytes" -ge 1024 ]; then
        printf "%.0fKB" $(echo "scale=0; $bytes/1024" | bc)
    else
        echo "${bytes}B"
    fi
}

format_duration() {
    local secs=$1
    local mins=$((secs / 60))
    local hrs=$((mins / 60))
    mins=$((mins % 60))
    secs=$((secs % 60))
    if [ $hrs -gt 0 ]; then
        printf "%dh %dm %ds" $hrs $mins $secs
    elif [ $mins -gt 0 ]; then
        printf "%dm %ds" $mins $secs
    else
        printf "%ds" $secs
    fi
}

while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    echo ""
    printf "${BLUE}[$(date '+%H:%M:%S')]${NC} Elapsed: $(format_duration $ELAPSED)\n"
    echo "────────────────────────────────────────────────────────────────────"

    # 1. App Status
    PID=$(pgrep -x "$APP_NAME" 2>/dev/null || echo "")
    if [ -z "$PID" ]; then
        printf "${RED}❌ $APP_NAME is NOT running!${NC}\n"
    else
        MEM_KB=$(ps -o rss= -p $PID 2>/dev/null | tr -d ' ')
        MEM_MB=$((MEM_KB / 1024))
        CPU=$(ps -o %cpu= -p $PID 2>/dev/null | tr -d ' ')

        # Track memory growth
        if [ -z "$INITIAL_MEM" ]; then
            INITIAL_MEM=$MEM_MB
        fi
        MEM_GROWTH=$((MEM_MB - INITIAL_MEM))

        printf "${GREEN}✅ $APP_NAME running${NC} (PID: $PID)\n"
        printf "   Memory: ${MEM_MB}MB"
        if [ $MEM_GROWTH -gt 0 ]; then
            printf " (+${MEM_GROWTH}MB since start)"
        fi
        printf "\n   CPU: ${CPU}%%\n"

        # Warn if memory grows too much
        if [ $MEM_MB -gt 500 ]; then
            printf "   ${YELLOW}⚠️  High memory usage!${NC}\n"
        fi
    fi

    # 2. Active Recording Files (in ~/Documents, not ~/Documents/Transcripted)
    echo ""
    echo "📁 Active Recording Files:"

    # Find recent WAV files (modified in last hour)
    MIC_FILE=$(find "$DOCUMENTS_DIR" -maxdepth 1 -name "meeting_*_mic.wav" -mmin -60 2>/dev/null | sort -r | head -1)
    SYS_FILE=$(find "$DOCUMENTS_DIR" -maxdepth 1 -name "meeting_*_system.wav" -mmin -60 2>/dev/null | sort -r | head -1)

    if [ -z "$MIC_FILE" ] && [ -z "$SYS_FILE" ]; then
        printf "   ${YELLOW}No active recordings${NC} (idle or already processed)\n"
    else
        if [ -n "$MIC_FILE" ]; then
            MIC_SIZE=$(stat -f%z "$MIC_FILE" 2>/dev/null || echo "0")
            MIC_NAME=$(basename "$MIC_FILE")
            printf "   🎤 Mic:    $(format_bytes $MIC_SIZE)  [$MIC_NAME]\n"
        fi
        if [ -n "$SYS_FILE" ]; then
            SYS_SIZE=$(stat -f%z "$SYS_FILE" 2>/dev/null || echo "0")
            SYS_NAME=$(basename "$SYS_FILE")
            printf "   🔊 System: $(format_bytes $SYS_SIZE)  [$SYS_NAME]\n"
        fi

        # Estimate recording duration from file size
        # System audio: 48kHz * 4 bytes * 2 channels = 384000 bytes/sec
        if [ -n "$SYS_SIZE" ] && [ "$SYS_SIZE" -gt 0 ]; then
            EST_SECS=$((SYS_SIZE / 384000))
            printf "   ⏱️  Est. duration: ~$(format_duration $EST_SECS)\n"
        fi
    fi

    # 3. Disk Space
    echo ""
    AVAIL=$(df -h "$DOCUMENTS_DIR" | tail -1 | awk '{print $4}')
    echo "💾 Disk available: $AVAIL"

    # 4. Recent Errors (check system log for Transcripted process)
    echo ""
    echo "📋 Console Status (last 2 min):"

    # Check specifically for the CRITICAL CoreAudio overload (skipping cycles = dropped audio)
    # This is the exact error string that indicates audio is being lost
    OVERLOAD_MSG=$(log show --predicate 'eventMessage contains "skipping cycle due to overload"' --style compact --last 2m 2>/dev/null | head -1)

    if [ -n "$OVERLOAD_MSG" ]; then
        printf "   ${RED}🔴 CRITICAL: CoreAudio dropping audio buffers!${NC}\n"
        printf "   ${RED}   Recording may have gaps${NC}\n"
    else
        printf "   ${GREEN}✅ Audio capture healthy${NC}\n"
    fi

    # 5. Recent Transcripts (in ~/Documents/Transcripted)
    RECENT_TRANSCRIPT=$(find "$TRANSCRIPTS_DIR" -name "*.md" -mmin -5 2>/dev/null | head -1)
    if [ -n "$RECENT_TRANSCRIPT" ]; then
        echo ""
        printf "${GREEN}📝 Recent transcript: $(basename "$RECENT_TRANSCRIPT")${NC}\n"
    fi

    sleep $INTERVAL
done
