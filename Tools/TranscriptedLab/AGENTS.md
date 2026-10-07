# Transcripted Lab

Transcripted Lab is an experiment orchestrator, not a second implementation of Transcripted. It runs repo scripts and production benchmark seams, then analyzes and compares their artifacts.

## Rules

- Reuse repository-owned scripts and production benchmark seams. Do not copy the diarizer, STT engine, dictation session, speaker matcher, or artifact writer into this package.
- Add a narrow production adapter only when the app has no measurable seam for a required benchmark.
- Keep `TranscriptedLabKit` Foundation-only. The SwiftUI app and the CLI both consume the same kit API.
- Keep reports versioned, Codable, and backward-readable whenever practical.
- Never persist raw audio, embeddings, prompt text, transcript bodies, or speaker clips in Lab JSON reports.

## Hard gates

Never average these away:

- cross-person false merge or false automatic speaker name
- profile contamination regression
- lost or duplicated audio/text
- speech/silence inversion
- delivery failure
- process crash, timeout, or blocking QA failure

## Layout

- `Package.swift` - `TranscriptedLabKit` library, `transcripted-lab` CLI, kit tests, and (macOS only) the `TranscriptedLab` SwiftUI app.
- `Sources/TranscriptedLabKit/`:
  - `LabModels.swift` - `LabBench` (`runtime-snapshot`, `dictation-stop`, `transcription-corpus`, `speaker-identity`, `qa`), option enums, run configuration and report types.
  - `LabCommandBuilder.swift` - run configuration to repo script/command plus expected artifacts (e.g. `scripts/ops/dictation-stop-autoeval.sh`).
  - `LabProcessRunner.swift` - one command, with timeout, in a private temp directory.
  - `LabExperimentRunner.swift` - `actor`: repetitions, artifact analysis, gate scoring, report save. Also `LabDoctor` environment checks.
  - `LabAnalyzers.swift` - per-bench analyzers.
  - `LabReportStore.swift` - report save/load and `LabReportComparator` metric deltas.
  - `LabUtilities.swift` - shell quoting, repository locator, report paths, statistics helpers.
- `Sources/transcripted-lab/TranscriptedLabCLI.swift` - `run`, `snapshot`, `doctor`, `list`, `show`, `compare`.
- `Sources/TranscriptedLab/` - SwiftUI app: `TranscriptedLabApp.swift`, `LabWorkspaceStore.swift` (run/report state over the kit), `LabContentView.swift`.
- `Tests/TranscriptedLabKitTests/TranscriptedLabKitTests.swift` - kit tests.
- `script/build_and_run.sh` - builds both products, assembles and ad-hoc signs a local app bundle, opens it unless `--verify`.

## Validation

```bash
swift test --package-path Tools/TranscriptedLab
swift build --package-path Tools/TranscriptedLab --product transcripted-lab
swift build --package-path Tools/TranscriptedLab --product TranscriptedLab
Tools/TranscriptedLab/script/build_and_run.sh --verify
```

`.github/workflows/transcripted-lab.yml` runs these on `macos-15`; `.agents/test-matrix.yml` carries the same four with `--jobs 4`. The app target is macOS-only; the manifest omits it elsewhere so the kit and CLI stay testable.
