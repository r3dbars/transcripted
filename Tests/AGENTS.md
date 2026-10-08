# Tests

App tests, smokes, and fixtures. Full guide with every smoke's details: `Tests/README.md`. Which checks a diff needs: `.agents/test-matrix.yml` (run `bash check.sh`).

## Layout

- `Tests/*Tests.swift` — fast tests, run by `bash run-tests.sh` (raw `swiftc`, `runSuite` style). Discovered by filename, not a manifest.
- `Tests/TranscriptedCoreTests/` — package tests for `Sources/TranscriptedCore/` (`swift test`). Five targets: `AudioTests`, `SpeakerTests`, `PipelineTests`, `StorageTests`, `UtilitiesTests`.
- `Tests/TranscriptedWritingTests/` — Swift Testing (not XCTest) for `Sources/TranscriptedWriting/` and `Sources/TranscriptedKeyboard/`.
- `Tests/Integration/`, `Tests/E2E/` — smoke sources run by `run-integration-smoke.sh`, `run-e2e-smoke.sh`, `run-slow-pasteback-smoke.sh`.
- `Tests/BuildDependencies/` — shell and Python tests for build, packaging, and Sparkle scripts.
- `Tests/Fixtures/` — golden meetings, corpora, release-health JSON. Treat as approved output: change one only when the behavior change is intended.
- `Tests/quarantine.txt` — benched flaky suites.

## Rules

- **A test checks a named promise through inputs and outputs.** The `runSuite` name says what must stay true. Write it from the promise or spec, not from the implementation.
- **No source-text tests and no wall-clock limits.** Don't read `Sources/**` as a string and assert on fragments; don't assert real elapsed time. Pull the decision into a small policy function, or inject a clock. `scripts/dev/check-test-shape.py` blocks new ones. Grandfathered files are in `.agents/test-shape-baseline.json`, which only shrinks (`--shrink` after converting one).
- **Source pins break silently on Linux.** Editing a file a test reads as text can fail a test only a Mac sees. `python3 scripts/dev/check-source-pins.py` finds those without Swift.
- **Prove the test can fail.** Break the code on purpose and watch it go red. `scripts/dev/mutation-probe.py` does it per file (`docs/mutation-testing.md`).
- **Synthetic is not real.** Fake mic, fake Cmd+V, and fake route tests never prove real microphone, Bluetooth, system audio, or pasteback. Name the manual check still owed.
- **Tests never touch real user data.** Fast tests and smokes set `TRANSCRIPTED_DISABLE_FILE_LOGGER=1` so they don't write to the real `~/Library/Application Support/Transcripted/logs/app.jsonl`. Use temp dirs and named synthetic pasteboards, never the real clipboard.

## Fast-test runner gotchas

- `Tests/FooTests.swift` must expose exactly one top-level `testFoo()`. A missing or duplicated entry fails before compiling.
- Hand-kept source lists: `FAST_TEST_SOURCES` and `APP_SOURCES` in `scripts/entrypoints/run-tests.sh` (root `run-tests.sh` is a wrapper) and `scripts/entrypoints/lib/shared-smoke-sources.sh`. Moving or adding a source file a test compiles means updating them. `python3 scripts/dev/check-build-source-lists.py` checks them.
- One suite: `bash run-tests.sh --filter <entryFn|File>` (`--list` shows entries). Compiled sources are cached in `build/fast-tests-cache/`; `TRANSCRIPTED_FAST_TESTS_NO_CACHE=1` forces a clean compile.
- Package tests: `swift test --filter '^SpeakerTests\.'` (or any target), `swift test --filter '^TranscriptedWritingTests\.'`. Plain `swift test` is what CI runs.
- `bash run-tests.sh --coverage` writes LLVM coverage under `build/coverage/fast-tests/`.
- Run `run-tests.sh`, `build.sh`, and smokes sequentially; they share `build/`. Give each run its own log file, since two runs sent to one `>` file overwrite each other and look like a flake.

## Flaky tests

A test that fails with no code change gets fixed or benched the same day. Bench by adding `YYYY-MM-DD | <runSuite name, exact> | <why, and who fixes it>` to `Tests/quarantine.txt` (Swift Testing: `.disabled("why")`; XCTest: `XCTSkip("why")`). `check-test-shape.py` fails on a malformed line or a missing suite and warns after 14 days. Never add retries until it passes. Reproduce busy-Mac flakes under load using the owning runner: `bash run-tests.sh --filter <entryFn|File>` for raw-swiftc fast suites, or `swift test --skip-build --filter <Suite>/<test>` for already-built package tests. Repetition is for diagnosis, never a retry-until-green gate.

## Real-world proof

`bash check.sh hardware`, `bash run-live-capture-smoke.sh` (needs mic and System Audio Recording permission), and `bash run-daily-audio-reliability.sh` are local gates, not CI. UI and TCC blockers exit `3` and mean `INCOMPLETE`, never green. The orchestrated bench is `bash scripts/ops/transcripted-qa-bench.sh` (`docs/qa-test-bench.md`).
