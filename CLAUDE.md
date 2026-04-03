# Transcripted - AI Agent Navigation Guide

## Project Overview
Menu bar-only macOS app for real-time system audio transcription. Pipeline: CoreAudio capture -> Parakeet STT -> PyAnnote diarization -> WeSpeaker embeddings. Output: Markdown transcripts with YAML frontmatter.

## Architecture
- **App entry**: `TranscriptedApp.swift` (@main) -> `AppDelegate` (slim coordinator with extensions)
- **Activation policy**: `.accessory` (menu bar only, no dock icon)
- **UI**: Floating pill (Dynamic Island style) + Settings window + Onboarding window
- **Dependencies**: Sparkle (auto-updates), FluidAudio (static lib at `fluidaudio-libs/libFluidAudioAll.a`)
- **Protocols**: 6 service protocols in `Services/Protocols/` (SpeechToTextEngine, DiarizationEngine, SpeakerStore, etc.)
- **DI**: `AppServices` container in `Core/AppServices.swift`

## Folder Map (~138 Swift files, agent-first: max ~300 lines per file, single responsibility)
- **Core/** (47 files): Audio capture (Audio + 3 extensions), transcription pipeline (TaskManager + 2 extensions), transcript saving (4 files), stats DB (3 files), model downloads (ModelDownloadService), failed transcription retry, file permissions, logging, coordinators (Hotkey, MenuBar, Notification, Window, Recording)
- **Services/** (16 files): ML services (10 files) + Protocols/ subdirectory (6 service protocols)
- **UI/FloatingPanel/** (21 files): Morphing pill UI, aurora state views (3 files), SavedPillView, transcript tray (3 files), speaker naming (3 files), Components/ (16 files), Helpers/ (1 file)
- **UI/Settings/** (17 files): Settings container + Sections/ (6 section views) + Components/ (6 reusable components) + Models/ (1 file)
- **Onboarding/** (9 files): 6-step first-run flow (Welcome -> Preview -> Permissions -> Model Setup -> How It Works -> Test Recording), dark theme
- **Design/** (21 files): Colors/ (6 files), Components/ (5 premium components), root tokens (10 files: Spacing, Radius, Typography, Animations, Shadows, ViewModifiers, Gradients, Dimensions, Accessibility, CardModifiers)
- **Tools/TranscriptedQA/** (12 files): QA testing CLI tool, health checks, transcript validation, database integrity checks, index validation, log analysis

## Build & Test
```bash
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted -configuration Debug build 2>&1
```
Test command: `xcodebuild -project Transcripted.xcodeproj -scheme Transcripted test`

## Critical Rules
1. **No I/O in CoreAudio callbacks** - Real-time audio thread cannot do file/network/lock operations
2. **Audio.swift and SystemAudioCapture.swift are NOT @MainActor** - They manage AVAudioEngine/CoreAudio which require synchronous access from audio threads. They dispatch UI updates to main thread explicitly.
3. **All other services are @MainActor** - ParakeetService, DiarizationService, Transcription, TranscriptionTaskManager (exception: SpeakerDatabase uses dedicated utility queue instead)
4. **Never commit to main** - Always create feature branches: `feat/description`, `fix/description`
5. **Branch naming**: `feat/{issue-id}-{slug}` or `fix/{issue-id}-{slug}`

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
- **TranscriptedApp.swift**: @main struct + slim AppDelegate coordinator
- **AppDelegate extensions**: MenuBarManager, HotkeyManager, NotificationCoordinator, WindowCoordinator, RecordingCoordinator (in Core/)
- **Core/TranscriptionTaskManager.swift**: Task queue (extensions: SpeakerNamingCoordinator, TranscriptionPipelineRunner)
- **Core/DisplayStatus.swift**: DisplayStatus enum + TranscriptionTask struct
- **Core/Audio.swift**: CoreAudio capture (extensions: AudioDeviceRecovery, AudioLevelMonitor, AudioFileManager)
- **Core/Transcription.swift**: @MainActor pipeline (extensions: TranscriptionPipeline, SpeakerMatchingService)
- **Core/AppServices.swift**: DI container with protocol-typed services
- **Services/Protocols/**: 6 service protocols (SpeechToTextEngine, DiarizationEngine, SpeakerStore, etc.)

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

## CLAUDE.md Navigation (16 files)
Every folder with ≥2 Swift files has its own CLAUDE.md with file index, reference data, and gotchas.

| Path | Scope |
|------|-------|
| `CLAUDE.md` (this file) | Architecture overview, pipeline, entry points |
| `Tools/TranscriptedMCP/CLAUDE.md` | MCP server: 5 tools, index schema, build/test, Claude Desktop setup |
| `Transcripted/Core/CLAUDE.md` | Audio, transcription, stats, error handling, coordinators |
| `Transcripted/Core/Logging/CLAUDE.md` | Logger subsystems, JSON Lines format, rolling behavior |
| `Transcripted/Services/CLAUDE.md` | ML services, speaker DB, thresholds, pipeline order |
| `Transcripted/Services/Protocols/CLAUDE.md` | 6 DI protocols with full signatures |
| `Transcripted/Design/CLAUDE.md` | All token values (colors, spacing, radius, typography, animations) |
| `Transcripted/Design/Colors/CLAUDE.md` | Complete color reference with hex/HSB values |
| `Transcripted/Design/Components/CLAUDE.md` | PremiumButton, PremiumCard, BenefitCard, QuickTipRow, AnimatedIcon specs |
| `Transcripted/UI/FloatingPanel/CLAUDE.md` | Pill state machine, Combine subscriptions, tray states |
| `Transcripted/UI/FloatingPanel/Components/CLAUDE.md` | Aurora views, speaker naming, error toast, pill overlays |
| `Transcripted/UI/Settings/CLAUDE.md` | @AppStorage keys, window config, speaker operations |
| `Transcripted/UI/Settings/Sections/CLAUDE.md` | 6 section views with per-section detail |
| `Transcripted/UI/Settings/Components/CLAUDE.md` | CoralToggle, button styles, input components |
| `Transcripted/Onboarding/CLAUDE.md` | 5-step flow, OnboardingState properties, integration |
| `Transcripted/Onboarding/Steps/CLAUDE.md` | Preview, Permissions, ModelSetup, HowItWorks, TestRecording step implementations |
| `Tools/TranscriptedQA/CLAUDE.md` | QA CLI tool, health checks, transcript validation, database/index/log validation |
| `Tools/TranscriptedMCP/CLAUDE.md` | MCP server tools, SQLite index schema, name variants, file watcher |

**Single-file folders** (covered by parent CLAUDE.md):
- `UI/MenuBar/MenuBarStatRow.swift` — Custom NSView (250x22), used in status bar dropdown
- `UI/FloatingPanel/Helpers/LawsComponents.swift` — AnimatedDotsView, LawsButton, FloatingTooltipModifier, Triangle
- `UI/Settings/Models/SettingsNavigationState.swift` — Migration state + vestigial SettingsTab
- `UI/FailedTranscriptionsView.swift` — Standalone window for failed transcription management (600x400 min)

## Tools (external CLI utilities)
- **Tools/TranscriptedMCP/** (7 source + 4 test Swift files): MCP server (`transcripted-mcp`) for querying transcripts from Claude Desktop or any MCP-compatible client. Exposes 5 read-only tools: `list_meetings` (metadata + participants), `read_meeting` (full transcript content), `search` (full-text with optional speaker/date filters), `who_is` (person profile — meeting history, speaking stats, co-speakers, quotes), `recap` (structured day/week digest with previews). Uses a local SQLite index rebuilt from JSON sidecars. File watcher auto-indexes new transcripts. Data dir: `~/Documents/Transcripted` or `$TRANSCRIPTED_DATA_DIR`. Dependencies: `swift-sdk` MCP library (v0.12.0), `libsqlite3`.
- **Tools/TranscriptedQA/** (19 Swift files): Standalone Swift CLI (`transcripted-qa`) for validating on-disk artifacts. Subcommands: `validate-all` (default), `validate-transcripts`, `validate-database`, `validate-logs`, `validate-artifacts`, `validate-index`, `check-health`. Validators: TranscriptValidator, SpeakerDBValidator, StatsDBValidator, JSONSidecarValidator, IndexValidator, LogValidator, HealthChecker. Uses `ArgumentParser`.
- **Tools/TranscriptedCLI/** (5 Swift files): Standalone Swift CLI (`transcripted-cli`) for offline diarization via FluidAudio. Entry: `TranscriptedCLI.swift` (ArgumentParser root). Subcommands: `diarize` (single file, `DiarizeCommand.swift`), `batch` (directory, `BatchCommand.swift`). Shared: `ConfigLoader.swift` (JSON config -> OfflineDiarizerConfig), `RTTMWriter.swift` (RTTM + JSON output).
- **Tools/TranscriptedMCP/** (8 Swift files): MCP server (`transcripted-mcp`) for Claude Desktop integration. Exposes 5 tools: `list_meetings`, `read_meeting`, `search`, `who_is`, `recap`. Uses SQLite index (`mcp_index.sqlite`) via `TranscriptIndex.swift`; file watching via `FileWatcher.swift`; name variant expansion via `NameVariants.swift` (mirrors SpeakerProfileMerger). Data dir: `~/Documents/Transcripted/` (override via `TRANSCRIPTED_DATA_DIR` env). See `Tools/TranscriptedMCP/CLAUDE.md`.

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
