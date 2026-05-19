# Tests Guide

## Test Surfaces

This repo has six distinct verification layers:

1. `bash run-tests.sh`
   Curated fast test runner built with raw `swiftc`
2. `bash run-integration-smoke.sh`
   App-to-core linkage smoke test
3. `bash run-e2e-smoke.sh`
   Deterministic release-critical artifact smoke without microphone/TCC
4. `swift test`
   Swift Package tests for the standalone `TranscriptedCore` package surface
5. `bash build.sh`
   Authoritative app build for the menubar target
6. `bash run-live-capture-smoke.sh`
   Local hardware/TCC smoke for app launch plus production mic + system-audio capture

There is also an orchestrated QA bench for human-style passes:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode quick
bash scripts/ops/transcripted-qa-bench.sh --mode deep
bash scripts/ops/transcripted-qa-bench.sh --mode corpus
bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare
bash scripts/ops/transcripted-qa-bench.sh --mode live
```

It wraps the layers above, `Tools/TranscriptedQA`, synthetic audio reliability,
the optional local meeting corpus, and redacted corpus comparison into one local report. See
`docs/qa-test-bench.md`.

## Fast Test Runner

`run-tests.sh` compiles the root fast tests listed in
`Tests/FastTests.manifest` into `build/tests` and generates a temporary runner
at build time.

Important implications:

- adding a root `Tests/*Tests.swift` file is not enough by itself
- new fast tests must be registered in:
  - `Tests/FastTests.manifest`
- moving a source file compiled by `run-tests.sh` also requires updating the script
- `run-tests.sh` now fails if the manifest and the actual root test files drift

The current compiled fast test set lives in `Tests/FastTests.manifest`.

To measure fast-test coverage, run:

```bash
bash run-tests.sh --coverage
```

This uses the same manifest-driven runner with LLVM coverage instrumentation
and writes `summary.txt`, `coverage.profdata`, raw `.profraw`, and
`report.lcov` under `build/coverage/fast-tests/`.

## Core Package Tests

`swift test` currently exercises the standalone package seam under
`Tests/TranscriptedCoreTests/`, including storage paths, audio startup,
meeting-input selection, file logging, failed-transcription persistence,
recording archiving, stats, speaker reconciliation, transcript frontmatter, and
transcript metadata.

Use this when changing:

- `Package.swift`
- `Sources/TranscriptedCore/`
- public core seams used by embedders

## Integration Smoke

`bash run-integration-smoke.sh` verifies that the app-side dependency bundle
still exposes the `TranscriptedCore` types that `Sources/Meeting/` depends on.
It also runs the wake-recovery smoke binary and currently finishes with
`swift test --filter MicRecordingFileMergerTests`.

The smoke sources now live under `Tests/Integration/` so the repo’s verification
surface stays under one top-level `Tests/` umbrella.

Fast tests and smoke runs set `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` so they do
not append test-only entries into the real `~/Library/Application Support/Transcripted/logs/app.jsonl`.

Run it whenever you touch:

- `Sources/Meeting/`
- `Sources/TranscriptedCore/`
- dependency wiring in `build-deps.sh`

## Deterministic E2E Smoke

`bash run-e2e-smoke.sh` compiles `Tests/E2E/TranscriptedE2ESmoke.swift`
with the small app source set needed to prove the release-critical local
artifact contract. It does not use the microphone, ScreenCaptureKit, Calendar,
Accessibility, Sparkle, or a real app launch.

It currently verifies:

- saved dictation Markdown can be written, counted, and read back
- meeting Markdown can be previewed and parsed for Home/agent use
- retained meeting audio can be resolved from the saved transcript
- the MCP directories manifest names the capture, meeting, and dictation roots
- support diagnostics redact titles, paths, emails, raw URLs, and device names

## Live Capture Smoke

`bash run-live-capture-smoke.sh` first runs `bash build.sh --no-open`, which
includes the signed app launch smoke and an env-gated menu-bar JSON snapshot
that checks the status item plus visible, enabled Start Dictation and Start
Meeting rows. It then runs
`LiveCaptureSmokeTests` with `TRANSCRIPTED_LIVE_CAPTURE_SMOKE=1`.

This is a local release gate, not a default CI test. It requires a microphone,
microphone permission for the test runner, and System Audio Recording permission
for ScreenCaptureKit audio. The smoke starts production `Audio`, waits for
meeting capture readiness, plays a short system tone from a separate process,
records briefly, stops, and verifies real mic and system-audio scratch WAVs were
written.

For a faster rerun after a fresh build:

```bash
bash run-live-capture-smoke.sh --skip-build
```
