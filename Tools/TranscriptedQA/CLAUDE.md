# TranscriptedQA - QA Testing CLI Tool

QA testing suite for Transcripted. `Package.swift`, files under `Sources/TranscriptedQA/`, and test files under `Tests/TranscriptedQATests/`.

The current package is intentionally small:

### Package Root (1 file)

| File | Purpose |
|------|---------|
| `Package.swift` | Swift package manifest for the standalone QA CLI |

### Root (1 file)

| File | Purpose |
|------|---------|
| `TranscriptedQA.swift` | CLI entry point (`@main`), shared path helpers, and subcommand registration |

### Commands/ (13 files)

| File | Purpose |
|------|---------|
| `CheckHealth.swift` | Quick health check: DB integrity, model presence, disk space |
| `GenerateFixtures.swift` | Generate valid test data (transcripts, legacy JSON artifacts, DB records) for CI or manual verification |
| `ImportedAudioSmoke.swift` | Deterministic imported-audio artifact smoke: synthetic WAV, imported meeting Markdown, retained single-file audio, parser and validator proof |
| `UISmoke.swift` | Launch a built app and validate onboarding, menu bar, Home, Settings, and General navigation through macOS Accessibility |
| `PermissionState.swift` | No-prompt macOS permission-state probe for Codex computer-use and live QA blockers |
| `PackagedAppSmoke.swift` | Pre-publish packaged app smoke for app bundle metadata, Sparkle config, signing, dSYM, DMG, optional UI, and privacy-safe local logs |
| `RoundTrip.swift` | Generate test data, validate, corrupt, re-validate, and confirm validators catch real defects |
| `StressTest.swift` | Generate large datasets and validate performance + correctness |
| `SparkleUpdateSmoke.swift` | No-publish fake-state Sparkle update UI smoke for update-available and downloading menu surfaces |
| `ValidateAll.swift` | Run all validators: transcripts, dictations, DB, index, logs, artifacts |
| `ValidateArtifacts.swift` | Check optional legacy JSON artifacts, YAML frontmatter, speaker clips |
| `ValidateDatabase.swift` | SpeakerDB and StatsDB integrity, schema validation, corruption check |
| `ValidateIndex.swift` | Legacy transcripted.json consistency and orphan-file checks |
| `ValidateLogs.swift` | Log file analysis and `app.jsonl` format validation |
| `ValidateTranscripts.swift` | Transcript content validation, speaker attribution, timestamp checks |

### Generators/ (1 file)

| File | Purpose |
|------|---------|
| `TestDataGenerator.swift` | Shared fixture builder used by `GenerateFixtures`, `RoundTrip`, and `StressTest` |

### Validators/ (8 files)

| File | Purpose |
|------|---------|
| `DictationValidator.swift` | Dictation day markdown evidence and metadata checks |
| `HealthChecker.swift` | System health: disk space, model files, DB existence |
| `IndexValidator.swift` | Legacy index consistency and orphan-file checks |
| `JSONSidecarValidator.swift` | YAML frontmatter and agent JSON structure |
| `LogValidator.swift` | Log file parsing and error pattern detection |
| `SpeakerDBValidator.swift` | SpeakerDB schema, record count, embedding integrity |
| `StatsDBValidator.swift` | StatsDB schema, recording history, daily activity |
| `TranscriptValidator.swift` | Transcript content, speaker attribution, timestamp validity |

### Utilities/ (2 files)

| File | Purpose |
|------|---------|
| `SQLiteReader.swift` | SQLite file reading, query execution, result parsing |
| `YAMLParser.swift` | YAML frontmatter parsing and metadata extraction |

### Models/ (1 file)

| File | Purpose |
|------|---------|
| `ValidationResult.swift` | shared `ValidationResult`, `ValidationReport`, and PASS/WARN/FAIL status types used for structured text or JSON validator output |

### Tests/

| File | Purpose |
|------|---------|
| `PackagedAppSmokeTests.swift` | package-level coverage for packaged app metadata, Sparkle config, dSYM UUIDs, DMG, and log privacy checks |
| `PermissionStateProbeTests.swift` | package-level coverage for permission-state probe modes and blocker classification |
| `PermissionStateRuntimeGateTests.swift` | package-level coverage for duplicate/wrong-running-app runtime gate warnings |
| `SparkleUpdateSmokeTests.swift` | package-level coverage for fake-state Sparkle update UI smoke evaluation |
| `ValidatorTests.swift` | package-level coverage for YAML parsing, legacy index validation, JSON sidecar validation, and `ValidationReport` exit-code behavior |

## Usage

```bash
cd Tools/TranscriptedQA
swift build
swift test

# Validate all
swift run transcripted-qa validate-all

# Validate specific areas
swift run transcripted-qa validate-database
swift run transcripted-qa validate-transcripts
swift run transcripted-qa validate-index
swift run transcripted-qa validate-logs
swift run transcripted-qa check-health
swift run transcripted-qa permission-state --mode computer-use
swift run transcripted-qa imported-audio-smoke --output /tmp/transcripted-imported-audio-smoke
swift run transcripted-qa sparkle-update-smoke --app ../../build/Transcripted.app --output /tmp/transcripted-sparkle-update-smoke
swift run transcripted-qa packaged-app-smoke --app ../../build/Transcripted.app --dsym ../../build/Transcripted.app.dSYM --run-ui-smoke

# UI automation smoke, local Accessibility permission required
swift run transcripted-qa ui-smoke --app ../../build/Transcripted.app

# Override nonstandard locations when captures are relocated
swift run transcripted-qa validate-all --path /path/to/meetings --dictations-path /path/to/dictations --state-dir /path/to/state --log-path /path/to/app.jsonl

# Test data generation
swift run transcripted-qa generate-fixtures --output /tmp/my-test-data
swift run transcripted-qa round-trip
swift run transcripted-qa stress-test --transcripts 100 --speakers-per-transcript 4 --utterances-per-transcript 200
```

## Validation Results

`ValidationResult` captures one structured check row with:
- `check` - validator check name
- `status` - `PASS`, `WARN`, or `FAIL`
- `target` - the file, database, or subsystem that was checked
- `detail` - optional human-readable detail when more context is useful

`ValidationReport` wraps all rows, computes a pass/fail/warn summary, exposes the CLI exit code, and can print either aligned text output or pretty JSON.

For agent and automation use, the JSON form also includes:
- `automation` - overall status, exit code, generated timestamp, and grouped-fingerprint count
- `failureFingerprints` - grouped non-pass checks with stable ids, counts, and affected targets

## Key Features

- **Health checks**: Quick system status before deep validation
- **Database integrity**: SpeakerDB and StatsDB corruption detection with backup / recreate pattern
- **Transcript validation**: Content, speaker attribution, timestamp consistency
- **Index validation**: Legacy `transcripted.json` checks when that file exists
- **Log analysis**: Error pattern detection, warning frequency tracking
- **Artifact validation**: YAML frontmatter, optional legacy JSON artifacts, speaker clips
- **Fixture generation**: `generate-fixtures` creates valid test data for use in CI or manual testing
- **Round-trip testing**: `round-trip` validates that validators correctly catch injected corruption
- **Stress testing**: `stress-test` generates large datasets to surface performance and correctness issues
- **Imported audio smoke**: `imported-audio-smoke` proves deterministic imported meeting artifact shape, `system_audio` metadata, retained single-file audio, parser discovery, and transcript validation. It is not native file-picker or real ML transcription proof.
- **Sparkle update smoke**: `sparkle-update-smoke` launches the built app through the launch-smoke harness with fake update-available and downloading states, then checks the real menu snapshot. It is local UI proof only, not live appcast/download/install proof.
- **UI smoke**: `ui-smoke` checks stable AX identifiers across first-run onboarding, menu bar, Home, and Settings, and exits `3` for Accessibility/TCC blockers
- **Packaged app smoke**: `packaged-app-smoke` validates a no-publish `build-beta.sh` artifact, including version/config parity, Sparkle keys, signing, dSYM UUIDs, DMG readability, optional menu bar UI, and local log privacy
- **Permission state**: `permission-state` prints the expected manual grant state, checks Codex host Accessibility/Event Posting/Input Monitoring/Screen Recording/Automation, verifies the Transcripted app bundle id, and warns on duplicate or wrong running Transcripted app instances

## Gotchas

- The package is now split across `Commands/`, `Validators/`, `Utilities/`, `Generators/`, and `Models/`, so keep `TranscriptedQA.configuration` in sync when adding or removing subcommands.
- Validators run synchronously on the calling thread; there is no internal dispatching
- SQLite readers open read-only connections with no internal queueing — callers own thread safety
- Validation results are structured for programmatic consumption and can be emitted as aligned text or pretty JSON via `ValidationReport`
- Error messages are human-readable for CLI output
- Defaults now prefer `~/Library/Application Support/Transcripted/captures/meetings`, `~/Library/Application Support/Transcripted/captures/dictations`, `~/Library/Application Support/Transcripted/state/`, and `~/Library/Application Support/Transcripted/logs/app.jsonl`
- If current Transcripted paths are missing, the resolver falls back to legacy Draft exports and then `~/Documents/Transcripted/`
- `--path` overrides the meetings capture directory only; use `--dictations-path`, `--state-dir`, and `--log-path` when validating unusual layouts
