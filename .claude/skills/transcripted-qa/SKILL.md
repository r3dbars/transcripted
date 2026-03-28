---
name: transcripted-qa
description: Run comprehensive QA testing on the Transcripted application — build verification, unit tests, artifact validation, log analysis, and optionally UI smoke testing via computer-use.
---

# Transcripted QA — Full Application Testing

You are a QA engineer testing the Transcripted macOS app. When this skill is invoked, run a comprehensive 6-tier test pass, report all findings, and enter a fix loop for any failures.

## Phase 1: Assess Scope

Determine what to test:

1. Run `git diff main --name-only` to see what files changed
2. Map changed files to test domains:
   - `Core/Audio*` → audio, recovery
   - `Core/Transcription*` → pipeline, merging
   - `Core/TranscriptSaver*`, `Core/TranscriptFormatter*` → saving, artifact validation
   - `Core/AgentOutput*` → JSON sidecars, index
   - `Core/StatsDatabase*` → stats
   - `Core/FailedTranscription*` → retry queue
   - `Services/SpeakerDatabase*`, `Services/SpeakerEmbedding*`, `Services/SpeakerProfile*` → speaker DB
   - `Services/EmbeddingClusterer*` → clustering
   - `Services/QwenService*` → Qwen inference
   - `UI/FloatingPanel/*` → pill states, trays
   - `UI/Settings/*` → settings
   - `Onboarding/*` → onboarding
   - `Design/*` → visual tokens
3. If the user said "test everything" or scope is unclear, run ALL tiers
4. Note the current transcript count and speaker count BEFORE testing (read `~/Documents/Transcripted/transcripted.json`)

## Phase 2: Execute Test Tiers

Run tiers in order. Stop and enter the fix loop if Tier 0 fails.

### Tier 0 — Build Verification

```bash
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1
```

If this fails, extract the compiler errors and enter the fix loop. Do NOT proceed to other tiers.

### Tier 1 — Unit Tests

```bash
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted test CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1
```

Parse the output for:
- Total tests run, passed, failed
- For each failure: test class, method name, assertion message, file:line
- If tests fail, log the failures but continue to Tier 2

### Tier 2 — Artifact Validation (CLI)

```bash
cd Tools/TranscriptedQA && swift run transcripted-qa validate-all --format json 2>&1
```

This validates all on-disk artifacts:
- Transcript .md files (YAML frontmatter, required keys, engine values, sources, capture quality, counts, sections, permissions, sidecar exists)
- JSON sidecars (schema, version, engines, duration, utterance sorting, speaker references, md match)
- Speaker database (integrity, WAL mode, schema, embedding size, UUID validity, confidence range, call counts, name sources, permissions)
- Stats database (integrity, schema, dates, durations, permissions)
- Log file (JSON Lines format, required keys, levels, subsystems, entry count, error rate)
- Index file (count match, files exist, no duplicate speakers)
- System health (directories, Qwen model, disk space, macOS version, crash reports)

Parse the JSON output. Report any FAIL or WARN results.

### Tier 3 — Log & Crash Analysis

Read `~/Library/Logs/Transcripted/app.jsonl` directly. Check for:
- Any `error` level entries — quote the message and subsystem
- Concentration of errors in one subsystem (indicates a specific area is broken)
- Timestamp gaps > 60 seconds between consecutive entries (may indicate crash or hang)
- Check `~/Library/Logs/DiagnosticReports/` for any files containing "Transcripted"

### Tier 4 — End-to-End Flow Testing (computer-use, optional)

Only run if: UI files changed, OR user said "test everything", OR user explicitly requested UI testing.

Prerequisites: Call `request_access` with `apps: ["Transcripted"]` and `reason: "QA testing the Transcripted app"`.

**Flow E1: Recording Happy Path**
1. Press Cmd+Shift+R to start recording
2. Screenshot — verify pill shows recording state (LED dots, timer)
3. Wait 8 seconds
4. Press Cmd+Shift+R to stop
5. Screenshot — verify pill shows processing state (progress bar)
6. Wait for processing (poll screenshots every 5s, max 120s)
7. Screenshot — verify saved card appears (green accent, title/duration/speakers)
8. Pass: all state transitions completed correctly

**Flow E2: Transcript on Disk**
After E1 completes, read the newest .md file in ~/Documents/Transcripted/
- Verify it exists and was created within the last 2 minutes
- Verify YAML frontmatter is valid
- Verify .json sidecar exists

**Flow E3: Settings Window**
1. Right-click pill → click Settings
2. Screenshot — verify Settings window opened
3. Verify all section headers visible: Profile, All Time Stats, Meeting Detection, Speaker Intelligence, AI Services, Voice Fingerprints
4. Close Settings

**Flow E4: Transcript Tray**
1. Hover pill → click Transcripts button
2. Screenshot — verify tray opened showing recent transcripts
3. Click outside tray → verify it dismissed

**Flow E5: Short Recording Rejection**
1. Press Cmd+Shift+R
2. Immediately press Cmd+Shift+R again (< 2s)
3. Screenshot — verify either error toast or pill returns to idle
4. No crash

**Flow E6: Context Menu**
1. Right-click pill
2. Screenshot — verify menu shows: Start Recording, View Transcripts, Open Transcripts Folder, Settings, Quit
3. Press Escape to dismiss

### Tier 5 — Cross-Feature Interaction Tests (computer-use, optional)

Only run if user said "test everything".

**X1: Settings Persistence**
1. Open Settings → change Profile name to a unique test value
2. Close Settings → reopen Settings
3. Verify name field shows the test value

**X2: Hover During Processing**
1. During processing (from E1), hover over pill
2. Verify progress is visible and pill responds to hover

**X3: Rapid Re-record**
1. After saved card appears, immediately press Cmd+Shift+R
2. Verify recording starts without crash or jammed state

### Tier 6 — Stress Tests (computer-use, optional)

Only run if user explicitly requests stress testing.

**S1: Rapid Start/Stop**
Start and stop recording 5 times with < 1s gaps. Verify pill returns to idle each time.

**S2: Settings Spam**
Open and close Settings 10 times rapidly. Verify no crash or visual corruption.

## Phase 3: Report

After all tiers complete, produce a structured report:

```
## Transcripted QA Report — [today's date]

### Scope: [all | list of changed files]

### Tier 0 — Build: PASS/FAIL
[If failed, show compiler errors]

### Tier 1 — Unit Tests: X/Y passed
[If failures, show test name + assertion + file:line for each]

### Tier 2 — Artifact Validation: X passed, Y failed, Z warnings
[Show any FAIL or WARN results]

### Tier 3 — Log Analysis: X errors, Y warnings
[Quote notable errors with subsystem]

### Tier 4 — End-to-End: X/Y flows passed
[Results per flow, with screenshots for failures]

### Tier 5 — Cross-Feature: X/Y passed
[Results per test]

### Tier 6 — Stress: X/Y passed
[Results per test]

### Issues Found
1. [severity] [description] → [file:line] → [suggested fix]
2. ...

### Warnings
- [notable warnings that don't block but should be tracked]

### Performance
- Build time: Xs
- Test suite: Xs
- CLI validation: Xs
```

## Fix Loop

When a tier fails:

1. **Identify**: Extract the test name, assertion message, and file:line from the failure output
2. **Trace**: Read the failing test file. Read the source file being tested. Identify the code path that broke.
3. **Diagnose**: Is the test outdated (expectations changed) or is the code broken (regression)?
4. **Fix**: Edit the appropriate file — either update the test or fix the source code
5. **Verify**: Re-run ONLY the failing tier. If it passes, re-run the full suite to check for regressions.

### Fix Loop Guardrails
- Max 3 fix attempts per failure
- NEVER modify `Audio.swift` or `SystemAudioCapture.swift` without asking the user — these are audio thread files
- Each fix should be a separate git commit
- If you can't fix it in 3 attempts, report it as unresolved and move on

## Key File Locations

| Artifact | Path |
|----------|------|
| Transcripts | ~/Documents/Transcripted/*.md |
| JSON sidecars | ~/Documents/Transcripted/*.json |
| Index | ~/Documents/Transcripted/transcripted.json |
| Speaker DB | ~/Documents/Transcripted/speakers.sqlite |
| Stats DB | ~/Documents/Transcripted/stats.sqlite |
| Failed queue | ~/Documents/Transcripted/failed_transcriptions.json |
| Speaker clips | ~/Documents/Transcripted/speaker_clips/ |
| App logs | ~/Library/Logs/Transcripted/app.jsonl |
| Crash reports | ~/Library/Logs/DiagnosticReports/ |
| CLI tool | Tools/TranscriptedQA/ |
