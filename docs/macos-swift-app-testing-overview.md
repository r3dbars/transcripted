# How I Test This macOS Swift App

This is the simple version of the testing setup for Transcripted, a macOS Swift app for dictation, meeting capture, local transcription, and saved Markdown output.

The basic idea is:

1. Prove the app builds.
2. Prove the core logic works.
3. Prove saved files and artifacts work.
4. Run deeper smoke tests for meeting/audio flows.
5. Use real manual QA for the macOS parts that automation cannot fully prove.

## The Normal Baseline

For most Swift app changes, I run:

```bash
bash build.sh --no-open
bash run-tests.sh
```

`build.sh --no-open` is the main app build check. It proves the menubar app still compiles.

`run-tests.sh` is the fast app test suite. It is a custom Swift test runner, not standard XCTest. The tests cover app behavior like dictation policy, meeting policy, settings, storage paths, hotkeys, observability, privacy redaction, diagnostics, speaker naming, and UI presentation rules.

The repo currently has a broad test surface: over 100 fast-test manifest entries and more than 100 Swift test files under `Tests/`.

## Integration Checks

If the change touches meeting capture or the shared transcription core, I run the stricter stack:

```bash
bash build-deps.sh --force
bash build.sh --no-open
bash run-tests.sh
bash run-integration-smoke.sh
```

`build-deps.sh --force` rebuilds the local dependency bundle used by the app.

`run-integration-smoke.sh` checks that the app-side meeting code still links correctly against `TranscriptedCore`, and that important integration seams still work.

## Core Package Tests

If I change `Package.swift`, `Sources/TranscriptedCore/`, or a public core API, I also run:

```bash
swift test
```

That covers the standalone Swift package side of the app. It checks things like storage paths, audio startup, meeting input selection, logging, failed-transcription persistence, recording archiving, speaker reconciliation, transcript frontmatter, and transcript metadata.

## Deterministic End-to-End Smoke

There is also a deterministic E2E smoke test:

```bash
bash run-e2e-smoke.sh
```

This proves the saved-output contract without needing real microphone access or macOS permission prompts.

It checks that:

- saved dictation Markdown can be written and read back
- meeting Markdown can be parsed for Home and agent use
- retained meeting audio can be resolved from the saved transcript
- the MCP directories manifest names the right capture folders
- support diagnostics redact private data like titles, paths, emails, raw URLs, and device names

This is useful because it tests the release-critical artifact flow without depending on hardware.

## Full QA Bench

When I want a real QA-style pass instead of one narrow test run, I use the QA bench:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode quick
bash scripts/ops/transcripted-qa-bench.sh --mode deep
bash scripts/ops/transcripted-qa-bench.sh --mode live
```

`quick` runs:

- preflight
- app build
- fast tests
- deterministic E2E smoke

`deep` adds:

- integration smoke
- `swift test`
- TranscriptedQA package tests
- TranscriptedQA round-trip validation
- artifact validation
- stress checks
- synthetic audio reliability checks

`live` adds:

- real app launch smoke
- real microphone capture
- real system-audio capture

The live mode needs macOS microphone permission and System Audio Recording permission. If macOS blocks those permissions, that is not a product pass. I mark it as incomplete and explain the permission blocker.

## Artifact And Data Validation

Transcripted has a separate QA CLI called `TranscriptedQA`.

It can validate:

- meeting Markdown
- YAML frontmatter
- speaker metadata
- retained audio references
- local databases
- logs
- legacy indexes
- saved artifact consistency

Useful command:

```bash
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa validate-all --format json
```

This is especially useful after running the app locally, because it checks the actual saved Transcripted library.

## Manual QA

Some macOS behavior still needs a human. Automated tests can prove a lot, but they cannot fully prove every real app, hardware, and permission path.

Manual QA covers:

- real Zoom, Meet, and Teams behavior
- Safari and Firefox meeting routes
- Bluetooth and AirPods switching
- sleep and wake recovery
- dictation pasteback into TextEdit, Notes, browser text areas, and Obsidian
- microphone permission prompts
- Accessibility permission behavior
- speaker review and manual rename feel
- whether the app feels stuck or recoverable

For meeting audio, the rule is simple: synthetic or browser-only evidence is not enough. Real meeting-app and hardware-route proof matters.

## How I Think About Confidence

I treat testing in three tiers:

1. Automated green: build, unit-style tests, smoke tests, package tests.
2. Deterministic E2E green: saved dictation and meeting artifacts work without real hardware.
3. Manual/live green: real macOS permissions, real apps, real microphone/system-audio routes, and real user flows work.

If tier 1 and 2 pass but tier 3 has not been run, I call the build promising, not fully proven.

For a release-quality pass, I want:

- app builds cleanly
- fast tests pass
- integration smoke passes when relevant
- `swift test` passes when core/package code changed
- E2E smoke passes
- QA bench is green or has clearly explained non-blocking warnings
- live capture works on the target machine
- manual QA proves the risky macOS flows

That is the real testing story: strong automated coverage, plus honest manual QA for the parts macOS makes hard to fake.
