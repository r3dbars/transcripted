# TranscriptedQA - QA Testing CLI Tool

`Tools/TranscriptedQA/` is a compact standalone Swift package for validating
Transcripted artifacts on disk.

The current package is intentionally small:

- `Package.swift` — Swift package manifest for the CLI
- `Sources/TranscriptedQA/TranscriptedQA.swift` — `@main` entry point, shared
  path resolution, subcommand registration, validators, fixture generation, and
  report formatting
- `Tests/TranscriptedQATests/ValidatorTests.swift` — targeted coverage for the
  lightweight validators and report exit behavior

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

# Override nonstandard locations when captures are relocated
swift run transcripted-qa validate-all --path /path/to/meetings --state-dir /path/to/state --log-path /path/to/app.jsonl

# Test data generation
swift run transcripted-qa generate-fixtures --output /tmp/my-test-data
swift run transcripted-qa round-trip
swift run transcripted-qa stress-test --transcripts 100 --speakers-per-transcript 4 --utterances-per-transcript 200
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

- The current implementation is consolidated into one source file, so keep the
  subcommand list in `TranscriptedQA.configuration` in sync with the validator
  types defined below it.
- All validators run synchronously on background threads
- SQLite readers use dedicated utility queues for thread safety
- Validation results are structured for programmatic consumption
- Error messages are human-readable for CLI output
- Defaults now prefer `~/Library/Application Support/Transcripted/captures/meetings`, `~/Library/Application Support/Transcripted/state/`, and `~/Library/Application Support/Transcripted/logs/app.jsonl`
- If current Transcripted paths are missing, the resolver falls back to legacy Draft exports and then `~/Documents/Transcripted/`
- `--path` overrides the meetings capture directory only; use `--state-dir` and `--log-path` when validating unusual layouts
