# TranscriptedQA

Standalone QA CLI for validating Transcripted artifact sets on disk.

## Current scope

This tool is strongest for validating meeting-artifact directories, indexes,
logs, and related databases. It is not the authoritative app test runner.

## Important layout

- `TranscriptedQA.swift` — `@main` command root, shared path helpers, and subcommand registration
- `Commands/` — user-facing commands such as `validate-all`, `validate-database`, `validate-index`, `check-health`, `round-trip`, and `stress-test`
- `Validators/` — database, transcript, artifact, index, log, and health validators
- `Generators/` — shared fixture generation
- `Utilities/` — SQLite and YAML helpers
- `Models/ValidationResult.swift` — structured validation output

## Default paths

This tool still defaults to the legacy Draft meetings tree unless you pass a
custom path:

- meetings root: `~/Library/Application Support/Draft/meetings/`
- transcripts under that root: `transcripts/`
- log target checked by validators: `~/Library/Logs/Transcripted/app.jsonl`

That makes it useful for legacy artifact sets or targeted validation runs, but
it is not yet aligned with the app’s new default capture-library layout unless
you provide `--path`.

## Commands

- `transcripted-qa validate-all`
- `transcripted-qa validate-transcripts`
- `transcripted-qa validate-database`
- `transcripted-qa validate-logs`
- `transcripted-qa validate-artifacts`
- `transcripted-qa validate-index`
- `transcripted-qa check-health`
- `transcripted-qa generate-fixtures`
- `transcripted-qa round-trip`
- `transcripted-qa stress-test`

## Usage

```bash
cd Tools/TranscriptedQA
swift build
swift run transcripted-qa validate-all
swift run transcripted-qa validate-all --path /path/to/meetings-root
```

## Notes

- validators run synchronously and are designed for CLI output plus structured machine-readable reports
- `--path` points at the meetings root, not the transcript file itself
- this tool complements `bash build.sh`, `bash run-tests.sh`, and `bash run-integration-smoke.sh`; it does not replace them
