# Transcripted Lab package guidance

Transcripted Lab is an experiment orchestrator, not a second implementation of Transcripted.

## Boundaries

- Reuse repository-owned scripts and production benchmark seams.
- Do not copy the diarizer, STT engine, dictation session, speaker matcher, or artifact writer into this package.
- Add a narrow production adapter only when the app has no measurable seam for a required benchmark.
- Keep `TranscriptedLabKit` Foundation-only. The SwiftUI target consumes it; the CLI consumes the same API.
- Keep reports versioned, Codable, and backward-readable whenever practical.
- Do not persist raw audio, embeddings, prompt text, transcript bodies, or speaker clips in Lab JSON reports.

## Files

- `Package.swift` — `TranscriptedLabKit` library, `transcripted-lab` CLI, kit tests, and (macOS only) the `TranscriptedLab` SwiftUI app
- `Sources/TranscriptedLabKit/` (Foundation-only):
  - `LabModels.swift` — benches (`LabBench`: runtime snapshot, dictation stop, transcription corpus, speaker identity, QA), experiment option enums, and the run configuration/report types
  - `LabCommandBuilder.swift` — turns a run configuration into the repo script/command to execute (e.g. `scripts/ops/dictation-stop-autoeval.sh`) plus its expected artifacts
  - `LabProcessRunner.swift` — runs one command with a timeout in a private temp directory
  - `LabExperimentRunner.swift` — `actor` that runs repetitions, analyzes artifacts, scores gates, and saves the report; also `LabDoctor` environment checks
  - `LabAnalyzers.swift` — per-bench analyzers (runtime events, dictation benchmark, speaker sweep, QA results, speaker auto-research)
  - `LabReportStore.swift` — report save/load plus `LabReportComparator` metric deltas
  - `LabUtilities.swift` — shell quoting, repository locator, report paths, text and statistics helpers
- `Sources/transcripted-lab/TranscriptedLabCLI.swift` — CLI: `run`, `snapshot`, `doctor`, `list`, `show`, `compare`
- `Sources/TranscriptedLab/` — SwiftUI app: `TranscriptedLabApp.swift` (entry), `LabWorkspaceStore.swift` (observable run/report state over the kit), `LabContentView.swift` (sidebar, experiment form, run detail)
- `Tests/TranscriptedLabKitTests/TranscriptedLabKitTests.swift` — kit tests
- `script/build_and_run.sh` — builds both products, assembles and ad-hoc signs a local app bundle, and opens it unless `--verify`

## Hard gates

Never average these away:

- cross-person false merge or false automatic speaker name
- profile contamination regression
- lost or duplicated audio/text
- speech/silence inversion
- delivery failure
- process crash, timeout, or blocking QA failure

## Validation

For changes inside this package:

```bash
swift test --package-path Tools/TranscriptedLab
swift build --package-path Tools/TranscriptedLab --product transcripted-lab
swift build --package-path Tools/TranscriptedLab --product TranscriptedLab
Tools/TranscriptedLab/script/build_and_run.sh --verify
```

These are the same four steps `.github/workflows/transcripted-lab.yml` runs on `macos-15` (CI adds `--jobs 4`). `.agents/test-matrix.yml` has no Lab-specific rule, so `agent-preflight.sh` will not suggest these; run them yourself.

The app target is macOS-only. The package manifest intentionally omits it on non-macOS hosts so the Foundation-only kit and CLI remain testable elsewhere.
