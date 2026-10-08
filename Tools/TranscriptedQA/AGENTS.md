# TranscriptedQA

`transcripted-qa` is a standalone Swift CLI that validates Transcripted's on-disk artifacts (meetings, dictations, writing days, SpeakerDB/StatsDB, logs) and drives no-publish smoke checks against a built app. It never links the app target.

## Where things live

All code is under `Sources/TranscriptedQA/`; tests under `Tests/TranscriptedQATests/`.

- `TranscriptedQA.swift` - `@main`, `PathOptions`, `QADataDirectories.resolve`, and the subcommand list.
- `Commands/` - one file per subcommand, plus smoke helpers: `AXInspector.swift` (Accessibility tree + launched-app handle), `PackagedAppSmokeRunner.swift` (the packaged-app checks), `FirstRunReliability{Launch,Report,SmokeRunner}.swift` (isolated first-run scenarios, run from the packaged-app tail), `PrivacyLogScanner.swift`.
- `Validators/` - `Transcript`, `Dictation`, `Writing`, `SpeakerDB`, `StatsDB`, `Log` validators and `HealthChecker`. Writing validation: no folder or no files means no results (writing is opt-in), and details never echo text.
- `Generators/TestDataGenerator.swift` - fixture builder shared by `generate-fixtures`, `round-trip`, `stress-test`.
- `Models/ValidationResult.swift` - `ValidationResult` (check, PASS/WARN/FAIL, target, detail) and `ValidationReport` (summary, exit code, text or JSON). JSON adds `automation` and `failureFingerprints` (grouped non-pass checks with stable ids) for agents.
- `Utilities/` - `NativeSmokeIsolation`, `ProcessTermination` (graceful terminate, then SIGKILL), `ReportWritable` (`--report` JSON), `SQLiteReader` (read-only), `YAMLParser`.

## Subcommands

Registered in `TranscriptedQA.configuration`; `validate-all` is the default.

- Validate: `validate-all`, `validate-transcripts`, `validate-database`, `validate-logs`, `check-health`, `speaker-stats` (funnel, graduation, precision, 30-day trends from `speaker_match_outcomes`).
- Fixtures: `generate-fixtures`, `round-trip` (inject corruption, confirm validators catch it), `stress-test`.
- Smokes: `imported-audio-smoke`, `imported-audio-native-smoke`, `ui-smoke`, `sparkle-update-smoke`, `packaged-app-smoke`, `permission-state`.

What each smoke does and does not prove:

- `imported-audio-smoke`: deterministic synthetic WAV through the imported-meeting artifact shape (`system_audio` metadata, retained single-file audio, parser discovery, transcript validation). Not file-picker or real ML transcription proof.
- `imported-audio-native-smoke`: drives the native import picker; needs Accessibility and local models.
- `ui-smoke`: stable AX identifiers across onboarding, menu bar, Home, Settings. Exits `3` for Accessibility/TCC blockers.
- `sparkle-update-smoke`: fake update-available and downloading states, real menu snapshot. Local UI proof only, not live appcast/download/install.
- `packaged-app-smoke`: validates a no-publish `build-beta.sh` artifact (version/config parity, Sparkle keys, signing, dSYM UUIDs, DMG, appcast, log privacy, optional `--run-ui-smoke`).
- `permission-state`: no-prompt probe (`--mode computer-use|live-capture`) of host grants and the Transcripted bundle id; warns on duplicate or wrong running app instances.

## Run and test

```bash
cd Tools/TranscriptedQA
swift build && swift test
swift run transcripted-qa validate-all
swift run transcripted-qa packaged-app-smoke --app ../../build/Transcripted.app --dsym ../../build/Transcripted.app.dSYM --run-ui-smoke
swift run transcripted-qa <subcommand> --help   # per-command flags
```

## Gotchas

- Adding or removing a subcommand means editing `TranscriptedQA.configuration`, this doc, and the matching test file.
- Native app-launch smokes (UI, imported audio native, first-run, Sparkle UI) refuse to run in the active macOS account; use a separate account or a verified hosted CI runner. A temporary `HOME` does not isolate `UserDefaults.standard`. `NativeSmokeIsolationTests` pins this.
- Default paths come from the app-selected capture library (`mcp-directories.json` or `transcriptSaveLocation`). Missing current paths fall back to legacy Draft exports, then `~/Documents/Transcripted/`. `LegacyCaptureDirectoriesContractTests` guards that layout against `CaptureLibraryResolver.legacyCaptureDirectories`. The current layout keeps state and logs under `~/Library/Application Support/Transcripted/`; explicit legacy capture paths can infer legacy state/log locations as described below.
- `--path` chooses the meetings directory and infers the base layout for unspecified dictation, state and log paths. A path under legacy Draft meetings inherits its legacy state directory and log file; a legacy shared capture path inherits that shared layout. Set `--state-dir` and `--log-path` explicitly when those should use current app state. Use `--dictations-path` and `--writing-path` for other overrides. With `--path`, writing is inferred only from a `writing/` folder beside a `meetings` path or inside the given root.
- Validators run synchronously; SQLite readers open read-only with no queueing. Callers own thread safety.
