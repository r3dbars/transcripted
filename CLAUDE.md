# Transcripted - AI Agent Navigation Guide

## Project Overview
Menu bar-only macOS app for real-time system audio transcription. Pipeline: CoreAudio capture -> Parakeet STT -> PyAnnote diarization -> WeSpeaker embeddings. Output: Markdown transcripts with YAML frontmatter.

## Architecture
- **App entry**: `Transcripted/TranscriptedApp.swift` (@main) -> `AppDelegate` (slim coordinator with extensions)
- **Activation policy**: `.accessory` (menu bar only, no dock icon)
- **UI**: Floating pill (Dynamic Island style) + Settings window + Onboarding window
- **Core library**: `Sources/TranscriptedCore/` — Swift Package (Package.swift at repo root) that contains the audio/transcription/stats/speaker pipeline. The Transcripted app target and Draft's Sources/Meeting/ both consume it as a library.
- **Dependencies**: Sparkle (auto-updates), FluidAudio 0.7.9 via SPM (AsrManager, DiarizerManager, OfflineDiarizerManager — phase 2.0 retired the 123MB committed binaries in favor of package resolution)
- **Protocols**: 6 service protocols in `Sources/TranscriptedCore/Protocols/` (SpeechToTextEngine, DiarizationEngine, SpeakerStore, TranscriptStorage, AudioCaptureEngine, StatsStore) — Core is UI- and STT-agnostic; embedders supply concrete conformers
- **Embedder adapters**: `Transcripted/Services/ParakeetEngineAdapter.swift` (SpeechToTextEngine via FluidAudio), `Transcripted/Services/TranscriptedNotificationsAdapter.swift` (TranscriptNotifier via UNUserNotificationCenter). Draft supplies its own adapters in `Sources/Meeting/`.

## Folder Map
- **Sources/TranscriptedCore/** — The extracted SPM library. Subfolders: Audio/, Pipeline/, Storage/, Speaker/, Stats/, Services/, Models/, Protocols/, Utilities/, Logging/. This is where the transcription pipeline, audio capture, stats DB, speaker DB, and transcript saver live. Consumed by both Transcripted and Draft.
- **Tests/TranscriptedCoreTests/** — SPM test target (5 smoke tests). Run via `swift test` from repo root.
- **Transcripted/** (app target, ~75 files) — macOS app shell that consumes TranscriptedCore:
  - **Core/** (11 files): app-target coordinators — `NotificationCoordinator`, `HotkeyManager`, `MenuBarManager`, `WindowCoordinator`, `RecordingCoordinator`, `AppDelegateDebug`, plus small UI-side helpers (`Clipboard`, `TranscriptExporter`, `TranscriptStore`, `SystemSettingsHelper`, `DiagnosticExporter`). Audio/transcription/stats/speaker code lives in `Sources/TranscriptedCore/`, NOT here.
  - **Services/** (3 files): embedder adapters — `ParakeetEngineAdapter` (wraps FluidAudio for `SpeechToTextEngine`), `TranscriptedNotificationsAdapter` (wraps `UNUserNotificationCenter` for `TranscriptNotifier`), `MeetingDetector` (Zoom/Teams/Webex auto-start). The bulk of pre-extraction ML services (ParakeetService, DiarizationService, SpeakerDatabase, EmbeddingClusterer, AudioResampler, etc.) moved to `Sources/TranscriptedCore/`.
  - **UI/FloatingPanel/**, **UI/Settings/**, **Onboarding/**, **Design/** — unchanged by extraction.
- **Tools/TranscriptedQA/** (22 files): QA testing CLI tool, health checks, transcript/database/index/log validation, fixture generation, round-trip testing, stress testing

## Build & Test
```bash
# Build the app (Xcode target consumes TranscriptedCore via XCLocalSwiftPackageReference)
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted -configuration Debug build

# Run Core library tests (SPM — 5 smoke tests)
swift test

# Run Xcode test target
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted test
```

## Critical Rules
1. **No I/O in CoreAudio callbacks** - Real-time audio thread cannot do file/network/lock operations
2. **Audio.swift and SystemAudioCapture.swift are NOT @MainActor** - They manage AVAudioEngine/CoreAudio which require synchronous access from audio threads. They dispatch UI updates to main thread explicitly.
3. **All other services are @MainActor** - ParakeetEngineAdapter, DiarizationService, Transcription, TranscriptionTaskManager (exception: SpeakerDatabase uses dedicated utility queue instead)
4. **Core is a library — do not import app-target types into it** — `Sources/TranscriptedCore/` must not reference anything in `Transcripted/`. Cross the boundary via protocols in `Sources/TranscriptedCore/Protocols/` and supply conformers in the embedder.
5. **Never commit to main** - Always create feature branches: `feat/description`, `fix/description`
6. **Branch naming**: `feat/{issue-id}-{slug}` or `fix/{issue-id}-{slug}`

## Recording -> Transcript Pipeline
```
User presses Cmd+Shift+R (global hotkey)
  -> Audio.startRecording() [CoreAudio thread]
  -> onRecordingStart callback -> TaskManager.prepareForRecording()
  -> User stops recording
  -> Audio.stopRecording() -> onRecordingComplete(micURL, systemURL)
  -> TaskManager.startTranscription(micURL, systemURL, outputFolder)
     -> Gate: reject < 2s recordings
     -> Step 1 (0-10%): Resample both to 16kHz mono
     -> Step 2 (10-30%): Offline diarization (PyAnnote) + EmbeddingClusterer post-process
     -> Step 3 (30-65%): Transcribe system segments with Parakeet per speaker
     -> Step 4 (65-90%): Transcribe mic segments per silence region
     -> Step 5 (90-100%): Merge consecutive utterances (1.5s gap, 30s cap)
  -> TranscriptSaver.saveTranscript() writes .md + YAML
  -> AgentOutput.writeTranscriptJSON() writes .json sidecar
  -> FloatingPanel shows success state
```

## Key Entry Points
- **Transcripted/TranscriptedApp.swift**: @main struct + slim AppDelegate coordinator. Constructs `TranscriptionTaskManager` with embedder adapters (`ParakeetEngineAdapter`, `TranscriptedNotificationsAdapter`) and Core services (`DiarizationService`, `SpeakerDatabase.shared`).
- **AppDelegate extensions** (in `Transcripted/Core/`): MenuBarManager, HotkeyManager, NotificationCoordinator, WindowCoordinator, RecordingCoordinator, AppDelegateDebug
- **Sources/TranscriptedCore/Pipeline/TranscriptionTaskManager.swift**: Task queue (extensions: SpeakerNamingCoordinator, TranscriptionPipelineRunner). Init takes `notifier: TranscriptNotifier? = nil` — embedders pass a concrete adapter, tests/CLI pass nil.
- **Sources/TranscriptedCore/Pipeline/DisplayStatus.swift**: DisplayStatus enum + TranscriptionTask struct
- **Sources/TranscriptedCore/Audio/Audio.swift**: CoreAudio capture (extensions: AudioDeviceRecovery, AudioLevelMonitor, AudioFileManager)
- **Sources/TranscriptedCore/Pipeline/Transcription.swift**: @MainActor pipeline (extensions: TranscriptionPipeline, SpeakerMatchingService)
- **Sources/TranscriptedCore/Protocols/**: 6 service protocols (SpeechToTextEngine, DiarizationEngine, SpeakerStore, TranscriptStorage, AudioCaptureEngine, StatsStore)
- **Transcripted/Services/ParakeetEngineAdapter.swift**: app-target conformer for `SpeechToTextEngine` wrapping FluidAudio's `AsrManager`.
- **Transcripted/Services/TranscriptedNotificationsAdapter.swift**: app-target conformer for `TranscriptNotifier` wrapping `UNUserNotificationCenter`. Sets `categoryIdentifier = "TRANSCRIPT_SAVED"` so `NotificationCoordinator`'s "Show in Finder" action button fires.

## Threading Model
- **Audio thread**: Audio.swift + SystemAudioCapture.swift (NOT @MainActor, sync audio access)
- **Main thread**: All UI, Transcription, TaskManager, ParakeetService, DiarizationService
- **Utility queue**: SpeakerDatabase (thread-safe SQLite via `DispatchQueue(label: "com.transcripted.speakerdb", qos: .utility)`)
- **Serial queue**: TranscriptSaver file updates, StatsDatabase writes
- **Cross-thread**: Audio dispatches UI updates via `DispatchQueue.main.async`

## Data Storage
- **Transcripts**: `~/Documents/Transcripted/*.md` (Markdown + YAML frontmatter)
- **Agent JSON**: `~/Documents/Transcripted/*.json` (sidecar for each transcript)
- **Speakers DB**: `~/Documents/Transcripted/speakers.sqlite` (256-dim embeddings, profiles)
- **Stats DB**: `~/Documents/Transcripted/stats.sqlite` (recording history, daily activity)
- **Failed queue**: `~/Documents/Transcripted/failed_transcriptions.json`
- **Speaker clips**: `~/Documents/Transcripted/speaker_clips/{speakerId}.wav`
- **Logs**: `~/Library/Logs/Transcripted/app.jsonl` (JSON lines)

## Model Cache
- **Parakeet**: Bundled or downloaded from HuggingFace (~600MB), 16kHz target rate
- **Diarization**: PyAnnote offline + Sortformer streaming, bundled or via FluidAudio
- **Download resilience**: All downloads use `ModelDownloadService` with HuggingFace mirror fallback (`hf-mirror.com`), retry with exponential backoff, and structured error classification

## CLAUDE.md Navigation
Every folder with ≥2 Swift files has its own CLAUDE.md with file index, reference data, and gotchas.

| Path | Scope |
|------|-------|
| `CLAUDE.md` (this file) | Architecture overview, pipeline, entry points |
| `Sources/TranscriptedCore/CLAUDE.md` | Extracted library: audio, transcription, stats, storage, protocols |
| `Tools/TranscriptedMCP/CLAUDE.md` | MCP server: 5 tools, index schema, build/test, Claude Desktop setup |
| `Transcripted/Core/CLAUDE.md` | App-target coordinators only (NotificationCoordinator, HotkeyManager, etc.) |
| `Transcripted/Services/CLAUDE.md` | Embedder adapters (ParakeetEngineAdapter, TranscriptedNotificationsAdapter) + MeetingDetector |
| `Transcripted/Design/CLAUDE.md` | All token values (colors, spacing, radius, typography, animations) |
| `Transcripted/Design/Colors/CLAUDE.md` | Complete color reference with hex/HSB values |
| `Transcripted/Design/Components/CLAUDE.md` | PremiumButton, PremiumCard, BenefitCard, QuickTipRow, AnimatedIcon specs |
| `Transcripted/UI/FloatingPanel/CLAUDE.md` | Pill state machine, Combine subscriptions, tray states |
| `Transcripted/UI/FloatingPanel/Components/CLAUDE.md` | Aurora views, speaker naming, error toast, pill overlays |
| `Transcripted/UI/Settings/CLAUDE.md` | @AppStorage keys, window config, speaker operations |
| `Transcripted/UI/Settings/Sections/CLAUDE.md` | 7 section views with per-section detail |
| `Transcripted/UI/Settings/Components/CLAUDE.md` | CoralToggle, button styles, input components |
| `Transcripted/Onboarding/CLAUDE.md` | 6-step flow, OnboardingState properties, integration |
| `Transcripted/Onboarding/Steps/CLAUDE.md` | Preview, Permissions, ModelSetup, HowItWorks, TestRecording step implementations |
| `Tools/TranscriptedQA/CLAUDE.md` | QA CLI tool, health checks, transcript validation, database/index/log validation |

**Single-file folders** (covered by parent CLAUDE.md):
- `UI/MenuBar/MenuBarStatRow.swift` — Custom NSView (250x22), used in status bar dropdown
- `UI/FloatingPanel/Helpers/LawsComponents.swift` — AnimatedDotsView, LawsButton, FloatingTooltipModifier, Triangle
- `UI/Settings/Models/SettingsNavigationState.swift` — Migration state + vestigial SettingsTab
- `UI/FailedTranscriptionsView.swift` — Standalone window for failed transcription management (600x400 min)

## Tools (external CLI utilities)
- **Tools/TranscriptedMCP/** (7 source + 4 test Swift files): MCP server (`transcripted-mcp`) for querying transcripts from Claude Desktop or any MCP-compatible client. Exposes 5 read-only tools: `list_meetings` (metadata + participants), `read_meeting` (full transcript content), `search` (full-text with optional speaker/date filters), `who_is` (person profile — meeting history, speaking stats, co-speakers, quotes), `recap` (structured day/week digest with previews). Uses a local SQLite index rebuilt from JSON sidecars. File watcher auto-indexes new transcripts. Data dir: `~/Documents/Transcripted` or `$TRANSCRIPTED_DATA_DIR`. Dependencies: `swift-sdk` MCP library (v0.12.0), `libsqlite3`. See `Tools/TranscriptedMCP/CLAUDE.md`.
- **Tools/TranscriptedQA/** (22 Swift files): Standalone Swift CLI (`transcripted-qa`) for validating on-disk artifacts. Subcommands: `validate-all` (default), `validate-transcripts`, `validate-database`, `validate-logs`, `validate-artifacts`, `validate-index`, `check-health`, `generate-fixtures`, `round-trip`, `stress-test`. Validators: TranscriptValidator, SpeakerDBValidator, StatsDBValidator, JSONSidecarValidator, IndexValidator, LogValidator, HealthChecker. Generators: TestDataGenerator. Uses `ArgumentParser`. See `Tools/TranscriptedQA/CLAUDE.md`.
- **Tools/TranscriptedCLI/** (5 Swift files): Standalone Swift CLI (`transcripted-cli`) for offline diarization via FluidAudio. Entry: `TranscriptedCLI.swift` (ArgumentParser root). Subcommands: `diarize` (single file, `DiarizeCommand.swift`), `batch` (directory, `BatchCommand.swift`). Shared: `ConfigLoader.swift` (JSON config -> OfflineDiarizerConfig), `RTTMWriter.swift` (RTTM + JSON output).

## Cross-Repo Dependency (Draft consumes TranscriptedCore)

As of merge-plan Phase 2 (Lane A extraction, tag `extract/core-v1`), the audio/transcription/stats/speaker pipeline lives in `Sources/TranscriptedCore/` as a Swift Package. The Transcripted app and the Draft app both depend on this package:

- **Transcripted** (this repo, app target) consumes TranscriptedCore via `XCLocalSwiftPackageReference` in `Transcripted.xcodeproj`. The package is resolved from `Package.swift` at the repo root. Embedder adapters for STT (`ParakeetEngineAdapter`) and notifications (`TranscriptedNotificationsAdapter`) live in `Transcripted/Services/`.
- **Draft** (`<draft-root>`) consumes TranscriptedCore the same way — Draft's `Sources/Meeting/` files `import TranscriptedCore` and supply their own adapters (`MeetingSTTAdapter` wrapping Draft's ParakeetEngine, `CoreStoragePaths` isolating meeting data under `~/Library/Application Support/Draft/meetings/`). Draft's build system uses `build-deps.sh` to produce a unified `libDraftDeps.a` that links against the same Core sources via `#filePath` resolution in Package.swift.

Because Core is STT-, notification-, and storage-layout-agnostic, both embedders can ship different Parakeet model paths, different notification UX, and different on-disk directory conventions without forking Core. When editing files in `Sources/TranscriptedCore/`, remember that both apps consume them — the Lane A contract is "Core is closed at tag `extract/core-v1`; any change needs cross-app regression testing."

## Documentation
See CONTRIBUTING.md for full development guidelines.

## Skill routing

When the user's request matches an available skill, ALWAYS invoke it using the Skill
tool as your FIRST action. Do NOT answer directly, do NOT use other tools first.
The skill has specialized workflows that produce better results than ad-hoc answers.

Key routing rules:
- Product ideas, "is this worth building", brainstorming → invoke office-hours
- Bugs, errors, "why is this broken", 500 errors → invoke investigate
- Ship, deploy, push, create PR → invoke ship
- QA, test the site, find bugs → invoke qa
- Code review, check my diff → invoke review
- Update docs after shipping → invoke document-release
- Weekly retro → invoke retro
- Design system, brand → invoke design-consultation
- Visual audit, design polish → invoke design-review
- Architecture review → invoke plan-eng-review
