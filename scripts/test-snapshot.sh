#!/bin/bash
# Quick diagnostic snapshot for Transcripted testing
# Run this after a test session and share the output with Claude Code

echo "=== TRANSCRIPTED TEST SNAPSHOT ==="
echo "Timestamp: $(date)"
echo ""

echo "=== LAST 50 LOG ENTRIES ==="
tail -50 ~/Library/Logs/Transcripted/app.jsonl
echo ""

echo "=== ERRORS IN LAST 200 ENTRIES ==="
tail -200 ~/Library/Logs/Transcripted/app.jsonl | grep '"l":"error"' || echo "No errors found"
echo ""

echo "=== WARNINGS IN LAST 200 ENTRIES ==="
tail -200 ~/Library/Logs/Transcripted/app.jsonl | grep '"l":"warn"' || echo "No warnings found"
echo ""

echo "=== LATEST TRANSCRIPT ==="
TRANSCRIPT_DIR="${HOME}/Claude Brain/Meetings"
if [ -d "$TRANSCRIPT_DIR" ]; then
    LATEST=$(ls -t "$TRANSCRIPT_DIR"/*.md 2>/dev/null | head -1)
    if [ -n "$LATEST" ]; then
        echo "File: $LATEST"
        head -40 "$LATEST"
    else
        echo "No transcripts found"
    fi
else
    echo "Transcript directory not found"
fi
echo ""

echo "=== SPEAKER DATABASE ==="
sqlite3 ~/Documents/Transcripted/speakers.sqlite "SELECT id, display_name, name_source, call_count, confidence, last_seen FROM speakers ORDER BY last_seen DESC LIMIT 10;" 2>/dev/null || echo "Could not query"
echo ""

echo "=== RECENT RECORDINGS (stats) ==="
sqlite3 ~/Documents/Transcripted/stats.sqlite "SELECT date, time, duration, speaker_count, word_count FROM recordings ORDER BY rowid DESC LIMIT 5;" 2>/dev/null || echo "Could not query"
echo ""

echo "=== FAILED TRANSCRIPTIONS ==="
cat ~/Documents/Transcripted/failed_transcriptions.json 2>/dev/null || echo "No failed queue"
echo ""

echo "=== CURRENT SETTINGS ==="
defaults read com.transcripted.app 2>/dev/null | grep -E "transcriptionProvider|enableMeetingDetection|autoRecordMeetings|enableQwenSpeakerInference|enableUISounds|useAuroraRecording|enableObsidianFormat|userName"
echo ""

echo "=== CRASH REPORTS ==="
ls -lt ~/Library/Logs/DiagnosticReports/*Transcripted* 2>/dev/null || echo "No crashes"
echo ""

echo "=== APP PROCESS ==="
ps aux | grep -i transcripted | grep -v grep || echo "App not running"
echo ""

echo "=== DONE ==="
