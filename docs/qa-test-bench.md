# Transcripted QA Test Bench

Use this when you want a QA-tester pass on Transcripted instead of one narrow
unit-test run.

The bench is an orchestrator. It calls the repo's existing checks, captures
logs, and writes one local report under:

```text
/tmp/transcripted-qa-bench/<run-id>/qa-report.md
```

## Quick Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode quick
```

This runs:

- `bash scripts/dev/agent-preflight.sh`
- `bash build.sh --no-open`
- `bash run-tests.sh`
- `bash run-e2e-smoke.sh`

It proves the app builds, fast tests pass, and deterministic meeting/dictation
artifact discovery still works without microphone or TCC prompts.

## Deep Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode deep
```

This adds:

- `bash run-integration-smoke.sh`
- `swift test`
- `swift test --package-path Tools/TranscriptedQA`
- `swift run --package-path Tools/TranscriptedQA transcripted-qa round-trip`
- a small `TranscriptedQA` stress pass
- `TranscriptedQA` health and live artifact validation
- `bash run-daily-audio-reliability.sh --synthetic`

Live artifact validation is non-blocking by default because a development Mac
may not have saved meetings yet. To make it strict:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode deep --strict-artifacts
```

## Live Run

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode live
```

This adds the real mic + system-audio capture smoke:

```bash
bash run-live-capture-smoke.sh --skip-build
```

It requires local microphone permission and System Audio Recording permission.
If macOS blocks it, report that as `INCOMPLETE` or `FAIL` with the permission
reason. Do not treat a TCC blocker as product proof.

## Manual QA

Every run writes:

```text
/tmp/transcripted-qa-bench/<run-id>/manual-scenarios.md
```

Use it for the lanes that need a human:

- actual meeting-app volume behavior
- sleep/wake
- Bluetooth and device switching
- TextEdit, Notes, browser text area dictation
- speaker review and manual rename feel
- "does this UI feel stuck?" recovery checks

For the meeting-volume matrix, use:

```text
docs/qa-issue-500-meeting-audio.md
```

For the daily audio state-machine loop, use:

```text
docs/audio-reliability-daily-check.md
```

## Pass Bar

A strong QA pass should answer:

- Do meetings start, stop, transcribe, and save?
- Do dictations paste or copy and then save readable Markdown?
- Do speaker labels stay understandable, with `You` for the local mic by default?
- Do manual speaker names survive into Markdown?
- Do failed meetings explain stage, retryability, retained artifacts, and user-visible state?
- Do support diagnostics and analytics stay privacy-safe?
- Did every failing check leave a local evidence path?

## Privacy

Keep raw logs local. Do not upload:

- transcript text
- audio files
- meeting titles
- speaker names
- emails
- tokens
- absolute paths
- raw private URLs
- device names
