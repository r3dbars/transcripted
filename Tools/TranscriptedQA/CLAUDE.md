# TranscriptedQA - QA Testing CLI Tool

QA testing suite for Transcripted. 23 Swift files across Commands/, Generators/, Validators/, Utilities/, Models/, and root.

## File Index

### Root (1 file)

| File | Purpose |
|------|---------|
| `TranscriptedQA.swift` | CLI entry point (`@main`), registers all subcommands via ArgumentParser |

### Commands/ (10 files)

| File | Purpose |
|------|---------|
| `CheckHealth.swift` | Quick health check: DB integrity, model presence, disk space |
| `ValidateAll.swift` | Run all validators: transcripts, DB, index, logs, artifacts |
| `ValidateArtifacts.swift` | Check transcript sidecars (.json), YAML frontmatter, speaker clips |
| `ValidateDatabase.swift` | SpeakerDB and StatsDB integrity, schema validation, corruption check |
| `ValidateIndex.swift` | Transcript index consistency, missing sidecars, orphan files |
| `ValidateLogs.swift` | Log file analysis, error patterns, warning frequency |
| `ValidateTranscripts.swift` | Transcript content validation, speaker attribution, timestamp checks |
| `GenerateFixtures.swift` | Generate valid test data (transcripts, sidecars, DB records) that passes all validators; outputs to configurable directory (default: `/tmp/transcripted-test-data`) |
| `RoundTrip.swift` | Generate test data, validate, corrupt, re-validate — verifies validators catch real defects |
| `StressTest.swift` | Generate large datasets (configurable transcript/speaker/utterance counts) and validate performance + correctness |

### Generators/ (1 file)

| File | Purpose |
|------|---------|
| `TestDataGenerator.swift` | Shared fixture builder used by GenerateFixtures, RoundTrip, and StressTest commands |

### Validators/ (7 files)

| File | Purpose |
|------|---------|
| `HealthChecker.swift` | System health: disk space, model files, DB existence |
| `IndexValidator.swift` | Index consistency, transcript/sidecar pairing |
| `JSONSidecarValidator.swift` | YAML frontmatter, agent JSON structure |
| `LogValidator.swift` | Log file parsing, error pattern detection |
| `SpeakerDBValidator.swift` | SpeakerDB schema, record count, embedding integrity |
| `StatsDBValidator.swift` | StatsDB schema, recording history, daily activity |
| `TranscriptValidator.swift` | Transcript content, speaker attribution, timestamp validity |

### Utilities/ (2 files)

| File | Purpose |
|------|---------|
| `SQLiteReader.swift` | SQLite file reading, query execution, result parsing |
| `YAMLParser.swift` | YAML frontmatter parsing, metadata extraction |

### Models/ (1 file)

| File | Purpose |
|------|---------|
| `ValidationResult.swift` | Validation outcome: success/failure, error details, metrics |

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

# Test data generation
transcripted-qa generate-fixtures --output /tmp/my-test-data
transcripted-qa round-trip
transcripted-qa stress-test --transcripts 100 --speakers-per-transcript 4 --utterances-per-transcript 200
```

## Validation Results

`ValidationResult` struct contains:
- `success: Bool` - Overall validation status
- `errors: [String]` - List of errors found
- `warnings: [String]` - Non-critical warnings
- `metrics: [String: Any]` - Validation metrics (record counts, file sizes, etc.)

## Key Features

- **Health checks**: Quick system status before deep validation
- **Database integrity**: SpeakerDB and StatsDB corruption detection with backup/recreate pattern
- **Transcript validation**: Content, speaker attribution, timestamp consistency
- **Index validation**: Transcript/sidecar pairing, orphan file detection
- **Log analysis**: Error pattern detection, warning frequency tracking
- **Artifact validation**: YAML frontmatter, JSON sidecars, speaker clips
- **Fixture generation**: `generate-fixtures` creates valid test data for use in CI or manual testing
- **Round-trip testing**: `round-trip` validates that validators correctly catch injected corruption
- **Stress testing**: `stress-test` generates large datasets to surface performance and correctness issues

## Gotchas

- All validators run synchronously on background threads
- SQLite readers use dedicated utility queues for thread safety
- Validation results are structured for programmatic consumption
- Error messages are human-readable for CLI output
