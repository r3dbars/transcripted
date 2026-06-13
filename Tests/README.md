# Tests Guide

## Test Surfaces

This repo has ten distinct verification layers:

1. `bash run-tests.sh`
   Curated fast test runner built with raw `swiftc`
2. `bash run-integration-smoke.sh`
   App-to-core linkage smoke test
3. `bash run-e2e-smoke.sh`
   Deterministic release-critical artifact smoke without microphone/TCC
4. `bash run-slow-pasteback-smoke.sh`
   Deterministic fake slow Cmd+V target for pasteback and clipboard restore
5. `swift test`
   Swift Package tests for the standalone `TranscriptedCore` package surface
6. `bash build.sh --no-open`
   Authoritative app build for the menubar target
7. `bash run-live-capture-smoke.sh`
   Local hardware/TCC smoke for app launch plus production mic + system-audio capture
8. `bash scripts/ops/transcripted-qa-bench.sh --mode ui`
   Accessibility-driven UI smoke for first-run onboarding, menu bar, Home, Settings, buttons, and basic navigation
9. `bash scripts/ops/transcripted-qa-bench.sh --mode packaged`
   No-publish `build-beta.sh` package smoke plus built app version, Sparkle, signing, dSYM, DMG, optional menu bar, and local log privacy checks
10. `bash scripts/ops/transcripted-qa-bench.sh --mode full`
   Deep QA plus release-health fixture proof and local Gemma summary planning when eligible transcripts exist

There is also an orchestrated QA bench for human-style passes:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode quick
bash scripts/ops/transcripted-qa-bench.sh --mode deep
bash scripts/ops/transcripted-qa-bench.sh --mode full
bash scripts/ops/transcripted-qa-bench.sh --mode ui
bash scripts/ops/transcripted-qa-bench.sh --mode packaged
bash scripts/ops/transcripted-qa-bench.sh --mode pasteback-synthetic
bash scripts/ops/transcripted-qa-bench.sh --mode corpus
bash scripts/ops/transcripted-qa-bench.sh --mode corpus-compare
bash scripts/ops/transcripted-qa-bench.sh --mode live
```

It wraps the layers above, `Tools/TranscriptedQA`, synthetic audio reliability,
the optional local meeting corpus, and redacted corpus comparison into one local report. See
`docs/qa-test-bench.md`.

These are layered proof tools, not every-PR requirements. Tiny docs-only PRs
stay on preflight and mapped docs checks unless they change release truth, QA
gates, appcast/update flow, Homebrew, or public download truth.

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

To run a single suite instead of the whole set, pass `--filter`:

```bash
bash run-tests.sh --filter <entryFn|File>
```

The selector matches an entry function (`testJSONLWriter`), a file name
(`JSONLWriterTests.swift` or `JSONLWriterTests`), or a case-insensitive
substring of either. `--only` is an alias. To see the known entry functions:

```bash
bash run-tests.sh --list
```

The runner also fails fast on a manifest entry-function typo and on a stale
`APP_SOURCES` path, instead of surfacing those as raw swiftc errors.

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

## Slow Pasteback Smoke

`bash run-slow-pasteback-smoke.sh` compiles
`Tests/E2E/SlowPastebackSmoke.swift` with the production
`ClipboardRestoringTextPaster` and timing constants. It uses named synthetic
pasteboards, not the real clipboard, and does not require dictation audio,
Accessibility, ScreenCaptureKit, or app launch.

It verifies:

- a fake Cmd+V target that reads at `950ms` still inserts fresh dictation
- a fake target near the `2.5s` fallback boundary still inserts fresh dictation
- a retry before fallback restore lets both fake Cmd+V targets insert fresh dictation, then restores the original clipboard
- an old `900ms` fallback control is detected as stale instead of hidden
- a reader beyond the current fallback is detected as stale
- paste-dispatch failure leaves fresh dictation copied
- clipboard restore does not overwrite a user copy made after pasteback
- a retry paste while restore is pending restores the user's original clipboard
- cancellation clears pending restore work without a delayed stale restore

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

## UI Automation Smoke

`bash scripts/ops/transcripted-qa-bench.sh --mode ui` runs
`transcripted-qa ui-smoke` against `build/Transcripted.app`. It checks a
throwaway first-run onboarding launch, then the normal menu bar, Home, Settings,
and General navigation path. It needs
Accessibility permission for the terminal or Codex runner so it can inspect AX
identifiers and press controls. Missing permission exits `3` and is reported as
`INCOMPLETE`, not green.

## Packaged App Smoke

`bash scripts/ops/transcripted-qa-bench.sh --mode packaged` runs a no-publish
package smoke with `SKIP_NOTARIZATION=1`, then runs:

```bash
swift run --package-path Tools/TranscriptedQA transcripted-qa packaged-app-smoke --app build/Transcripted.app --dsym build/Transcripted.app.dSYM --run-ui-smoke
```

It validates the built app version/config against source `Info.plist`, Sparkle
feed URL/public key/update flags, HTTPS observability endpoints, code signing,
the bundled Sparkle framework and MCP helper, matching app/dSYM UUIDs, the
versioned DMG, optional menu bar UI, and local log privacy patterns. UI/TCC
blockers exit `3` as `INCOMPLETE`, not green proof. Notarization and publishing
remain manual release steps.

## Codex UI Permission-State Smoke

Before counting Codex computer-use screenshots or click flows as proof, run:

```bash
TRANSCRIPTED_DISABLE_FILE_LOGGER=1 swift run --package-path Tools/TranscriptedQA transcripted-qa permission-state --mode computer-use
```

For live capture lanes, use `--mode live-capture`. A warning means
`INCOMPLETE: harness permission blocked`, not a green UI result and not
necessarily a Transcripted product failure.
