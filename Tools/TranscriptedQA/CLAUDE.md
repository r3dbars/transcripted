# TranscriptedQA - QA Testing CLI Tool

QA testing suite for Transcripted. 23 Swift files total: `Package.swift` plus 22 files under `Sources/TranscriptedQA/`.

## File Index

### Package Root (1 file)

| File | Purpose |
|------|---------|
| `Package.swift` | Swift package manifest for the standalone QA CLI |

### Root (1 file)

| File | Purpose |
|------|---------|
| `TranscriptedQA.swift` | CLI entry point (`@main`), shared path helpers, and subcommand registration |

### Commands/ (10 files)

| File | Purpose |
|------|---------|
| `CheckHealth.swift` | Quick health check: DB integrity, model presence, disk space |
| `GenerateFixtures.swift` | Generate valid test data (transcripts, legacy JSON artifacts, DB records) for CI or manual verification |
| `RoundTrip.swift` | Generate test data, validate, corrupt, re-validate, and confirm validators catch real defects |
| `StressTest.swift` | Generate large datasets and validate performance + correctness |
| `ValidateAll.swift` | Run all validators: transcripts, DB, index, logs, artifacts |
| `ValidateArtifacts.swift` | Check optional legacy JSON artifacts, YAML frontmatter, speaker clips |
| `ValidateDatabase.swift` | SpeakerDB and StatsDB integrity, schema validation, corruption check |
| `ValidateIndex.swift` | Legacy transcripted.json consistency and orphan-file checks |
| `ValidateLogs.swift` | Log file analysis and `app.jsonl` format validation |
| `ValidateTranscripts.swift` | Transcript content validation, speaker attribution, timestamp checks |

### Generators/ (1 file)

| File | Purpose |
|------|---------|
| `TestDataGenerator.swift` | Shared fixture builder used by `GenerateFixtures`, `RoundTrip`, and `StressTest` |

### Validators/ (7 files)

| File | Purpose |
|------|---------|
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
| `ValidationResult.swift` | Validation outcome: success/failure, error details, warnings, and metrics |

## Usage

```bash
# Health check
transcripted-qa check-health

# Validate all
transcripted-qa validate-all

# Validate specific areas
transcripted-qa validate-database
transcripted-qa validate-transcripts
transcripted-qa validate-index
transcripted-qa validate-logs

# Override nonstandard locations when captures are relocated
transcripted-qa validate-all --path /path/to/meetings --state-dir /path/to/state --log-path /path/to/app.jsonl

# Test data generation
transcripted-qa generate-fixtures --output /tmp/my-test-data
transcripted-qa round-trip
transcripted-qa stress-test --transcripts 100 --speakers-per-transcript 4 --utterances-per-transcript 200
```

## Validation Results

`ValidationResult` / `ValidationReport` capture:
- `success: Bool` - Overall validation status
- `errors: [String]` - List of errors found
- `warnings: [String]` - Non-critical warnings
- `metrics` - Validation metrics (record counts, file sizes, etc.)

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

## Gotchas

- All validators run synchronously on background threads
- SQLite readers use dedicated utility queues for thread safety
- Validation results are structured for programmatic consumption
- Error messages are human-readable for CLI output
- Defaults now prefer `~/Library/Application Support/Transcripted/captures/meetings`, `~/Library/Application Support/Transcripted/state/`, and `~/Library/Application Support/Transcripted/logs/app.jsonl`
- If current Transcripted paths are missing, the resolver falls back to legacy Draft exports and then `~/Documents/Transcripted/`
- `--path` overrides the meetings capture directory only; use `--state-dir` and `--log-path` when validating unusual layouts
