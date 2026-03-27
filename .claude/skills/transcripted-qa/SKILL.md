---
name: transcripted-qa
description: Run comprehensive QA testing on the Transcripted application — build, unit tests, deep code audit, artifact validation, log analysis, and fix loop.
---

# Transcripted QA — Full Application Testing

You are a QA engineer testing the Transcripted macOS app. When this skill is invoked, run a comprehensive test pass across all tiers, audit changed code for bugs, report all findings in a structured report, and enter a fix loop for any failures.

## Phase 1: Assess Scope

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

Run tiers in order. Stop and enter the fix loop if Tier 0 fails. Run independent tiers in parallel where possible (e.g., Tier 2 + Tier 3 can run alongside Tier 1). Note: Tier 3.5 and Tier 6 require the live app and cannot run in parallel with tiers that launch or build it.

### Tier 0 — Build Verification

```bash
cd /Users/redbars/redbars/code/transcripted && xcodebuild -project Transcripted.xcodeproj -scheme Transcripted -configuration Debug build CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1
```

If FluidAudio module errors occur, run `scripts/build-fluidaudio.sh --force` and copy artifacts:
```bash
cp -R scripts/fluidaudio-libs/* fluidaudio-libs/ && cp -R scripts/fluidaudio-modules/* fluidaudio-modules/
```

If this fails, extract the compiler errors and enter the fix loop. Do NOT proceed to other tiers.

### Tier 1 — Unit Tests (~552 tests across 44 test files)

```bash
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted test -destination 'platform=macOS' CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO 2>&1
```

**What's covered** (by test file → source file):

| Test File | Source Under Test | What It Tests |
|-----------|-------------------|---------------|
| **Core Tests** | | |
| `DateFormattingHelperTests` | `DateFormattingHelper` | ISO dates, time-only, filename-precise formats |
| `DateParserTests` | `DateParser` | Date string parsing from various formats |
| `DisplayStatusTests` | `DisplayStatus` | Status enum transitions, progress values |
| `EmbeddingTests` | `SpeakerProfile` | Embedding vector operations |
| `FailedTranscriptionManagerTests` | `FailedTranscriptionManager` | Retry queue, persistence, auto-cleanup |
| `FailedTranscriptionTests` | `FailedTranscription` | Model properties, serialization |
| `PipelineErrorTests` | `TranscriptionTypes` | Error types, retryable classification |
| `RecordingValidatorTests` | `RecordingValidator` | Disk space, permissions, path safety |
| `SpeechSegmentationTests` | `Transcription` | Silence detection, segment merging |
| `StatsDatabaseTests` | `StatsDatabase` | Schema, queries, aggregations |
| `TranscriptionTypesTests` | `TranscriptionTypes` | Utterance, result, speaker segment models |
| `DiagnosticExporterTests` | `DiagnosticExporter` | System info collection, GitHub issue URLs |
| `ModelDownloadServiceTests` | `ModelDownloadService` | Error classification (12+ codes), error descriptions, disk space |
| `TranscriptExporterTests` | `TranscriptExporter` | Markdown export, plain text export, filename generation, speaker prefix stripping |
| `TranscriptFormatterTests` | `TranscriptFormatter` | YAML escaping, source labels, markdown generation, frontmatter construction |
| `TranscriptMetadataBuilderTests` | `TranscriptMetadataBuilder` | CaptureQuality thresholds, RecordingHealthInfo |
| `TranscriptSaverTests` | `TranscriptSaver` | File save, notifications |
| `TranscriptStoreTests` | `TranscriptStore` | Transcript reading for tray UI |
| `AgentOutputTests` | `AgentOutput` | JSON sidecar generation, index updates |
| **Service Tests** | | |
| `AudioResamplerTests` | `AudioResampler` | 16kHz resampling, format conversion |
| `SpeakerDatabaseTests` | `SpeakerDatabase` + `SpeakerProfileMerger` | Find by name, merge profiles, EMA update, WAL mode, confidence cap |
| `SpeakerEmbeddingMatcherTests` | `SpeakerEmbeddingMatcher` | Cosine similarity (8 cases), L2 normalize, speaker matching with thresholds |
| `SpeakerProfileMergerTests` | `SpeakerProfileMerger` | Name variants (15+ pairs), case insensitivity, empty strings, symmetry |
| `QwenServiceTests` | `QwenService` | Response parsing, JSON extraction, markdown fence stripping, generic title filtering |
| `MeetingDetectorTests` | `TranscriptionTypes` | SpeakerNameUpdate action enum cases |
| `EmbeddingClustererTests` | `EmbeddingClusterer` | Cluster merging, absorption, DB-informed split |
| **UI Tests** | | |
| `PillStateManagerTests` | `PillStateManager` | State machine transitions |
| `ContextualErrorBannerTests` | `ContextualErrorBanner` | Error classification (6 types), icons, titles, recovery hints |
| `PillDimensionsTests` | `Design/Animations` | All pill dimension constants, size relationships, animation timing |
| `PillSoundsTests` | `PillStateManager` | System sound availability, sound preference toggle |

Parse output for: total tests run, passed, failed. For each failure: test class, method name, assertion message, file:line.

### Tier 2 — Artifact Validation (68 CLI checks)

```bash
cd Tools/TranscriptedQA && swift run transcripted-qa validate-all --format json 2>&1
```

**What's checked** (by category):

| Category | Checks | What It Validates |
|----------|--------|-------------------|
| **Transcripts** (per .md file) | yaml-present, yaml-required-keys, yaml-engine-stt, yaml-engine-diarize, yaml-sources, yaml-capture-quality, yaml-count-mic_utterances, yaml-count-system_utterances, yaml-count-total_word_count, body-has-sections, sidecar-exists, permissions | YAML frontmatter completeness, engine names match expected values, source types are valid, counts present and numeric, markdown has expected sections, .json sidecar exists alongside each .md, file permissions not world-readable |
| **JSON Sidecars** (per .json file) | json-valid, json-version, json-engine-stt, json-engine-diarize, json-duration, json-utterances-sorted, json-speaker-refs, md-match | Valid JSON, schema version present, engine names, duration is positive number, utterances sorted by start time, all speaker refs resolve, corresponding .md file exists |
| **Speaker DB** | speakers-integrity, speakers-wal-mode, speakers-schema, speakers-embedding-size, speakers-no-null-embeddings, speakers-valid-uuids, speakers-confidence-range, speakers-callcount-positive, speakers-name-source, speakers-permissions | SQLite integrity check, WAL journal mode, schema has expected columns, embeddings are 1024 bytes (256 floats), no NULL embeddings, UUIDs are valid format, confidence 0.0-1.0, call counts positive, name sources are known values, 0600 permissions |
| **Stats DB** | stats-integrity, stats-schema-recordings, stats-schema-daily, stats-positive-durations, stats-valid-dates, stats-permissions | SQLite integrity, recordings table schema, daily_activity table schema, no negative durations, dates are valid YYYY-MM-DD, 0600 permissions |
| **Logs** | jsonl-valid, jsonl-required-keys, jsonl-valid-levels, jsonl-valid-subsystems, jsonl-entry-count, jsonl-error-rate | Every line parses as JSON, required keys (ts, level, subsystem, message), levels are known values, subsystems are known values, reasonable entry count, error+warning rate below threshold |
| **Index** | json-valid, count-match, files-exist, no-duplicate-speakers | Valid JSON, transcript count matches array length, all referenced files exist on disk, no duplicate speaker IDs |
| **Health** | transcript-dir, logs-dir, qwen-model, disk-space, macos-version, no-crashes | ~/Documents/Transcripted exists, log directory exists, Qwen model files present, sufficient disk space, macOS 14.2+, no crash reports in DiagnosticReports |

After validating real data, also run the round-trip test:

```bash
cd Tools/TranscriptedQA && swift run transcripted-qa round-trip 2>&1
```

This generates clean test fixtures, validates them (86 checks, expect 0 failures), then runs 8 corruption tests — each one modifies the data in a specific way and verifies the validator catches it:
1. Remove YAML `transcription_engine` key → TranscriptValidator FAIL
2. Delete JSON sidecar file → TranscriptValidator FAIL (sidecar-exists)
3. Unsort utterances in JSON → JSONSidecarValidator FAIL
4. Set negative `duration_seconds` → JSONSidecarValidator FAIL
5. Corrupt speakers.sqlite → SpeakerDBValidator FAIL (integrity)
6. Set invalid date in stats.sqlite → StatsDBValidator FAIL
7. Set wrong `transcript_count` → IndexValidator FAIL
8. Write invalid JSON line → LogValidator FAIL

### Tier 3 — Log & Crash Analysis

Read `~/Library/Logs/Transcripted/app.jsonl` directly. Check for:
- Any `error` level entries — quote the message and subsystem
- Concentration of errors in one subsystem (indicates a specific area is broken)
- Timestamp gaps > 60 seconds between consecutive entries (may indicate crash or hang)
- Check `~/Library/Logs/DiagnosticReports/` for any files containing "Transcripted"

### Tier 3.5 — UI Smoke Tests (AppleScript, requires app running)

**Skip this tier** unless: UI files changed (`UI/**`, `Design/**`, `Onboarding/**`), OR the user said "test everything". If the script is missing or returns a non-zero exit code for non-accessibility reasons, WARN and continue — do not enter the fix loop.

```bash
bash scripts/ui-smoke-test.sh
```

If Transcripted is not running, the script will attempt to launch it. Requires Accessibility permissions for Terminal/Claude Code.

**What's checked** (~16 checks):

| Check | What It Tests |
|-------|---------------|
| `ui/app-running` | App process is alive |
| `ui/menu-bar-only` | App runs as accessory (no dock icon) |
| `ui/menu-bar-item` | Status bar item exists |
| `ui/idle-no-windows` | No windows open at idle state |
| `ui/hotkey-responsive` | Cmd+Shift+R triggers log activity |
| `ui/hotkey-stop` | Second Cmd+Shift+R stops recording |
| `ui/settings-window` | Settings opens from menu and closes with Cmd+W |
| `ui/context-menu` | Right-click menu is readable |
| `ui/menu-item-Start-Recording` | "Start Recording" menu item present |
| `ui/menu-item-Settings` | "Settings" menu item present |
| `ui/menu-item-Quit` | "Quit" menu item present |
| `ui/idle-cpu` | CPU usage < 5% at idle |
| `ui/idle-memory` | Memory < 500MB at idle |
| `ui/defaults-*` | UserDefaults keys readable |
| `ui/accessibility` | App responds to accessibility queries |

If the script cannot get accessibility access, checks will WARN (not FAIL). This tier is informational — failures here don't trigger the fix loop.

### Tier 4 — Deep Code Audit

**Skip this tier** if no source files changed (only test files, config files, or skill files changed).

For each changed source file (NOT test files), launch a subagent to:
1. Read the full file and the `git diff main` for that file
2. Check for: bugs, race conditions, security issues, edge cases, memory leaks, force unwraps, API misuse
3. Rate each finding: critical / high / medium / low / info
4. For bugs found, check if there's an existing test covering that code path

### Tier 5 — Test Coverage Analysis

**Skip this tier** if no source files changed (only test files, config files, or skill files changed).

For each changed source file, check:
1. Does a corresponding test file exist?
2. What % of public methods are tested?
3. Are there untested error paths or edge cases?
4. Are test assertions meaningful (not trivially true)?
5. Do tests use isolated state (temp files, not shared singletons)?

### Tier 6 — End-to-End UI + Audio Testing (requires live app)

**Skip this tier** unless: the user said "test everything" or "run e2e", OR Audio/Transcription/TranscriptSaver files changed AND the user has confirmed the app is running. This tier takes ~2 minutes minimum due to the YouTube recording flow.

Run the full E2E test script:

```bash
bash scripts/ui-e2e-test.sh /tmp/transcripted-e2e
```

Requires: Transcripted running, Accessibility + Screen Recording permissions for the terminal app. Takes screenshots at every step for visual verification. Uses AppleScript to drive the UI via menu items (not hotkeys — hotkeys can be intercepted by focused apps like Chrome).

**Flows tested** (~30 checks):

| Flow | What It Does | What It Verifies |
|------|-------------|------------------|
| **E1: Idle State** | Check app at rest | No spurious windows, CPU < 5%, memory < 500MB |
| **E2: Context Menu** | Click menu bar item | "Start Recording", "Open Transcripts", "Settings", "Quit" all present |
| **E3: Settings** | Open Settings via menu, then Cmd+W | Window opens with UI content, closes cleanly |
| **E4: Recording** | Start via menu, wait 8s, stop via menu | Log activity confirms recording, new .md + .json created |
| **E5: Transcript Verification** | Read newest transcript | YAML has required keys, JSON sidecar valid, CLI validator passes |
| **E6: Short Recording** | Start and stop within 0.5s | App doesn't crash |
| **E7: Rapid Stress** | 5x rapid start/stop cycles | App survives, CPU recovers |
| **E8: YouTube Comparison** | Open a known YouTube video (JFK Moon Speech), record 30s of system audio, compare transcript | Word count > 0, system utterances captured, expected words from speech found in transcript, JSON sidecar valid |

After running, read screenshots from the output directory to visually verify:
- Recording state transitions (pill shows timer)
- Settings window content
- YouTube video was playing during capture
- Transcript content matches expected speech

## Phase 3: Report

After all tiers complete, produce this report:

```
## Transcripted QA Report — [today's date]

### Scope
[Changed files count, mapped domains, baseline transcript/speaker counts]

### Tier 0 — Build: PASS/FAIL
[Build time. If failed, show compiler errors]

### Tier 1 — Unit Tests: X/Y passed
[Test time. If failures: test name + assertion + file:line for each]

### Tier 2 — Artifact Validation: X passed, Y failed, Z warnings
[Show any FAIL or WARN results with details]

### Tier 3 — Log Analysis
[Total entries, error count by subsystem, notable errors quoted, timestamp gaps, crash reports]

### Tier 3.5 — UI Smoke Tests: X passed, Y warnings
[Results per check. WARN if accessibility permissions missing]

### Tier 4 — Code Audit
[Per-file findings table: file, issue, severity, line]

### Tier 5 — Coverage Analysis
[Per-file: tested methods vs untested, notable gaps]

### Tier 6 — End-to-End: X/Y flows passed (or SKIPPED)
[Results per flow. Include YouTube comparison: words captured, content match score, processing time]
[Read screenshots from /tmp/transcripted-e2e/ and verify UI state visually]

### Issues Found
1. [severity] [description] → [file:line] → [fix applied / suggested fix]
2. ...

### Warnings
- [notable warnings that don't block but should be tracked]

### What's NOT Tested
- [List of source files with zero test coverage that were changed]
- [List of important untested code paths in covered files]
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
- Tier 3.5 is informational — do NOT enter the fix loop for Tier 3.5 failures under any circumstances
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

## Known Baselines

- Unit tests: ~552 across 44 test files (as of 2026-03-26)
  - Core: 24 files (security, retry, pipeline, formatting, save chain, recording validator)
  - Services: 9 files (speaker DB dangerous ops, lifecycle, embedding, QwenService, ParakeetService)
  - UI: 5 files (ClipAudioPlayer regression, pill state, dimensions, sounds, error banner)
  - Integration: 6 files (save chain, formatter round-trip, speaker lifecycle, AgentOutput, cross-artifact consistency, edge cases + fuzz)
  - Helpers: 2 files (MockServices, TestFixtures)
- CLI checks: 68 per validation run + 86 generated fixture checks + 21 corruption round-trip checks + 1030 stress test checks
- CLI commands: `validate-all`, `round-trip`, `generate-fixtures`, `stress-test`, plus per-category validators
- UI smoke tests: ~16 checks (process, menu bar, context menu, CPU, memory, accessibility, UserDefaults)
- E2E tests: ~30 checks across 8 flows (idle, menu, settings, recording, transcript verification, short recording, rapid stress, YouTube comparison)
- Expected warnings: transcript permissions (644), log error rate if > 10%, empty speaker embeddings
- FluidAudio modules must match current Swift toolchain version — rebuild with `scripts/build-fluidaudio.sh --force` if module errors occur
- YouTube test uses JFK Moon Speech (NASA Video, `WZyRbnpGyzQ` at t=90s) — expects words: condense, history, century, animals, caves, years
