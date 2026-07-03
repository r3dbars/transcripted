# Testing tiers

Transcripted runs tests in three tiers. They differ by what they touch (pure
logic vs. real I/O vs. hardware) and where they run (every PR vs. opt-in). This
doc is the shared vocabulary; the enforceable per-path mapping still lives in
`.agents/test-matrix.yml`, and that file wins on any conflict.

## Tier 1 — Fast logic tests

Pure, deterministic, no hardware. The bulk of the suite.

- Runner: `bash run-tests.sh` (a custom `swiftc` runner, **not** XCTest)
- Source of truth: `Tests/FastTests.manifest` — one `<File>.swift:<entryFn>`
  line per test. A new root `Tests/*Tests.swift` file is invisible until it's
  registered here, and the runner fails if the manifest and the on-disk test
  files drift.
- Helpers: `Tests/TestHelpers.swift` (`runSuite`, `assertEqual`, `assertTrue`, …)
- Compiles against a curated `APP_SOURCES` list inside `run-tests.sh`. If a unit
  under test isn't in that list, add it there.
- Scope: policies, formatters, parsers, preference migration, state classifiers,
  debounce/chord selection, and anything else with clean inputs and outputs.

Run one: `bash run-tests.sh --filter <entryFn|File>`. List them:
`bash run-tests.sh --list`. Coverage: `bash run-tests.sh --coverage`.

## Tier 2 — Component / integration tests

Real file I/O, SQLite, state machines, multi-component flows. XCTest.

- Runners:
  - `swift test` — the `TranscriptedCore` SPM seam (`Tests/TranscriptedCoreTests/`)
  - `swift test --package-path Tools/<Tool>` — each standalone tool
    (`TranscriptedCaptureKit`, `TranscriptedCLI`, `TranscriptedMCP`, `TranscriptedQA`)
  - `bash run-integration-smoke.sh` — proves `TranscriptedCore` links into the
    app archive and Core types construct, plus wake-recovery and the mic-merge
    package test
- These are auto-discovered XCTest cases — no manifest entry needed.
- Scope: the audio pipeline FSM, transcription orchestration, speaker
  diarization / merge, transcript save+scan, MCP indexing, capture-Markdown
  parsing.

## Tier 3 — End-to-end / smoke / hardware

Whole-artifact and real-hardware paths.

- Deterministic (run in CI, no mic/TCC):
  - `bash run-e2e-smoke.sh` — capture-artifact round trip in a sandboxed fake home
  - `bash run-slow-pasteback-smoke.sh` — clipboard-restoration timing
- Hardware / TCC (opt-in, `workflow_dispatch` only — needs a real mic and the
  System Audio Recording grant):
  - `bash run-live-capture-smoke.sh`
- The deterministic smokes compile from explicit source lists; if you move a
  file they reference, update the list (the `*SourceListContract` fast tests
  guard this).

## CI

`.github/workflows/swift-ci.yml` (macos-26) runs Tier 1, Tier 2, and the
deterministic Tier 3 smokes on every PR. The hardware smokes are echo-only there
until a self-hosted runner exists. `.github/workflows/repo-hygiene.yml` runs
shell/ruby/python syntax checks and `agent-preflight.sh`.

## The format-sync contract (why a contract spans two tiers)

`TranscriptedCore.TranscriptFormatter` writes meeting Markdown, and
`Tools/TranscriptedCaptureKit/CaptureMarkdownParser` parses it for the CLI and
MCP tools. The kit deliberately does **not** link Core, so the writer and the
parser can drift without anything failing to compile. Two tests pin them
together — change the format and both must change:

- Writer side: `Tests/TranscriptedCoreTests/TranscriptFormatterCaptureKitContractTests.swift`
  asserts the exact frontmatter keys, channel-qualified speaker block, and
  `[mm:ss] [Source/Label]` transcript rows the kit keys on.
- Parser side: `CaptureMarkdownParserTests.testRoundTripParsesWriterDocument`
  parses a verbatim sample of that writer output.

The same rule applies to the `Dictations_YYYY-MM-DD.md` day-file format
(`Sources/Dictation/DictationTranscriptWriter.swift` ↔ the kit's dictation
parser).

## Adding a test — quick reference

- Pure logic with clean inputs/outputs → Tier 1. Add the file under `Tests/`,
  register it in `Tests/FastTests.manifest`, and make sure the unit's source is
  in the `APP_SOURCES` list in `run-tests.sh`.
- Needs files, SQLite, or Core/tool internals → Tier 2 XCTest under the matching
  package's `Tests/` directory. No manifest entry.
- Needs whole-artifact or hardware coverage → Tier 3 smoke.

When in doubt, run `bash scripts/dev/agent-preflight.sh` for the suggested
verification map for your branch diff, and cross-check `.agents/test-matrix.yml`.
