# TranscriptedQA - QA Testing CLI Tool

QA testing suite for Transcripted. 12 Swift files across Commands/, Validators/, Utilities/, and Models/.

## File Index

### Commands/ (7 files)

| File | Purpose |
|------|---------|
| `CheckHealth.swift` | Quick health check: DB integrity, model presence, disk space |
| `ValidateAll.swift` | Run all validators: transcripts, DB, index, logs, artifacts |
| `ValidateArtifacts.swift` | Check transcript sidecars (.json), YAML frontmatter, speaker clips |
| `ValidateDatabase.swift` | SpeakerDB and StatsDB integrity, schema validation, corruption check |
| `ValidateIndex.swift` | Transcript index consistency, missing sidecars, orphan files |
| `ValidateLogs.swift` | Log file analysis, error patterns, warning frequency |
| `ValidateTranscripts.swift` | Transcript content validation, speaker attribution, timestamp checks |

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

## Gotchas

- All validators run synchronously on background threads
- SQLite readers use dedicated utility queues for thread safety
- Validation results are structured for programmatic consumption
- Error messages are human-readable for CLI output
