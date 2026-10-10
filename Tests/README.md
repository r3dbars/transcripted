# Tests Guide

## Test rules (read before writing a test)

A test checks a **promise** through the front door: give the code inputs and
check what it returns or does. It never reads the app's code as text. These
rules exist because tests that pin code shape go red on harmless renames, stay
green when behavior breaks, and cost agents a CI run each time.

1. **Name the promise.** The `runSuite` name (or test name) says what must stay
   true, in plain words: "The stop click plays after the mic stops."
2. **Inputs in, outputs out.** Call the real function or type with plain values
   or fakes, then assert on the result, the saved file, or the order of
   recorded events.
3. **No source-text tests.** Don't read `Sources/**` as a string and assert on
   fragments. If the logic is stuck inside a big file, pull the decision into a
   small function (a "policy") and test that. `scripts/dev/check-test-shape.py`
   blocks new ones. The grandfathered files are listed in
   `.agents/test-shape-baseline.json`, and that list can only shrink: after
   converting one, run `python3 scripts/dev/check-test-shape.py --shrink`.
4. **No wall-clock limits.** Don't assert that real elapsed time stayed under a
   number. Assert the outcome instead (it timed out, it didn't wait for the
   slow part), give slow fakes a wide margin, or inject a clock. The same guard
   blocks new ones. Example clock seam:
   `Sources/TranscriptedCore/Pipeline/OrphanedRecordingRecoveryClock.swift`
   (now / date / sleep) with a virtual clock in its tests; assert on the
   virtual time that passed, never on real elapsed time.
5. **Write it from the promise, not from the code.** Write the test before the
   fix, or from a one-line spec. A test written by reading the implementation
   tends to copy its bugs. For bigger features, have a second agent write the
   tests from the spec (`.claude/agents/test-writer.md`).
6. **Prove it can fail.** Before committing, break the code on purpose (flip
   the condition, drop the call) and watch the test go red.
   `scripts/dev/mutation-probe.py` does this for a whole file and lists the
   breaks no test catches (see `docs/mutation-testing.md`).
7. **Synthetic is not real.** A fake-mic test never proves real microphone,
   Bluetooth, system audio, or paste-back behavior. Say which real check is
   still needed.

Where each kind of test goes, fastest first:

| Layer | Use it for | Where |
| --- | --- | --- |
| Compiler | Making bad states impossible to write | Types and enums in `Sources/` |
| Decision tests | Policies, parsers, formatting, ordering | `Tests/*Tests.swift`, `Tests/TranscriptedCoreTests/` |
| Output tests | Saved Markdown and other artifacts | `MeetingMarkdownGoldenTests` (approved copies in `Tests/Fixtures/golden-meetings/`), `bash run-e2e-smoke.sh` |
| Consistency checks | Files that must agree with each other | `scripts/dev/check-*.py`, `scripts/dev/linux-checks.sh` |
| Real world | Mic, AirPods, system audio, paste-back | `bash check.sh hardware`, `bash run-daily-audio-reliability.sh` |

### Flaky tests

A test that fails without a code change is a flake, and a flake teaches
everyone to ignore red. The same day, either fix it or bench it: add
`YYYY-MM-DD | <runSuite name> | <why, and who fixes it>` to
`Tests/quarantine.txt`. `run-tests.sh` skips benched suites and lists them in
its summary, and the test-shape guard warns once an entry is two weeks old. For
Swift Testing use `.disabled("why")`, for XCTest `XCTSkip("why")`, under the
same same-day rule. Never add retries until it passes.

To reproduce a flake that only shows up on a busy Mac: start about 64
`yes > /dev/null` loops and a from-scratch
`swift build --build-tests --build-path <scratch dir>` in parallel, then run
the one test on its own over and over with
`swift test --skip-build --filter <Suite>/<test>`. Run it alone, not in the
suite: earlier tests warm the process, which hides cold-start timing bugs. If
you add a watchdog `(sleep N; kill ...) &`, send its output to `/dev/null`, or
`| tail` waits for it.

Give every run its own log file. Two `run-tests.sh` runs sent to one file with
`>` overwrite each other's lines, which looks like a second summary with a
failure count and no FAIL lines. That's a shared log, not a flake. Each
summary repeats its FAIL lines, with the suite they came from, so check the
`Failures:` list under the count before chasing one.

### One command

```bash
bash check.sh            # the checks your diff needs (from .agents/test-matrix.yml)
bash check.sh quick      # Linux-safe repo checks and the test-shape guard, no Swift build
bash check.sh full       # what Swift CI runs on a PR
bash check.sh hardware   # real mic, system audio and paste-back smokes on this Mac
```

## Test Surfaces

This repo has eleven distinct verification layers:

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
9. `bash scripts/ops/transcripted-qa-bench.sh --mode sparkle-update`
   No-publish fake-state Sparkle update UI smoke for update-available and downloading menu surfaces
10. `bash scripts/ops/transcripted-qa-bench.sh --mode packaged`
   No-publish `build-beta.sh` package smoke plus built app version, Sparkle, signing, dSYM, DMG, optional menu bar, and local log privacy checks
11. `bash scripts/ops/transcripted-qa-bench.sh --mode full`
   Deep QA plus release-health fixture proof

There is also an orchestrated QA bench for human-style passes:

```bash
bash scripts/ops/transcripted-qa-bench.sh --mode quick
bash scripts/ops/transcripted-qa-bench.sh --mode deep
bash scripts/ops/transcripted-qa-bench.sh --mode full
bash scripts/ops/transcripted-qa-bench.sh --mode ui
bash scripts/ops/transcripted-qa-bench.sh --mode sparkle-update
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

`run-tests.sh` discovers root `Tests/*Tests.swift` files, derives each entry
function from its filename, compiles them into `build/tests`, and generates a
temporary runner at build time.

Important implications:

- `Tests/FooTests.swift` must expose exactly one top-level `testFoo()` entry
- the hand-kept lists are `FAST_TEST_SOURCES` and `APP_SOURCES` in `scripts/entrypoints/run-tests.sh` (the root `run-tests.sh` is a wrapper) plus `scripts/entrypoints/lib/shared-smoke-sources.sh`; moving or adding a source file a test compiles means updating them
- missing or duplicated convention entry functions fail before compilation

The current compiled fast test set is the sorted root `Tests/*Tests.swift` set.

To run a single suite instead of the whole set, pass `--filter`:

```bash
bash run-tests.sh --filter <entryFn|File>
```

The selector matches an entry function (`testObservabilityLogWriter`), a file name
(`ObservabilityLogWriterTests.swift` or `ObservabilityLogWriterTests`), or a case-insensitive
substring of either. `--only` is an alias. To see the known entry functions:

```bash
bash run-tests.sh --list
```

The runner also fails fast on a missing/duplicated convention entry function
and on a stale `APP_SOURCES` path, instead of surfacing raw swiftc errors.

To measure fast-test coverage, run:

```bash
bash run-tests.sh --coverage
```

This uses the same convention-driven runner with LLVM coverage instrumentation
and writes `summary.txt`, `coverage.profdata`, raw `.profraw`, and
`report.lcov` under `build/coverage/fast-tests/`.

## Running one test

`bash run-tests.sh --filter <entryFn|File>` runs one fast-test file; the
selector matches an entry function, a file name, or a case-insensitive
substring of either. Compiled app sources are cached under
`build/fast-tests-cache/` (keyed by the source list, file contents, compiler
and flags), so later filtered runs skip that work;
`TRANSCRIPTED_FAST_TESTS_NO_CACHE=1` forces a clean compile.

`Tests/TranscriptedCoreTests/` is split into five package test targets:
`AudioTests`, `SpeakerTests`, `PipelineTests`, `StorageTests`, `UtilitiesTests`.
Scope a loop with `swift test --filter '^SpeakerTests\.'`, or one class with
`swift test --filter <ClassName>`. Plain `swift test` runs them all, which is
what CI does.

Diarization split tests live in `SpeakerTests` (not the root fast-test tree):
`EmbeddingClustererSplitTests`, `SpeakerTurnWindowSplitterTests`,
`NemotronTurnBuilderTests`. Class-name filters only see them after that
target links:

```bash
swift test --filter '^SpeakerTests\.EmbeddingClustererSplitTests'
swift test --filter '^SpeakerTests\.SpeakerTurnWindowSplitterTests'
swift test --filter '^SpeakerTests\.NemotronTurnBuilderTests'
```

`Executed 0 tests` on those filters almost always means `SpeakerTests` failed
to compile — the other four Core bundles then have nothing matching. Do not
use `bash run-tests.sh --filter …` for these; that runner only sees
`Tests/*Tests.swift`.

## Core Package Tests

`swift test` currently exercises the standalone package seam under
`Tests/TranscriptedCoreTests/`, including storage paths, audio startup,
meeting-input selection, file logging, failed-transcription persistence,
recording archiving, stats, speaker reconciliation, transcript frontmatter, and
transcript metadata.

`Tests/TranscriptedWritingTests/` holds Writing's ported Tilde tests (Swift
Testing, not XCTest) for `Sources/TranscriptedWriting/` and
`Sources/TranscriptedKeyboard/`; run just those with
`swift test --filter '^TranscriptedWritingTests\.'`.

Use this when changing:

- `Package.swift`
- `Sources/TranscriptedCore/`
- `Sources/TranscriptedWriting/` or `Sources/TranscriptedKeyboard/`
- public core seams used by embedders

## Integration Smoke

Parakeet model-lifecycle changes also have a deterministic executor harness:
`bash scripts/dev/test-parakeet-lifecycle.sh`. It compiles the production
lifecycle extension against delayed fake models (no network, cache writes, or
microphone). See `Tests/Integration/ParakeetLifecycle/README.md` for coverage and
the explicit boundary between this executor test and full engine/live proof.

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
for Core Audio process taps. The smoke starts production `Audio`, waits for
meeting capture readiness, plays a short system tone from a separate process,
records briefly, stops, and verifies real mic and system-audio scratch WAVs were
written with sensible durations and nonzero finite system-audio signal from
the external tone. File size alone does not prove permission or audible audio.

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

## Sparkle Update UI Smoke

`bash scripts/ops/transcripted-qa-bench.sh --mode sparkle-update` builds the
app, then runs `transcripted-qa sparkle-update-smoke` against
`build/Transcripted.app`. It launches the app through the launch-smoke harness
with fake update-available and downloading states, then validates the menu
snapshot copy and visibility for the prominent install callout and disabled
download-progress row.

This is no-publish local UI proof only. It does not contact the live appcast,
download or verify an update, install, relaunch, notarize, publish, update
Homebrew, or prove an existing installed app can upgrade.

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
