# Transcripted Repo Inventory

Read-only recon of `<transcripted-root>` for the Draft ↔ Transcripted merge. Produced by `transcripted-mapper` on 2026-04-04. Current branch in Transcripted: `docs/claude-md-sync-20260404`, tip `6ff2e98` (post v0.5.2). All file paths below are relative to the Transcripted repo root unless stated absolute.

**Most important deliverable: §3 "TranscriptedCore file list" and §11 "Extraction blockers."** Everything else in this document is framing for those two.

---

## 1. Top-Level Repo Layout

Transcripted is an **Xcode project**, not an SPM package. The app target is `Transcripted` (menu-bar macOS 26 / Tahoe app, `.accessory` activation policy). Alongside it are three standalone Swift packages under `Tools/` that deliberately do not link the app target.

```
<transcripted-root>/
├── Transcripted.xcodeproj/               # Main Xcode project (Swift 6 toolchain)
│   ├── project.pbxproj                   # Links libFluidAudioAll.a + SWIFT_INCLUDE_PATHS
│   └── xcshareddata/
├── Transcripted/                         # App sources — see §2
├── TranscriptedTests/                    # XCTest host-app tests (47 files)
├── Tools/                                # Standalone Swift packages — see §9
│   ├── TranscriptedCLI/                  # Offline diarizer CLI (FluidAudio only)
│   ├── TranscriptedMCP/                  # MCP server for Claude Desktop
│   └── TranscriptedQA/                   # On-disk artifact validator CLI
├── fluidaudio-libs/
│   └── libFluidAudioAll.a                # ~54 MB static lib (all FluidAudio + deps)
├── fluidaudio-modules/                   # Prebuilt .swiftmodule files (Swift 6.3 toolchain)
│   ├── FluidAudio.swiftmodule/
│   ├── Hub.swiftmodule/                  # HuggingFace hub client
│   ├── HuggingFace.swiftmodule/
│   ├── Tokenizers.swiftmodule/
│   ├── Jinja.swiftmodule/                # Template engine
│   ├── Crypto.swiftmodule/               # swift-crypto
│   ├── Atomics.swiftmodule/              # swift-atomics
│   ├── DequeModule, OrderedCollections, InternalCollectionsUtilities (swift-collections)
│   ├── ContainersPreview.swiftmodule/
│   ├── EventSource.swiftmodule/
│   ├── NIOCore, NIOConcurrencyHelpers, _NIOBase64, _NIODataStructures (SwiftNIO bits)
│   ├── FastClusterWrapper/               # C module (VBx clustering)
│   ├── MachTaskSelfWrapper/              # C module (mach_task_self shim)
│   └── yyjson/                           # C JSON parser
├── Assets.xcassets/                      # AccentColor + AppIcon only (no in-code lookups)
├── Info.plist                            # Usage strings, LSUIElement=1, CFBundle*
├── Transcripted/Transcripted.entitlements# App Sandbox/hardened runtime
├── release-0.2.0/ … release-0.5.2/       # DMG + ZIP artifacts (ignore for merge)
├── scripts/                              # build-fluidaudio, notarize, release, monitor-recording
├── docs/                                 # appcast.xml + screenshots
├── CLAUDE.md                             # Architecture overview (17 nested CLAUDE.md files)
├── CHANGELOG.md, CONTRIBUTING.md, README.md, LICENSE, SECURITY.md
└── .env                                  # Local env file (ignore)
```

**Line-count sanity checks** (Transcripted/Core + Services + Protocols only):
- `Transcripted/Core/*.swift` + `Transcripted/Core/Logging/*.swift`: ~12,600 LOC across 48 files
- `Transcripted/Services/*.swift` + `Transcripted/Services/Protocols/*.swift`: ~2,440 LOC across 16 files
- Combined Core+Services: ~15,000 LOC, 64 files — this is the bulk of what would become TranscriptedCore.

---

## 2. The `Transcripted/` Source Tree

One entry file + five top-level groups. All files are app-bundled — no existing `Sources/` SPM layout.

```
Transcripted/
├── TranscriptedApp.swift                 # @main + slim AppDelegate (216 LOC)
├── Info.plist, Transcripted.entitlements
├── Resources/Assets.xcassets             # AccentColor, AppIcon only
├── Core/            (48 files)           # Audio + pipeline + storage + coordinators
├── Services/        (16 files)           # ML services + 6 protocols
├── UI/              (36 files)           # FloatingPanel + Settings + FailedTranscriptionsView + MenuBar
├── Design/          (21 files)           # Colors, Components, tokens
└── Onboarding/      (9 files)            # 6-step first-run flow
```

### 2.1 `Core/` (48 files) — logical groupings

Exhaustive list with one-liners. Types declared are all `internal` (default) unless noted.

**App lifecycle & coordinators (AppDelegate extensions):**
| File | Type(s) | Purpose |
|---|---|---|
| `AppServices.swift` | `struct AppServices` (@MainActor) | DI container holding Parakeet+Diarization+SpeakerDB concrete types (aspirational protocol form noted in code comments) |
| `RecordingCoordinator.swift` | `extension AppDelegate` | Recording toggle, orphan file cleanup |
| `MenuBarManager.swift` | `extension AppDelegate` | Status bar menu construction |
| `HotkeyManager.swift` | `extension AppDelegate` | Global Cmd+Shift+R registration |
| `NotificationCoordinator.swift` | `extension AppDelegate` | UNUserNotificationCenter categories + delegate |
| `WindowCoordinator.swift` | `extension AppDelegate` | Settings/Onboarding/panel windows |
| `AppDelegateDebug.swift` | `extension AppDelegate` | DEBUG-only reset helpers |

**Audio capture (NOT @MainActor — runs on audio threads):**
| File | Type(s) | Purpose |
|---|---|---|
| `Audio.swift` | `class Audio: ObservableObject`, `enum SystemAudioStatus` | AVAudioEngine setup, Published UI state, sleep/wake, silence detection (618 LOC) |
| `AudioDeviceRecovery.swift` | `extension Audio` | Watchdog timer, reconnect, sleep/wake proactive recovery |
| `AudioFileManager.swift` | `extension Audio` | WAV file creation, buffer copy, format conversion, 0o600 perms |
| `AudioLevelMonitor.swift` | `extension Audio` | RMS metering, rolling 15-element level history |
| `SystemAudioCapture.swift` | `class SystemAudioCapture: ObservableObject` | CoreAudio process-tap wrapper (macOS 14.2+) |
| `SystemAudioProcessTap.swift` | `extension SystemAudioCapture` | Aggregate device setup, format negotiation |
| `SystemAudioBufferWriter.swift` | `extension SystemAudioCapture` | Buffer stats, recovery listener |
| `CoreAudioUtils.swift` | `extension AudioObjectID`, `extension String`, `extension AudioObjectPropertyAddress` | CoreAudio property helpers |

**Transcription pipeline orchestration:**
| File | Type(s) | Purpose |
|---|---|---|
| `Transcription.swift` | `class Transcription: ObservableObject` (@MainActor), `struct SpeakerMapping` | Top-level pipeline class, owns Parakeet+Diarization+SpeakerDB refs |
| `TranscriptionPipeline.swift` | `extension Transcription` | `transcribeMultichannel(...)` — the 5-step pipeline; nonisolated to keep off main thread |
| `TranscriptionPipelineRunner.swift` | `extension TranscriptionTaskManager` | Phase orchestration: transcribe → DB classify → save → speaker naming |
| `TranscriptionTaskManager.swift` | `class TranscriptionTaskManager: ObservableObject` (@MainActor) | Task queue, `startTranscription(...)`, `retryFailedTranscription(...)`, Published progress (294 LOC) |
| `TranscriptionTypes.swift` | `struct TranscriptionUtterance`, `struct TranscriptionResult`, `enum PipelineError: LocalizedError`, `enum SpeakerConfidence`, `struct IdentifiedSpeaker`, `struct TranscriptionMetadata`, `struct SpeakerNamingRequest`, `struct SpeakerNamingEntry`, `struct SpeakerNameUpdate` | Every engine-agnostic pipeline type (189 LOC — pure data, zero deps beyond Foundation) |
| `DisplayStatus.swift` | `enum DisplayStatus: Equatable`, `struct TranscriptionTask: Identifiable` | UI status enum + task record |
| `SpeakerMatchingService.swift` | `extension Transcription` | `matchAgainstProfiles`, `computeMeanEmbedding`, `cosineSimilarityStatic` — nonisolated static helpers |
| `SpeakerNamingCoordinator.swift` | `extension TranscriptionTaskManager` | Applies user-typed names to DB + transcript, merges profiles by name |

**Transcript output:**
| File | Type(s) | Purpose |
|---|---|---|
| `TranscriptSaver.swift` | `class TranscriptSaver` | Static save methods, `defaultSaveDirectory`, `fileUpdateQueue`, shows UNUserNotification on save |
| `TranscriptFormatter.swift` | `extension TranscriptSaver` | `escapeYAML`, `formatMarkdown`, `formatTranscriptMarkdown` (static) |
| `TranscriptMetadataBuilder.swift` | `struct RecordingHealthInfo` | Capture-quality enum, YAML metadata builder from `Audio` |
| `RetroactiveSpeakerUpdater.swift` | `extension TranscriptSaver` | Renames speaker across all existing .md files via fileUpdateQueue |
| `TranscriptStore.swift` | `class TranscriptStore: ObservableObject` (@MainActor), `struct SpeakerInfo`, `struct TranscriptSummary`, `struct TranscriptLine` | Imports SwiftUI — tray UI adapter (352 LOC) |
| `TranscriptExporter.swift` | `enum TranscriptExporter` | Imports AppKit — NSSavePanel .md/.txt export |
| `TranscriptScanner.swift` | (file-level funcs) | Scans save dir for transcripts, migration |
| `TranscriptUtils.swift` | `enum TranscriptUtils` | Misc formatting helpers |
| `AgentOutput.swift` | `enum AgentOutput`, `struct Agent{Transcript,Recording,Engines,Speaker,Utterance,Index,IndexEntry,KnownSpeaker}` | JSON sidecar + index writer — pure Foundation, all Codable (357 LOC) |

**Stats:**
| File | Type(s) | Purpose |
|---|---|---|
| `StatsDatabase.swift` | `class StatsDatabase` | SQLite on serial queue (com.transcripted.statsdb), WAL + 0o600 |
| `StatsDatabaseModels.swift` | `struct RecordingMetadata`, `struct DailyActivity` | Pure data |
| `StatsDatabaseQueries.swift` | `extension StatsDatabase` | Aggregations/queries |
| `StatsService.swift` | `class StatsService: ObservableObject` (@MainActor, singleton) | Dashboard Published stats + heat-map data |

**Model downloads & validation:**
| File | Type(s) | Purpose |
|---|---|---|
| `ModelDownloadService.swift` | `enum ModelDownloadService`, `enum DownloadErrorKind`, `struct ModelDownloadError` | HF mirror fallback (hf-mirror.com), retry (2/5/10s), NWPathMonitor reachability, error classification. Pure Foundation+Network+CryptoKit. |
| `RecordingValidator.swift` | `class RecordingValidator` (static) | Pre-recording checks: disk, permissions, path safety (symlinks/.., /System/etc rejected) |
| `FilePermissions.swift` | `extension FileManager` | `restrictToOwnerOnly(atPath:)` → 0o600 |

**Failed-transcription retry queue:**
| File | Type(s) | Purpose |
|---|---|---|
| `FailedTranscription.swift` | `struct FailedTranscription: Identifiable, Codable, Equatable` | Pure data |
| `FailedTranscriptionManager.swift` | `class FailedTranscriptionManager: ObservableObject` (@MainActor) | Persisted JSON queue, auto-clean permanent errors |

**Utilities (small, mostly pure):**
| File | Type(s) | Purpose |
|---|---|---|
| `Clipboard.swift` | `class Clipboard` | Imports AppKit+UserNotifications — NSPasteboard wrapper |
| `DateFormattingHelper.swift` | `enum DateFormattingHelper` | `formatFilename`, `formatFilenamePrecise`, `formatDisplay` |
| `DateParser.swift` | `enum DateParser` | Date parsing |
| `SystemSettingsHelper.swift` | `enum SystemSettingsHelper` | Imports AppKit — opens System Settings panes via `x-apple.systempreferences:` |
| `DiagnosticExporter.swift` | `class DiagnosticExporter` | Imports AppKit — diagnostic bundle export; reads `Bundle.main.infoDictionary` for version/build |

**Logging (`Core/Logging/`):**
| File | Type(s) | Purpose |
|---|---|---|
| `AppLogger.swift` | `final class AppLogger: @unchecked Sendable`, `struct SubsystemLogger: Sendable` | 10 subsystem loggers, dual output (os.Logger + FileLogger) |
| `FileLogger.swift` | (file-level) | JSONL writer with flock(), rolling 2000-entry cap |

### 2.2 `Services/` (16 files)

| File | Actor | Types | Purpose |
|---|---|---|---|
| `ParakeetService.swift` | @MainActor | `class ParakeetService: ObservableObject`, `enum ParakeetModelState` | FluidAudio AsrManager wrapper. `initialize()` loads from bundle or downloads. `transcribeSegment(samples:source:)` (nonisolated). **Bundle.main.resourcePath lookup** — blocker §11. |
| `DiarizationService.swift` | @MainActor | `class DiarizationService: ObservableObject`, `struct SpeakerSegment`, `enum DiarizationModelState` | Dual pipeline: Sortformer (streaming) + OfflineDiarizerManager (PyAnnote). Champion offline config embedded (`clusteringThreshold: 0.6, Fa: 0.25, Fb: 0.63, windowDuration: 10.0, segmentationStepRatio: 0.266, embeddingBatchSize: 32, minSegmentDuration: 1.1821, minGapDuration: 0.2874, exclusiveSegments: true, speechOnsetThreshold: 0.4472, maxVBxIterations: 24, min/maxSpeakers: 3/11`). Also has **Bundle.main.resourcePath** lookup. |
| `SpeakerDatabase.swift` | utility queue | `final class SpeakerDatabase: @unchecked Sendable` | SQLite at `~/Documents/Transcripted/speakers.sqlite`, singleton `.shared` + testable `init(path:)`. WAL, 0o600, quick_check corruption recovery. Dedicated `com.transcripted.speakerdb` utility queue. |
| `SpeakerEmbeddingMatcher.swift` | — | (extension/file-level) | vDSP-accelerated cosine similarity |
| `SpeakerProfile.swift` | — | `struct SpeakerProfile: Identifiable`, `struct SpeakerMatchResult`, `enum NameSource` | Pure data (25 LOC) |
| `SpeakerProfileMerger.swift` | utility queue | (file-level) | Name variant table, merge/prune/fuzzy match |
| `EmbeddingClusterer.swift` | static | `enum EmbeddingClusterer` | 3-stage post-process: pairwise merge 0.85, small-cluster absorption 0.72/0.62, DB-informed split 0.62 (393 LOC) |
| `AudioResampler.swift` | static | `enum AudioResampler` | AVAudioConverter → 16kHz mono, 30s chunked loading, `loadAndResample(url:,targetRate:)`, `extractSlice(...)` |
| `SpeakerClipExtractor.swift` | static | `enum SpeakerClipExtractor`, `struct ClipResult` | Per-speaker WAV clips for naming UI, persistent clips at `speaker_clips/{speakerId}.wav`, 0o600 |
| `MeetingDetector.swift` | @MainActor | `class MeetingDetector: ObservableObject` | Imports AppKit — Zoom/Teams/Webex/FaceTime/Loom NSRunningApplication polling + 5s dual-stream audio confirmation |

**`Services/Protocols/` (6 files — all aspirational, conformances declared in protocols file but NOT applied to concrete types yet; AppServices.swift still uses concrete types):**

| File | Protocol | Conformer (unapplied) | Signature summary |
|---|---|---|---|
| `SpeechToTextEngine.swift` | `@MainActor protocol SpeechToTextEngine: ObservableObject` | ParakeetService | `isReady: Bool`, `initialize() async`, `transcribeSegment(samples: [Float], source: AudioSource) async throws -> String`, `cleanup()` |
| `DiarizationEngine.swift` | `@MainActor protocol DiarizationEngine: ObservableObject` | DiarizationService | `isReady`, `initialize() async`, `diarizeOffline(samples:sampleRate:) async throws -> [SpeakerSegment]`, `diarizeOffline(audioURL:) async throws -> [SpeakerSegment]`, `cleanup()` |
| `SpeakerStore.swift` | `protocol SpeakerStore` (no actor) | SpeakerDatabase | `matchSpeaker(embedding:threshold:)`, `addOrUpdateSpeaker(embedding:existingId:)`, `getSpeaker(id:)`, `allSpeakers()`, `setDisplayName(id:name:source:)`, `deleteSpeaker(id:)`, `mergeProfiles(sourceId:into:)`, `mergeProfilesByName()`, `mergeDuplicates()`, `pruneWeakProfiles()`, `resetDisputeCount(id:)`, `findProfilesByName(_:)` |
| `AudioCaptureEngine.swift` | `protocol AudioCaptureEngine: ObservableObject` (NOT @MainActor) | Audio | `isRecording`, `audioLevel`, `recordingDuration`, `systemAudioStatus`, `micAudioFileURL`, `systemAudioFileURL`, `start()`, `stop()`, `onRecordingStart`, `onRecordingComplete`, `createHealthInfo()` |
| `StatsStore.swift` | `protocol StatsStore` | StatsDatabase | `recordTranscription(...)`, `totalRecordingCount()`, `totalDurationSeconds()`, `recordingsForDate(_:)`, `dailyActivity(from:to:)` |
| `TranscriptStorage.swift` | `protocol TranscriptStorage` | TranscriptSaver | All `static` members: `saveTranscript(...)`, `updateSpeakerNames(...)`, `retroactivelyUpdateSpeaker(dbId:newName:)`, `defaultSaveDirectory` |

### 2.3 `UI/` (36 files) — NOT a Core candidate

FloatingPanel (Dynamic-Island pill), Settings window (7 sections), MenuBar stat row, FailedTranscriptionsView. Every file `import SwiftUI` / `import AppKit`. All references to Core are via `ObservableObject` bindings (`Audio`, `Transcription`, `TranscriptionTaskManager`, `FailedTranscriptionManager`, `StatsService`, `TranscriptStore`, `SpeakerDatabase.shared`).

Listed for completeness (14 files touch pipeline types):
```
UI/FloatingPanel/FloatingPanelController.swift
UI/FloatingPanel/FloatingPanelView.swift
UI/FloatingPanel/PillStateManager.swift
UI/FloatingPanel/PillCalloutController.swift
UI/FloatingPanel/Components/{Aurora{Idle,Recording,Processing}View, SavedPillView, SpeakerNamingCard, SpeakerNamingView, TranscriptTrayView, TranscriptRowView, TranscriptDetailView, ContextualErrorBanner, PillCalloutView, PillErrorView, PillOverlayViews, ToastNotificationView, AttentionPromptView, ClipAudioPlayer}
UI/FloatingPanel/Helpers/LawsComponents.swift
UI/Settings/{SettingsContainerView, SettingsTopBar, SettingsWindowController, MigrationOverlayView}
UI/Settings/Sections/{AIServices, FailedTranscriptions, MeetingDetection, Profile, Speakers, Stats, Troubleshooting}Section.swift
UI/Settings/Components/{SettingsButtonStyles, SettingsPathRow, SettingsRadioGroup, SettingsSectionCard, SettingsTextField, SettingsToggleRow}
UI/Settings/Models/SettingsNavigationState.swift
UI/MenuBar/MenuBarStatRow.swift
UI/FailedTranscriptionsView.swift
```

### 2.4 `Design/` (21 files) — NOT a Core candidate

Design tokens, colors, premium components. Pure SwiftUI. Not needed by Draft.

### 2.5 `Onboarding/` (9 files) — NOT a Core candidate

6-step first-run flow. Pure SwiftUI. `OnboardingState.swift` persists via UserDefaults.

### 2.6 `TranscriptedTests/` (47 files)

Uses `@testable import Transcripted` so it accesses internal symbols. The AppDelegate guards on `XCTestConfigurationFilePath` env var to skip full app init during tests. Test groups: `Core/`, `Services/`, `Integration/`, `UI/`, `Helpers/`. These tests are a major safety net for the merge — if Core moves, these tests (or copies) must follow.

---

## 3. TranscriptedCore File List (THE CRITICAL DELIVERABLE)

These are the exact files that belong in a `Sources/TranscriptedCore/` SPM target. The list is based on: (a) files that have no AppKit/SwiftUI/UserNotifications dependency after small surgery, or (b) files that are so central to the STT→diarize→speaker-match→save pipeline that Draft cannot use Transcripted without them.

Every file is listed with:
- **Abs path** relative to Transcripted repo root
- **Purpose** — one line
- **Current visibility** — `internal` is the default for every type in Transcripted (zero `public`/`open` declarations exist anywhere in Core or Services today). Anything marked `nonisolated` or `static` is noted.
- **Target visibility** — what Draft needs (`public`, `public + public init`, or keep `internal` for pipeline-private helpers that SPM-internal callers reach via `@testable import` or by being in the same module). In SPM you can ship everything in one Core target and let Draft `import TranscriptedCore` — only symbols Draft *calls directly* need `public`.
- **Extraction action** — what must change to move this file cleanly.

### 3.1 Tier A — Pure core, trivial to extract (no surgery beyond `public` annotations)

| Abs path | Purpose | Current vis | Target vis | Extraction action |
|---|---|---|---|---|
| `Transcripted/Core/TranscriptionTypes.swift` | `TranscriptionUtterance`, `TranscriptionResult`, `PipelineError`, `SpeakerConfidence`, `IdentifiedSpeaker`, `TranscriptionMetadata`, `SpeakerNamingRequest`, `SpeakerNamingEntry`, `SpeakerNameUpdate` | `internal` | **`public`** (every struct/enum + every stored property + memberwise inits) | Add `public` throughout. `PipelineError` already conforms to `LocalizedError`. |
| `Transcripted/Core/DisplayStatus.swift` | `DisplayStatus`, `TranscriptionTask` | `internal` | **`public`** | Add `public`. Imports `AVFoundation` but only for `TimeInterval` — already transitively from Foundation. |
| `Transcripted/Core/TranscriptMetadataBuilder.swift` | `RecordingHealthInfo` + `CaptureQuality` enum | `internal` | **`public`** | `RecordingHealthInfo.from(audio:systemCapture:)` references `Audio` and `SystemAudioCapture` — those move together. No UI imports. |
| `Transcripted/Core/FailedTranscription.swift` | `FailedTranscription: Identifiable, Codable, Equatable` | `internal` | **`public`** | Pure Codable model. Add `public`. |
| `Transcripted/Core/FilePermissions.swift` | `FileManager.restrictToOwnerOnly(atPath:)` | `internal` | `public` | 10-line file. `public` the extension func. |
| `Transcripted/Core/DateFormattingHelper.swift` | `formatFilename`, `formatFilenamePrecise`, `formatDisplay` | `internal` | `public` | Pure Foundation. |
| `Transcripted/Core/DateParser.swift` | ISO/locale date parsing | `internal` | `public` | Pure Foundation. |
| `Transcripted/Core/TranscriptUtils.swift` | Formatting helpers | `internal` | `public` | Pure Foundation. |
| `Transcripted/Core/Logging/AppLogger.swift` | 10 subsystem loggers, dual output (os.Logger + FileLogger) | `internal`, `@unchecked Sendable` | `public` | Imports `OSLog` only. Portable to SPM. |
| `Transcripted/Core/Logging/FileLogger.swift` | JSONL writer with flock, 2000-entry rolling | `internal`, `@unchecked Sendable` | `internal` (used only by AppLogger) | Keep internal within Core target. Writes to `~/Library/Logs/Transcripted/` — Draft may want to rename the subdir (see §11). |
| `Transcripted/Core/ModelDownloadService.swift` | HF mirror fallback, retry, `DownloadErrorKind`, `ModelDownloadError`, `withRetry {}`, `classifyError(_:)`, `checkNetworkReachability()` | `internal` | **`public`** (enum + all static methods, `DownloadErrorKind`, `ModelDownloadError`) | Pure Foundation/Network/CryptoKit. No UI refs. Used by Parakeet+Diarization services. |
| `Transcripted/Core/RecordingValidator.swift` | Disk/permission/path-safety pre-checks | `internal` static class | `public` | Pure Foundation. |
| `Transcripted/Services/SpeakerProfile.swift` | `SpeakerProfile`, `SpeakerMatchResult`, `NameSource` | `internal` | **`public`** | Pure data. |
| `Transcripted/Services/AudioResampler.swift` | `loadAndResample(url:targetRate:)`, `extractSlice(...)` | `internal` enum (static) | **`public`** | Uses AVFoundation only. Critical for Draft pipeline entry points. |
| `Transcripted/Services/EmbeddingClusterer.swift` | 3-stage post-process | `internal` enum (static) | **`public`** | Uses Accelerate (vDSP). Already nonisolated. |
| `Transcripted/Services/SpeakerClipExtractor.swift` | Per-speaker WAV clips for naming UI | `internal` enum (static), `struct ClipResult` | **`public`** | Uses AVFoundation only. |
| `Transcripted/Services/SpeakerEmbeddingMatcher.swift` | vDSP cosine similarity | `internal` | **`public`** | Pure Accelerate. |
| `Transcripted/Services/SpeakerProfileMerger.swift` | Name variants, merge/prune, fuzzy lookup | `internal` | **`public`** | Pure Foundation. |
| `Transcripted/Services/Protocols/SpeechToTextEngine.swift` | Protocol | `internal`, @MainActor | **`public`** | Depends on `FluidAudio.AudioSource` — Core target must link FluidAudio. |
| `Transcripted/Services/Protocols/DiarizationEngine.swift` | Protocol | `internal`, @MainActor | **`public`** | Depends on `SpeakerSegment` (Services). |
| `Transcripted/Services/Protocols/SpeakerStore.swift` | Protocol | `internal` | **`public`** | Depends on `SpeakerProfile`, `SpeakerMatchResult`. |
| `Transcripted/Services/Protocols/StatsStore.swift` | Protocol | `internal` | **`public`** | Depends on `RecordingMetadata`, `DailyActivity`. |
| `Transcripted/Services/Protocols/TranscriptStorage.swift` | Protocol (all static requirements) | `internal` | **`public`** | Depends on `TranscriptionResult`, `SpeakerMapping`, `RecordingHealthInfo`, `SpeakerNameUpdate`. |
| `Transcripted/Services/Protocols/AudioCaptureEngine.swift` | Protocol (NOT @MainActor) | `internal` | **`public`** | Depends on `SystemAudioStatus` (from Audio.swift) and `RecordingHealthInfo`. |

### 3.2 Tier B — Core with minor surgery required

| Abs path | Purpose | Current vis | Target vis | Extraction action |
|---|---|---|---|---|
| `Transcripted/Core/AppServices.swift` | DI container struct | `internal` @MainActor | **`public`** | Currently holds concrete types (`ParakeetService`, `DiarizationService`, `SpeakerDatabase`). Switch to protocol types (`any SpeechToTextEngine`, `any DiarizationEngine`, `any SpeakerStore`) **per its own TODO comment** to let Draft inject alternate implementations. |
| `Transcripted/Core/Transcription.swift` | `class Transcription: ObservableObject` (@MainActor), `struct SpeakerMapping` | `internal` | **`public`** | Both `SpeakerMapping` (public) and `Transcription`. `SpeakerMapping` is referenced across TranscriptSaver + TranscriptFormatter. |
| `Transcripted/Core/TranscriptionPipeline.swift` | `extension Transcription` with `transcribeMultichannel(micURL:systemURL:onProgress:)` + `detectSpeechSegments`, `mergeConsecutiveUtterances`, `embeddingWeight` | `internal` nonisolated | **`public`** on `transcribeMultichannel`; static helpers can stay internal if Core-internal callers use them | The 5-step pipeline lives here. 597 LOC. Uses AVFoundation + Accelerate. No UI deps. |
| `Transcripted/Core/SpeakerMatchingService.swift` | `extension Transcription` with `matchAgainstProfiles`, `computeMeanEmbedding`, `cosineSimilarityStatic` | `internal` nonisolated static | `public` (only if Draft calls directly; likely stays internal) | Pure Accelerate. |
| `Transcripted/Core/TranscriptionTaskManager.swift` | Task queue, @Published progress, retry logic | `internal` @MainActor | **`public`** | **Imports `UserNotifications`** and calls `UNUserNotificationCenter` for failure notifications (`sendFailureNotification`) and permission requests (`requestNotificationPermission`). **Surgery**: extract notification-sending into a protocol (`FailureNotifier`) or a closure injected at init, so Core has no UserNotifications dependency. Draft can wire its own notifier. |
| `Transcripted/Core/TranscriptionPipelineRunner.swift` | `extension TranscriptionTaskManager.transcribeWithSpeakerIdentification + transcribeMultichannelPipeline` | `internal` nonisolated | **`public`** on top-level method | Imports `UserNotifications` but doesn't use it directly — import can be removed. Otherwise pure pipeline glue. |
| `Transcripted/Core/SpeakerNamingCoordinator.swift` | `extension TranscriptionTaskManager.handleNamingComplete(...)` | `internal` @MainActor | `public` | No UI imports. Calls into SpeakerDatabase + TranscriptSaver. |
| `Transcripted/Core/TranscriptSaver.swift` | `class TranscriptSaver` static save methods, `defaultSaveDirectory`, `fileUpdateQueue` | `internal` | **`public`** | **Imports `UserNotifications`** and shows save notifications from `showSaveNotification(fileURL:)`. **Surgery**: hoist `showSaveNotification` out or accept an injected notifier. Without surgery, Core must link UserNotifications — acceptable on Apple platforms but makes Core non-portable. |
| `Transcripted/Core/TranscriptFormatter.swift` | `extension TranscriptSaver` YAML/markdown formatting | `internal` static | `public` on `formatTranscriptMarkdown`, `escapeYAML` | Pure Foundation. |
| `Transcripted/Core/RetroactiveSpeakerUpdater.swift` | `extension TranscriptSaver.retroactivelyUpdateSpeaker(dbId:newName:)` | `internal` static | **`public`** | Pure Foundation. |
| `Transcripted/Core/TranscriptScanner.swift` | Save-dir scanner + migration | `internal` | `public` | Pure Foundation. |
| `Transcripted/Core/AgentOutput.swift` | JSON sidecar + index writer, all `Agent*` Codable structs | `internal` enum + structs | **`public`** (at least the writer funcs; structs can stay internal unless Draft serializes them itself) | Pure Foundation + Codable. 357 LOC. |
| `Transcripted/Core/StatsDatabase.swift` | SQLite stats DB on serial queue | `internal` final class | **`public`** | Imports `SQLite3` C. `~/Documents/Transcripted/stats.sqlite` path is hard-coded (matches SpeakerDatabase pattern). |
| `Transcripted/Core/StatsDatabaseModels.swift` | `RecordingMetadata`, `DailyActivity` | `internal` | **`public`** | Pure data. |
| `Transcripted/Core/StatsDatabaseQueries.swift` | `extension StatsDatabase` | `internal` | `public` on methods | Pure SQL. |
| `Transcripted/Core/StatsService.swift` | Published dashboard aggregator, `StatsService.shared` | `internal` @MainActor singleton | **`public`** | Pure Foundation+Combine. |
| `Transcripted/Core/FailedTranscriptionManager.swift` | Persistent failed-queue | `internal` @MainActor | **`public`** | Pure Foundation+Combine. Path is hard-coded `~/Documents/Transcripted/failed_transcriptions.json`. |
| `Transcripted/Services/ParakeetService.swift` | Parakeet TDT V3 wrapper | `internal` @MainActor | **`public`** | **Bundle.main.resourcePath lookup** — blocker §11. Remove or let caller pass a bundle URL. |
| `Transcripted/Services/DiarizationService.swift` | Dual-pipeline diarizer, `SpeakerSegment`, `DiarizationModelState` | `internal` @MainActor | **`public`** | Same **Bundle.main.resourcePath** blocker. Champion offline config embedded — Draft inherits these DER-tuned values. |
| `Transcripted/Services/SpeakerDatabase.swift` | SQLite speaker DB, singleton `.shared` | `internal` final class | **`public`** | Pure SQLite3. Path hard-coded to `~/Documents/Transcripted/speakers.sqlite` — Draft may want an injectable base dir (see §11). |

### 3.3 Tier C — Audio capture stack (NOT @MainActor)

The three Audio.* files are tightly coupled (all `extension Audio`). They MUST move as a unit or stay out entirely. Draft needs them if Draft wants end-to-end recording; if Draft has its own capture layer, these can stay in the Transcripted app target (which is the more likely call — see my hand-off note to draft-mapper).

| Abs path | Purpose | Current vis | Target vis | Extraction action |
|---|---|---|---|---|
| `Transcripted/Core/Audio.swift` | `class Audio: ObservableObject`, `enum SystemAudioStatus`, `struct AudioGap` | `internal` | `public` | **Imports AppKit** (for `NSWorkspace.willSleep/didWake` notifications). **Imports Combine**. Not @MainActor by design. 618 LOC. If Draft has its own capture, DO NOT extract — it's load-bearing for the Audio-extension files. |
| `Transcripted/Core/AudioFileManager.swift` | `extension Audio` WAV creation, buffer copy | `internal` | `public` on entry points | **Imports AppKit**. Writes to `~/Documents/` via `FileManager.urls(for:.documentDirectory)`. |
| `Transcripted/Core/AudioDeviceRecovery.swift` | `extension Audio` watchdog + sleep/wake recovery | `internal` | `public` on entry points | **Imports AppKit**. |
| `Transcripted/Core/AudioLevelMonitor.swift` | `extension Audio` RMS metering | `internal` | `public` on entry points | Foundation only. |
| `Transcripted/Core/SystemAudioCapture.swift` | `class SystemAudioCapture: ObservableObject` | `internal` | `public` | macOS 14.2+ CoreAudio process-tap wrapper. |
| `Transcripted/Core/SystemAudioProcessTap.swift` | `extension SystemAudioCapture` aggregate-device setup | `internal` | internal | Pure CoreAudio. |
| `Transcripted/Core/SystemAudioBufferWriter.swift` | `extension SystemAudioCapture` buffer stats + recovery listener | `internal` | internal | Pure CoreAudio. |
| `Transcripted/Core/CoreAudioUtils.swift` | `extension AudioObjectID`, `extension String` (retroactive LocalizedError), `extension AudioObjectPropertyAddress` | `internal` | `public` on the extensions | Helpers used by SystemAudioCapture. |

### 3.4 Tier D — Ambiguous (probably NOT Core, but useful services)

| Abs path | Purpose | Verdict |
|---|---|---|
| `Transcripted/Services/MeetingDetector.swift` | Zoom/Teams/Webex/FaceTime auto-start detector | **NOT Core**. Imports AppKit, polls `NSWorkspace.shared.runningApplications`. Only makes sense in a foreground agent. Leave in the Transcripted app target. |
| `Transcripted/Core/TranscriptStore.swift` | Imports SwiftUI, `@Published var transcripts` for tray UI | **NOT Core**. Pure UI adapter. Its value-types (`SpeakerInfo`, `TranscriptSummary`, `TranscriptLine`) *could* be hoisted into Core if Draft wants them — probably not needed. |
| `Transcripted/Core/TranscriptExporter.swift` | NSSavePanel .md/.txt export | **NOT Core**. AppKit UI. |
| `Transcripted/Core/DiagnosticExporter.swift` | Diagnostic bundle export | **NOT Core**. AppKit + reads `Bundle.main.infoDictionary`. |
| `Transcripted/Core/Clipboard.swift` | NSPasteboard wrapper | **NOT Core**. AppKit. |
| `Transcripted/Core/SystemSettingsHelper.swift` | Opens System Settings panes | **NOT Core**. AppKit. |
| `Transcripted/Core/HotkeyManager.swift` et al. | All AppDelegate extensions | **NOT Core**. AppKit, @MainActor coordinators. |
| `Transcripted/Core/MenuBarManager.swift` | " | " |
| `Transcripted/Core/NotificationCoordinator.swift` | " | " |
| `Transcripted/Core/WindowCoordinator.swift` | " | " |
| `Transcripted/Core/RecordingCoordinator.swift` | " | " |
| `Transcripted/Core/AppDelegateDebug.swift` | " | " |

### 3.5 TranscriptedCore final count

- **Tier A (no-surgery)**: 24 files (16 Core + 5 Services + 6 protocols, minus SpeakerProfile/AudioResampler which are listed twice — corrected count: 22 files). Re-counting:
  - Core: `TranscriptionTypes`, `DisplayStatus`, `TranscriptMetadataBuilder`, `FailedTranscription`, `FilePermissions`, `DateFormattingHelper`, `DateParser`, `TranscriptUtils`, `Logging/AppLogger`, `Logging/FileLogger`, `ModelDownloadService`, `RecordingValidator` → **12**
  - Services: `SpeakerProfile`, `AudioResampler`, `EmbeddingClusterer`, `SpeakerClipExtractor`, `SpeakerEmbeddingMatcher`, `SpeakerProfileMerger` → **6**
  - Protocols: **6**
  - **Subtotal Tier A: 24 files**
- **Tier B (minor surgery — add `public`, remove UserNotifications deps, parameterize `Bundle.main` lookups)**: `AppServices`, `Transcription`, `TranscriptionPipeline`, `SpeakerMatchingService`, `TranscriptionTaskManager`, `TranscriptionPipelineRunner`, `SpeakerNamingCoordinator`, `TranscriptSaver`, `TranscriptFormatter`, `RetroactiveSpeakerUpdater`, `TranscriptScanner`, `AgentOutput`, `StatsDatabase`, `StatsDatabaseModels`, `StatsDatabaseQueries`, `StatsService`, `FailedTranscriptionManager`, `ParakeetService`, `DiarizationService`, `SpeakerDatabase` → **20 files**
- **Tier C (optional: audio capture)**: 8 files if Draft wants them.

**Minimum viable TranscriptedCore (Tiers A+B): 44 files, ~10,500 LOC.**
**Full TranscriptedCore including capture (Tiers A+B+C): 52 files, ~13,500 LOC.**

---

## 4. Audio Capture

**Dual-stream**, concurrent mic + system audio, independent WAV files, 0o600 perms immediately after creation.

- **Mic path**: `Audio.startAudioCapture()` → `AVAudioEngine` + `inputNode.installTap(onBus:0, bufferSize:4096, format: hardwareFormat)`. Uses `inputNode.inputFormat(forBus: 1)` to get ACTUAL hardware format (not the converter format from bus 0) — critical for Bluetooth. Hardware sample rate (can be 44.1/48 kHz), stereo-to-mono conversion stored in `monoOutputFormat` (thread-safe via `formatLock`).
- **System audio path**: `SystemAudioCapture` (macOS 14.2+) uses CoreAudio process taps via `CATapDescription` + aggregate device. 2-step lifecycle: `prepare()` (creates aggregate device, resolves format, gets `tapStreamDescription`) → `start(callback:)` (installs I/O proc). File MUST be created before `start()` — creating files inside the audio callback causes `HALC_ProxyIOContext::IOWorkLoop` overloads.
- **File paths**: Both files under `~/Documents/meeting_<YYYY-MM-DD_HH-mm-ss>_{mic,system}.wav`. Linear PCM Float32. After recording, `originalMicAudioFileURL` is used (not potentially-overwritten recovery segments).
- **VAD**: Energy-based in `TranscriptionPipeline.detectSpeechSegments(samples:sampleRate:)`: 25 ms frames, 10 ms hop, RMS threshold 0.01, min silence gap 400 ms, min segment 0.5 s. vDSP-accelerated. Applied to MIC audio only (system audio is segmented by diarization). Also `Audio.swift` has a separate `isSilent` flag (audioLevel < 0.02) for UI "Still recording?" prompts.
- **Silence detection during recording** (AudioLevelMonitor): 15-element rolling buffers, `silenceThreshold: Float = 0.02`.
- **Recovery mechanisms** (AudioDeviceRecovery):
  - Watchdog timer 3–5 s → `recoverFromDeviceChange()`, max 5 attempts, 5 s cooldown between recoveries.
  - Uses `CACurrentMediaTime()` (monotonic) to avoid false triggers post sleep/wake.
  - Sleep/wake via `NSWorkspace.willSleepNotification` / `didWakeNotification` → 500 ms HAL stabilization wait → proactive recovery.
  - 10 consecutive write errors → stop recording.
  - System audio >10 s silence → `.silent` status; >10 min → `.failed`.
  - Recovery segments get 0o600 on creation.
- **Health tracking**: `RecordingGaps: [AudioGap]` (lock-protected), `deviceSwitchCount` (lock-protected), `systemCapture.bufferSuccessRate` → feeds `RecordingHealthInfo.CaptureQuality` (excellent ≥0.98, good 0.90–0.97, fair 0.80–0.89, degraded <0.80). Captured into YAML frontmatter.
- **Published properties** (UI bindings): `isRecording`, `isMonitoring`, `audioLevel`, `recordingDuration`, `audioLevelHistory [15]`, `systemAudioLevelHistory [15]`, `error`, `systemAudioStatus`, `silenceDuration`, `isSilent`, `micAudioFileURL`, `systemAudioFileURL`, `systemAudioFailed`.
- **Monitoring mode**: `startMonitoring()` / `stopMonitoring()` — lightweight level metering without file recording, used by `MeetingDetector`. Auto-stops when `start()` is called for full recording.

---

## 5. STT (Parakeet TDT V3)

- **Wrapper**: `Services/ParakeetService.swift` (117 LOC, @MainActor, `class ParakeetService: ObservableObject`).
- **Model state**: `enum ParakeetModelState: Equatable { notLoaded, loading, ready, failed(String) }` as `@Published`.
- **Backing manager**: `FluidAudio.AsrManager` (from libFluidAudioAll.a) + `FluidAudio.AsrModels` with version `.v3`.
- **Initialization path**:
  1. `bundledModelsPath()` → `Bundle.main.resourcePath + /parakeet-models/parakeet-tdt-0.6b-v3-coreml/` checked for `Encoder.mlmodelc`. If present, `AsrModels.load(from: bundlePath, version: .v3)`.
  2. Otherwise `ModelDownloadService.withRetry { try await AsrModels.downloadAndLoad(version: .v3) }`. ~600 MB download from HuggingFace (`huggingface.co` → `hf-mirror.com` fallback).
  3. Create `AsrManager(config: .default)` → `manager.initialize(models:)` → `modelState = .ready`.
- **Inference APIs**:
  - `transcribe(audioURL: URL) async throws -> String` (nonisolated): loads + resamples to 16 kHz via `AudioResampler.loadAndResample`, calls `manager.transcribe(samples, source: .microphone)`. Returns trimmed `result.text`.
  - `transcribeSegment(samples: [Float], source: AudioSource = .system) async throws -> String` (nonisolated): called per diarized segment. `source` is `FluidAudio.AudioSource` (mic vs system).
  - Both throw `PipelineError.modelNotLoaded(model: "Parakeet")` if `asrManager` is nil or `!manager.isAvailable`.
- **Input type**: 16 kHz mono Float32 samples.
- **Output type**: plain `String` (FluidAudio's result struct has `text` + `confidence` — only `text` surfaced; confidence logged at info level but not carried forward).
- **Cleanup**: `async cleanup()` → `asrManager?.cleanup()` + state reset.
- **Batch only** — no live streaming (Transcripted records first, then transcribes).

---

## 6. Diarization (Sortformer + PyAnnote)

- **Wrapper**: `Services/DiarizationService.swift` (271 LOC, @MainActor, `class DiarizationService: ObservableObject`). Two parallel pipelines inside one service.
- **Streaming pipeline**: `FluidAudio.DiarizerManager` + `DiarizerModels` (Sortformer). T×4 output matrix, up to 4 speakers. Used only for "future real-time preview" per code comment — currently not on the main transcription path.
- **Offline pipeline (PRIMARY)**: `FluidAudio.OfflineDiarizerManager` + `OfflineDiarizerModels` — PyAnnote segmentation + WeSpeaker 256-dim embeddings + VBx clustering. Unlimited speakers, ~15 % DER on VoxConverse.
- **Champion offline config** (hard-coded in `DiarizationService.initializeOffline()`, derived from a DER grid-search over 16 Zoom meetings, key win: `Fa 0.07 → 0.25`):
  ```swift
  OfflineDiarizerConfig(
      clusteringThreshold: 0.6,
      Fa: 0.25, Fb: 0.63,
      windowDuration: 10.0,
      segmentationStepRatio: 0.266,
      embeddingBatchSize: 32,
      embeddingExcludeOverlap: true,
      minSegmentDuration: 1.1821,
      minGapDuration: 0.2874,
      exclusiveSegments: true,
      speechOnsetThreshold: 0.4472,
      speechOffsetThreshold: 0.4472,
      segmentationMinDurationOn: 0.0,
      segmentationMinDurationOff: 0.2738,
      maxVBxIterations: 24,
      convergenceTolerance: 0.0001
  ).withSpeakers(min: 3, max: 11)
  ```
- **`SpeakerSegment` type** (the unit passed between diarizer and matcher):
  ```swift
  struct SpeakerSegment {
      let speakerId: Int          // unlimited (PyAnnote) or 0-3 (Sortformer)
      let startTime: Double       // seconds
      let endTime: Double
      let embedding: [Float]?     // 256-dim WeSpeaker, nil if below quality
      let qualityScore: Float     // 0-1
      var duration: Double { endTime - startTime }
  }
  ```
- **Offline model load**: `bundledModelsPath("offline-diarizer-models")` → `Bundle.main.resourcePath`; fallback to `ModelDownloadService.withRetry { try await manager.prepareModels() }`.
- **Speaker-ID parsing**: `speakerIdFromString(_:)` handles `"speaker_0"` (Sortformer), `"S0"` (PyAnnote offline), bare `"0"` (fallback). Logs and returns 0 on parse failure.
- **Public entry points**:
  - `diarizeOffline(samples: [Float], sampleRate: Int = 16000) async throws -> [SpeakerSegment]` (nonisolated) — primary.
  - `diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment]` (nonisolated) — loads + resamples via AudioResampler.
  - `diarizeStreaming(samples:sampleRate:)` / `diarizeStreaming(audioURL:)` — unused in production today.

---

## 7. Speaker Recognition (Familiar Voices)

Three-layer stack: in-memory embeddings → on-disk SQLite profiles → post-process clustering.

### 7.1 SpeakerDatabase (`Services/SpeakerDatabase.swift` + `SpeakerEmbeddingMatcher.swift` + `SpeakerProfileMerger.swift`)

- **Storage**: `~/Documents/Transcripted/speakers.sqlite`. Singleton `.shared`. Testable `init(path:)` (used by tests via `@testable import`).
- **Queue**: dedicated `DispatchQueue(label: "com.transcripted.speakerdb", qos: .utility)`. Not @MainActor.
- **Safety**: WAL mode, `busy_timeout = 5000`, `synchronous = NORMAL`, 0o600 via `restrictToOwnerOnly` immediately after open. `PRAGMA quick_check` corruption detection on open → automatic backup-and-recreate if corrupt. Silently returns in-memory dummy profiles if DB open fails (logs CRITICAL).
- **Schema**:
  ```sql
  CREATE TABLE speakers (
      id TEXT PRIMARY KEY,          -- UUID string
      display_name TEXT,
      name_source TEXT DEFAULT NULL, -- "user_manual" (see NameSource.userManual)
      embedding BLOB NOT NULL,      -- 256-dim float32 binary
      first_seen TEXT NOT NULL,     -- ISO8601
      last_seen TEXT NOT NULL,
      call_count INTEGER DEFAULT 1,
      confidence REAL DEFAULT 0.5,
      dispute_count INTEGER DEFAULT 0,
      created_at TEXT DEFAULT CURRENT_TIMESTAMP
  );
  ```
- **Key API (conformance to `SpeakerStore` protocol is aspirational — concrete type today)**:
  - `matchSpeaker(embedding: [Float], threshold: Double = 0.6) -> SpeakerMatchResult?` — vDSP cosine similarity (in `SpeakerEmbeddingMatcher.swift`).
  - `addOrUpdateSpeaker(embedding: [Float], existingId: UUID? = nil) -> SpeakerProfile` — NEW: confidence 0.5, callCount 1. UPDATE: EMA blend alpha=0.15 (slow — takes 6-7 updates to shift), confidence += 0.1 (capped at 1.0), callCount += 1.
  - `setDisplayName(id:name:source:)` — in SpeakerProfileMerger.
  - `allSpeakers()`, `getSpeaker(id:)`, `deleteSpeaker(id:)`, `resetDisputeCount(id:)`.
  - `findProfilesByName(_ name: String)` — fuzzy with hardcoded name variants (mike/michael/mikey, nate/nathan/nathaniel, dave/david, alex/alexander/alexandra, dan/daniel/danny, matt/matthew, chris/christopher, nick/nicholas, rob/robert/bob, +15 more) + substring matching.
  - `mergeProfiles(sourceId:into:)` — weighted blend by callCount in atomic txn.
  - `mergeProfilesByName()` — merge profiles that ended up with the same display name.
  - `mergeDuplicates()` — proactive de-dupe.
  - `pruneWeakProfiles()` — deletes unnamed AND callCount ≤ 1 AND confidence ≤ 0.5 AND age > 1 hr.
  - `getColumnNames(tableName:)` — PRAGMA `table_info` with compile-time allowlist validation (SQL injection guard).

### 7.2 Embedding type

```swift
struct SpeakerProfile: Identifiable {
    let id: UUID
    var displayName: String?, nameSource: String?
    var embedding: [Float]        // 256-dim average
    var firstSeen: Date, lastSeen: Date, callCount: Int
    var confidence: Double        // 0.5–1.0
    var disputeCount: Int
}
struct SpeakerMatchResult { let profile: SpeakerProfile; let similarity: Double }
```

### 7.3 Match logic and thresholds

- **`matchSpeaker()` default**: 0.60.
- **Adaptive threshold in pipeline** (`TranscriptionPipeline.swift`, by # of embedded segments for a diarizer speaker): 1 seg → 0.85, 2–3 segs → 0.78, 4+ segs → 0.70.
- **EmbeddingClusterer thresholds**: pairwise merge 0.85 (or 0.78 when pipeline passes explicit override), small-cluster absorption 0.72, micro-cluster (<10 s) absorption 0.62, DB-informed split 0.62.
- **Mic-contamination gating** (in `TranscriptionPipeline`): embedding weight tiers by mic-active fraction during system segment: >0.8 = excluded, 0.5–0.8 = 0.2, 0.3–0.5 = 0.5, <0.3 = 1.0. Uses 100 ms mic energy frames vs threshold 0.02.
- **Ghost speaker handling**: speakers whose segments were all filtered (low quality or mic-contaminated) get a single best-effort embedding as fallback for UUID assignment, then force-merged into the closest non-ghost speaker by cosine similarity.
- **Cross-cluster merge**: speakers that matched the same DB profile are unified under the speaker ID with the most segments via `speakerIdRemap`.

### 7.4 EmbeddingClusterer 3-stage post-process (`Services/EmbeddingClusterer.swift`)

- Stage 1 — Pairwise merge (skipped if pipeline passes `pairwiseMergeThreshold` param; PyAnnote VBx already handles base case): Union-find graph, merge at mean similarity ≥ 0.85 (or caller override).
- Stage 2 — Small cluster absorption: Micro-clusters <10 s absorb at 0.62 (above codec similarity range); clusters 10–30 s absorb at 0.72. Clusters with ≥3 segments are protected from being absorbed.
- Stage 3 — DB-informed split: per-segment match against existing profiles at 0.62, min 8 segments per profile to claim ownership. Splits clusters where diarizer merged two speakers.

---

## 8. Storage Writers (Transcript → Markdown + YAML + JSON Sidecar)

All writes serialized through `TranscriptSaver.fileUpdateQueue = DispatchQueue(label: "com.transcripted.fileupdate", qos: .utility)`.

### 8.1 File layout under `~/Documents/Transcripted/`

```
Call_<YYYY-MM-DD_HH-mm-ss>.md              # Markdown + YAML frontmatter (primary)
Call_<YYYY-MM-DD_HH-mm-ss>.json            # AgentOutput JSON sidecar
AGENT.md                                    # Written once by AgentOutput.writeAgentReadme
index.json                                  # Rebuilt by AgentOutput.writeIndex on every save
speakers.sqlite (+ -wal, -shm)              # SpeakerDatabase
stats.sqlite (+ -wal, -shm)                 # StatsDatabase
failed_transcriptions.json                  # FailedTranscriptionManager
speaker_clips/<speakerId>.wav               # SpeakerClipExtractor persistent clips
meeting_<ts>_mic.wav                        # Ephemeral — deleted post-naming
meeting_<ts>_system.wav                     # Ephemeral — deleted post-naming
```
- All text files written with 0o600 immediately after creation via `FileManager.restrictToOwnerOnly`.
- Collision handling: `Call_<ts>.md`, `Call_<ts>_1.md`, `Call_<ts>_2.md`, …
- Disk check: `TranscriptSaver.saveTranscript` rejects if free space < 50 MB.
- Custom save location via `UserDefaults.standard.string(forKey: "transcriptSaveLocation")` validated by `RecordingValidator.validateSavePath` (rejects symlinks, `..`, `/System`, `/Library`, `/usr`).

### 8.2 YAML frontmatter schema (emitted by `TranscriptFormatter.formatTranscriptMarkdown`)

```yaml
---
date: 2024-01-15                            # YYYY-MM-DD
time: 14:30:00                              # HH:mm:ss
duration: "47:32"                           # mm:ss quoted
processing_time: "120.5s"
transcription_engine: parakeet_local
diarization_engine: pyannote_offline
sources: [mic, system_audio]
mic_utterances: 42
system_utterances: 156
mic_speakers: 1
system_speakers: 4
total_word_count: 8291
capture_quality: excellent|good|fair|degraded
audio_gaps: 0
device_switches: 0
speakers:
  - id: "system_0"
    db_id: "<uuid>"
    name: "Alice"
    confidence: high|medium
tags: [transcripted, meeting, speaker/alice]  # only if Obsidian integration enabled
---
```
- YAML escaping via `escapeYAML(_:)`: backslash, quote, `\n`, `\r`, `\t` (critical — raw `\n` in a double-quoted scalar breaks YAML parsing and lets subsequent text become new keys).

### 8.3 Markdown body structure

```markdown
# Call Recording - <formatted date>

**Duration:** mm:ss
**Words:** <count>
**Date:** <display-format date>

---

<utterance text with [timestamp] **Speaker Name**: ... lines>

---

*Recorded with Transcripted*
```
- Source label transform: `"System Audio"` → `"SysAudio"` for compactness.

### 8.4 Agent JSON sidecar (written from inside `TranscriptSaver.saveTranscript` via `AgentOutput.writeTranscriptJSON`)

`struct AgentTranscript { version; recording: AgentRecording; speakers: [AgentSpeaker]; utterances: [AgentUtterance] }` with `snake_case` CodingKeys throughout. Same dir writes:
- Per-transcript: `<stem>.json`.
- `index.json`: `AgentIndex { version, updated_at, transcript_count, transcripts: [AgentIndexEntry], known_speakers: [AgentKnownSpeaker] }`.
- `AGENT.md`: written once by `AgentOutput.writeAgentReadme` — explains the sidecar format to an AI agent browsing the directory.

### 8.5 StatsDatabase write

`TranscriptSaver.saveTranscript` dispatches a `Task { @MainActor in }` after saving: `StatsService.createMetadata(from:transcriptPath:title:)` → `StatsService.shared.recordSession(metadata)` → `StatsDatabase` insert.

Schema:
```sql
CREATE TABLE recordings (
    id TEXT PRIMARY KEY, date TEXT, time TEXT, duration_seconds INT,
    word_count INT, speaker_count INT, processing_time_ms INT,
    transcript_path TEXT, title TEXT, created_at TEXT
);
CREATE TABLE daily_activity (
    date TEXT PRIMARY KEY, recording_count INT, total_duration_seconds INT,
    action_items_count INT, updated_at TEXT
);
```
WAL, busy_timeout 5000, NORMAL sync, 0o600.

### 8.6 Retroactive speaker renaming

`RetroactiveSpeakerUpdater.retroactivelyUpdateSpeaker(dbId:newName:)` scans the save dir for `.md` files matching `db_id: "<uuid>"`, extracts the old name from the adjacent `name:` line, and replaces all occurrences in YAML frontmatter + transcript body. Serialized through `fileUpdateQueue.sync`.

---

## 9. Sub-packages in `Tools/`

Critical finding: **all three Tools packages are standalone SPM packages with ZERO compile-time dependency on the main `Transcripted` app target.** None of them `import` any app-defined module. This means extraction of TranscriptedCore will NOT affect the Tools packages — they can remain exactly as-is. The flip side is that they don't benefit from Core either: each one currently duplicates any logic it needs.

### 9.1 `Tools/TranscriptedCLI/` — standalone diarizer CLI

- **Package**: swift-tools-version 5.9, platform macOS 14, one executable target `transcripted-cli`.
- **Dependencies**: `swift-argument-parser 1.3.0` only (SPM). Plus **unsafe flags** linking the prebuilt FluidAudio: `-I ../../fluidaudio-modules`, `-I .../FastClusterWrapper`, `-I .../MachTaskSelfWrapper`, `-I .../yyjson`, `-L ../../Tools/TranscriptedCLI`, `-lFluidAudioCLI`, `-lc++`. Frameworks: Metal, MetalKit, Accelerate, CoreML, CoreAudio, AVFoundation, Network.
- **Source files (5)**: `TranscriptedCLI.swift` (@main ArgumentParser root), `DiarizeCommand.swift` (single file), `BatchCommand.swift` (directory), `ConfigLoader.swift` (JSON → `OfflineDiarizerConfig`), `RTTMWriter.swift` (RTTM + JSON output).
- **Imports**: only `ArgumentParser`, `Foundation`, `FluidAudio`. **No app imports.**
- **What it does**: offline diarization CLI that takes WAV files, runs FluidAudio's `OfflineDiarizerManager` directly, writes RTTM/JSON. Parallel to `DiarizationService` but independent.
- **What it would lose if Core were extracted**: nothing — it doesn't use Core today. **It would GAIN** the ability to reuse `DiarizationService`'s champion config, `EmbeddingClusterer` post-processing, `AudioResampler` — if Core were extracted and it were updated to depend on it. (Optional follow-up, not merge-critical.)
- **Note**: links a *different* static lib (`libFluidAudioCLI`) than the main app's `libFluidAudioAll.a`. The CLI's libFluidAudioCLI file does not exist in the repo today — likely built on demand or expected to be present locally. **Flag for draft-mapper.**

### 9.2 `Tools/TranscriptedMCP/` — MCP server for Claude Desktop

- **Package**: swift-tools-version 5.9, platform macOS 14, `transcripted-mcp` executable + `TranscriptedMCPTests` target. Depends on `modelcontextprotocol/swift-sdk` exact 0.12.0. `linkedLibrary("sqlite3")`.
- **Source files (7)**: `Main.swift` (@main, StdioTransport), `ToolHandlers.swift` (5 tools), `TranscriptIndex.swift` (SQLite FTS5 index), `TranscriptLoader.swift` (.md parser), `Models.swift` (all Codable structs — **its own copy of `AgentTranscript` et al.**, not shared with the app), `NameVariants.swift` (**duplicates `SpeakerProfileMerger`'s name-variant table**), `FileWatcher.swift` (DispatchSource directory watcher).
- **Tests (4)**: `TranscriptIndexTests`, `TranscriptLoaderTests`, `NameVariantsTests`, `TestHelpers`.
- **What it does**: exposes 5 read-only MCP tools — `list_meetings`, `read_meeting`, `search`, `who_is`, `recap` — backed by a SQLite FTS5 index rebuilt from `~/Documents/Transcripted/*.json` sidecars. FileWatcher does incremental updates.
- **Imports**: `MCP` (swift-sdk), `Foundation`, `SQLite3`. **No app imports.**
- **What it would lose if Core were extracted**: nothing — it reads JSON sidecars off disk only. **It would GAIN**: it could import Core and drop its duplicate `Models.swift` (shared `AgentTranscript`) and `NameVariants.swift` (shared with `SpeakerProfileMerger`). Optional post-merge cleanup.
- **Index DB**: `~/Documents/Transcripted/mcp_index.sqlite`, auto-recreated on `quick_check` failure.

### 9.3 `Tools/TranscriptedQA/` — on-disk artifact validator CLI

- **Package**: swift-tools-version 5.9, macOS 14, `transcripted-qa` executable. Depends on `swift-argument-parser 1.3.0`. `linkedLibrary("sqlite3")`.
- **Source files (23)**:
  - Entry: `TranscriptedQA.swift` (@main ArgumentParser).
  - `Commands/` (10): `CheckHealth`, `ValidateAll`, `ValidateArtifacts`, `ValidateDatabase`, `ValidateIndex`, `ValidateLogs`, `ValidateTranscripts`, `GenerateFixtures`, `RoundTrip`, `StressTest`.
  - `Generators/TestDataGenerator.swift`.
  - `Validators/` (7): `HealthChecker`, `IndexValidator`, `JSONSidecarValidator`, `LogValidator`, `SpeakerDBValidator`, `StatsDBValidator`, `TranscriptValidator`.
  - `Utilities/`: `SQLiteReader`, `YAMLParser`.
  - `Models/ValidationResult.swift`.
- **Imports**: `ArgumentParser`, `Foundation`, `SQLite3`. **No app imports.** Re-implements YAML parsing, SQLite reading, JSON-sidecar schema validation independently.
- **What it does**: validates on-disk artifacts (transcript YAML, sidecar JSON, SpeakerDB, StatsDB, logs, mcp_index, speaker_clips) without touching the app. Generates fixtures and stress-tests validators.
- **What it would lose if Core were extracted**: nothing — its whole point is to validate artifacts from the outside without sharing app code.

### 9.4 Summary: Tools are safe during extraction

- None of the three Tools packages `import` any type from `Transcripted/` sources.
- They share data **by disk contract only** (JSON sidecar schema, SQLite schemas, YAML frontmatter).
- Extracting Core will NOT break them.
- Each has its own (potentially duplicative) internal copies of types/logic — cleanup opportunities post-merge, not blockers.

---

## 10. Public API Surface — What Draft Would Need from TranscriptedCore

Every type below is currently `internal` (Transcripted has **zero `public` declarations** anywhere in Core or Services — confirmed via grep). If Draft imports TranscriptedCore, each of these needs `public` added. Columns:
- **Type / method** — call site Draft would touch.
- **Current** — today's visibility (always `internal` implicitly).
- **Needed** — what Draft requires.

### Pipeline entry points (critical)

| Type / method | Current | Needed |
|---|---|---|
| `class Transcription` (+ init) | internal | **public**, **public init** |
| `Transcription.transcribeMultichannel(micURL:systemURL:onProgress:) async throws -> TranscriptionResult` | internal nonisolated | **public** |
| `Transcription.initializeModels() async` | internal @MainActor | **public** |
| `Transcription.parakeet` / `.diarization` / `.speakerDB` (properties) | internal | **public** (so Draft can pre-initialize individually) |
| `class TranscriptionTaskManager` (+ init taking `FailedTranscriptionManager`) | internal @MainActor | **public**, **public init** |
| `TranscriptionTaskManager.startTranscription(micURL:systemURL:outputFolder:healthInfo:)` | internal | **public** |
| `TranscriptionTaskManager.retryFailedTranscription(failedId:)` | internal | **public** |
| `TranscriptionTaskManager.cancelAll()` | internal | **public** |
| `TranscriptionTaskManager.@Published` vars (`displayStatus`, `activeCount`, `speakerNamingRequest`, `lastSavedTranscriptURL`, `lastSavedTitle`, `lastSavedDuration`, `lastSavedSpeakerCount`, `justCompleted`, `backgroundTaskCount`) | internal | **public** (Draft UI binds to them) |

### Data types (used in parameters + returns of the above)

| Type | Current | Needed |
|---|---|---|
| `struct TranscriptionUtterance` (all 7 fields) | internal | **public** + public memberwise init |
| `struct TranscriptionResult` (all fields + init + computed vars) | internal | **public** |
| `enum PipelineError: LocalizedError` | internal | **public** |
| `enum SpeakerConfidence` | internal | **public** |
| `struct IdentifiedSpeaker` | internal | **public** |
| `struct TranscriptionMetadata` | internal | **public** |
| `struct SpeakerNamingRequest` | internal | **public** |
| `struct SpeakerNamingEntry` | internal | **public** |
| `struct SpeakerNameUpdate` (+ nested `NamingAction`) | internal | **public** |
| `struct SpeakerMapping` (from `Transcription.swift`) | internal | **public** |
| `enum DisplayStatus` | internal | **public** |
| `struct TranscriptionTask` | internal | **public** |
| `struct RecordingHealthInfo` + `.CaptureQuality` enum | internal | **public** |
| `struct FailedTranscription` | internal | **public** |

### Speaker recognition

| Type / method | Current | Needed |
|---|---|---|
| `struct SpeakerSegment` | internal | **public** |
| `struct SpeakerProfile` | internal | **public** |
| `struct SpeakerMatchResult` | internal | **public** |
| `enum NameSource` | internal | **public** |
| `final class SpeakerDatabase` (+ `.shared` + `init(path:)`) | internal | **public** (keep `.shared` convenient, add `public init(path:)` for Draft to point at an alternate location) |
| All 12 `SpeakerStore`-protocol methods on SpeakerDatabase | internal | **public** |
| `enum EmbeddingClusterer.postProcess(segments:existingProfiles:skipPairwiseMerge:pairwiseMergeThreshold:)` | internal static | **public** |

### Services

| Type / method | Current | Needed |
|---|---|---|
| `class ParakeetService` (+ init) | internal @MainActor | **public** |
| `ParakeetService.initialize() async`, `.isReady`, `.modelState`, `.transcribe(audioURL:)`, `.transcribeSegment(samples:source:)`, `.cleanup()` | internal | **public** |
| `enum ParakeetModelState` | internal | **public** |
| `class DiarizationService` (+ init) | internal @MainActor | **public** |
| `DiarizationService.initialize()`, `.diarizeOffline(samples:sampleRate:)`, `.diarizeOffline(audioURL:)`, `.cleanup()` | internal | **public** |
| `enum DiarizationModelState` | internal | **public** |
| `enum AudioResampler.loadAndResample(url:targetRate:)`, `.extractSlice(from:sampleRate:startTime:endTime:)` | internal static | **public** |
| `enum ModelDownloadService.withRetry`, `.classifyError(_:)`, `.checkNetworkReachability()` | internal static | **public** |
| `enum DownloadErrorKind` | internal | **public** |
| `struct ModelDownloadError` | internal | **public** |

### Storage

| Type / method | Current | Needed |
|---|---|---|
| `class TranscriptSaver` (+ all static methods: `save(text:duration:directory:)`, `saveTranscript(_:speakerMappings:speakerSources:speakerDbIds:directory:meetingTitle:healthInfo:)`, `defaultSaveDirectory`, `updateSpeakerNames(...)`, `retroactivelyUpdateSpeaker(dbId:newName:)`) | internal static | **public** |
| `extension TranscriptSaver.formatTranscriptMarkdown(...)` (if Draft wants to render YAML itself) | internal static | **public** |
| `enum AgentOutput.writeTranscriptJSON(...)`, `.writeIndex(to:speakerDB:)`, `.writeAgentReadme(to:)` | internal static | **public** |
| `class StatsDatabase` (+ init path) | internal | **public** |
| `final class StatsService` (+ `.shared` + `recordSession`, `createMetadata`, all Published vars) | internal @MainActor | **public** |
| `class FailedTranscriptionManager` (+ init) | internal @MainActor | **public** |
| `struct RecordingMetadata`, `struct DailyActivity` | internal | **public** |

### Protocols (if Draft wants to provide alternate impls)

All 6 `Services/Protocols/` files → all **public**. Today they are internal and **no concrete type formally conforms** — the conformance declarations are aspirational per `AppServices.swift`'s own TODO comment.

### Logging

| Type / method | Current | Needed |
|---|---|---|
| `final class AppLogger` (+ `.shared`, `.audio`, `.audioMic`, `.audioSystem`, `.transcription`, `.pipeline`, `.speakers`, `.services`, `.ui`, `.stats`, `.app`, `.flush()`) | internal | **public** |
| `struct SubsystemLogger` (+ `.debug`, `.info`, `.warning`, `.error`) | internal | **public** |

### AppServices DI container

| Type / method | Current | Needed |
|---|---|---|
| `struct AppServices` + `.makeDefault()` + stored props | internal @MainActor | **public**; swap stored props to `any SpeechToTextEngine` / `any DiarizationEngine` / `any SpeakerStore` per the TODO in the file |

### Count

- **~44 unique top-level type declarations** + dozens of methods. All internal today, all needed public.
- Mechanical pass: `sed` / refactor tool would take one pass per file. None of these require structural rewrites. The harder parts are the **extraction blockers in §11**.

---

## 11. Extraction Blockers (the part that will slow Phase 1 down)

Ordered from "hardest to fix, will gate extraction" to "easy, annoying but clear".

### 11.1 `Bundle.main.resourcePath` lookups (HIGH — blocks clean SPM)

Two files dereference `Bundle.main` to find bundled ML models:
- `Transcripted/Services/ParakeetService.swift:71` — `bundledModelsPath()` → `Bundle.main.resourcePath + /parakeet-models/parakeet-tdt-0.6b-v3-coreml/`.
- `Transcripted/Services/DiarizationService.swift:145` — `bundledModelsPath(directory:)` → `Bundle.main.resourcePath + directory`.

**Why it blocks**: in an SPM package linked from a host app, `Bundle.main` is the HOST app's bundle. That's actually OK if Draft also bundles the models at `Contents/Resources/parakeet-models/`. But if Draft wants a different layout (or wants to override the path for tests), the API has no hook. `DiagnosticExporter.swift:12-13` also reads `Bundle.main.infoDictionary` for version/build — lower impact since that's diagnostic only.

**Fix options**:
1. Add a public `bundleProvider: () -> URL?` closure parameter on `ParakeetService.init` / `DiarizationService.init`. Default falls back to `Bundle.main.resourcePath`. Draft passes its own locator.
2. Add a public static `modelsBaseURL: URL?` on each service that callers can set before `initialize()`. Less clean but minimal churn.
3. (Best) Refactor to `init(modelSource: ModelSource)` where `ModelSource` is an enum `.bundled(URL) | .downloadable | .custom(loader)`.

### 11.2 `UserNotifications` framework coupling (HIGH — cross-platform blocker + adds system-prompt dep)

Five Core files `import UserNotifications`:
- `TranscriptionTaskManager.swift` — `sendFailureNotification(errorMessage:)`, `requestNotificationPermission()`.
- `TranscriptionPipelineRunner.swift` — the import exists but isn't called directly; removing the import is safe.
- `TranscriptSaver.swift` — `showSaveNotification(fileURL:)` called from inside `saveTranscript`.
- `Clipboard.swift` — copy + notify; only used from UI path, stays in app target.
- `NotificationCoordinator.swift` — AppDelegate extension, stays in app target.

**Why it matters**: if Core links `UserNotifications`, any process that imports Core inherits a system prompt for notification permissions — including headless tools. For a future server-side or iOS port, UN is limited.

**Fix**: Define a `public protocol TranscriptNotifier { func notifySaved(fileURL: URL); func notifyFailure(message: String); func requestPermission() async -> Bool }`. `TranscriptionTaskManager` and `TranscriptSaver` hold an optional `TranscriptNotifier?` set at init (default nil → no-op). Draft passes a UserNotifications-backed adapter; Core target drops the import entirely. ~30–50 lines of surgery.

### 11.3 Hard-coded `~/Documents/Transcripted/` paths (MEDIUM — affects co-existence with Draft)

Every storage component assumes `~/Documents/Transcripted/`:
- `SpeakerDatabase.init()` — `.../Transcripted/speakers.sqlite`
- `StatsDatabase.init()` — `.../Transcripted/stats.sqlite` (inferred from same pattern — confirm in §8)
- `FailedTranscriptionManager.init()` — `.../Transcripted/failed_transcriptions.json`
- `TranscriptSaver.defaultSaveDirectory` — `.../Transcripted/`
- `AudioFileManager` — `~/Documents/meeting_<ts>_{mic,system}.wav` (at the Documents root, not inside Transcripted/)
- `AppLogger`/`FileLogger` — `~/Library/Logs/Transcripted/app.jsonl`
- `SpeakerClipExtractor` persistent clips — `~/Documents/Transcripted/speaker_clips/<id>.wav`

**Why it matters**: if Draft and Transcripted run on the same machine, they'd silently share data directories. That may be exactly what the user wants (unified speaker DB across apps) OR it may cause migration/conflict pain. Draft needs a decision up front.

**Fix**: introduce `struct CoreStoragePaths { let transcripts: URL; let speakerDB: URL; let statsDB: URL; let failedQueue: URL; let speakerClips: URL; let logs: URL }` with a `.default` static for the Transcripted layout. Every Core component takes a `CoreStoragePaths` at init instead of hard-coding `FileManager.default.urls(for: .documentDirectory)`. ~15 touch points, each ~3-line change.

### 11.4 `@MainActor` + `ObservableObject` on Core classes (MEDIUM — API shape decision)

`Transcription`, `TranscriptionTaskManager`, `ParakeetService`, `DiarizationService`, `FailedTranscriptionManager`, `StatsService`, `TranscriptStore`, `MeetingDetector`, `SystemAudioCapture` are all `@MainActor ObservableObject` with `@Published` properties. This is a SwiftUI-centric API.

**Why it matters**: SwiftUI is macOS-only-ish (iOS too) and pulls Combine into anything that uses them. Headless or cross-platform consumers of Core would prefer plain `async`/`AsyncStream` APIs. But Draft is also a macOS SwiftUI app today, so this may be a non-issue.

**Fix (if needed)**: add parallel non-Combine APIs (`AsyncStream<DisplayStatus>` instead of `@Published`). Or leave as-is if Draft is happy with `@StateObject` / `@ObservedObject` bindings. Probably leave as-is for v1 of the merge.

### 11.5 `@available(macOS 26.0, *)` availability floor (MEDIUM — coordinate with Draft)

81 occurrences across 58 files (mostly `Core/`, `UI/`, `Onboarding/`, plus `Services/EmbeddingClusterer.swift` and `Services/MeetingDetector.swift`). Services core (`ParakeetService`, `DiarizationService`, `SpeakerDatabase`, most of `Services/`) gates at `@available(macOS 14.0, *)`.

**Why it matters**: a TranscriptedCore target's `platforms: [.macOS(.v26)]` is fine if Draft also ships macOS 26. If Draft targets macOS 14 or 15, Core cannot export the macOS-26-gated types to it. The gating is required because of `SystemAudioCapture` (CoreAudio process taps require macOS 14.2+ but the app chose 26 as minimum for UX reasons) and `AVAudioEngine` Swift 6 concurrency APIs.

**Decision needed from draft-mapper**: what is Draft's deployment target? Based on that, either (a) set Core's platform to match, or (b) audit each macOS-26 gate and lower it to 14/15 where the API allows.

### 11.6 AppKit coupling in audio path (LOW — only if Draft extracts Audio capture)

`Audio.swift`, `AudioFileManager.swift`, `AudioDeviceRecovery.swift` import AppKit for `NSWorkspace.willSleep/didWake` notifications and `NSSound(named:"Pop")`. If Draft wants the capture stack in Core, AppKit has to come along (fine on macOS, blocks iOS). If Draft has its own capture stack, leave these in the Transcripted app target.

### 11.7 FluidAudio static lib linking via unsafe flags (HIGH — SPM pitfall)

The Transcripted app target links FluidAudio via **pbxproj unsafe flags**:
- `OTHER_LDFLAGS = "-lFluidAudioAll"`, `LIBRARY_SEARCH_PATHS += "$(SRCROOT)/fluidaudio-libs"`.
- `SWIFT_INCLUDE_PATHS = "$(SRCROOT)/fluidaudio-modules $(SRCROOT)/fluidaudio-modules/FastClusterWrapper $(SRCROOT)/fluidaudio-modules/MachTaskSelfWrapper $(SRCROOT)/fluidaudio-modules/yyjson"`.
- The prebuilt `libFluidAudioAll.a` (~54 MB) + 18 prebuilt `.swiftmodule`s live in `fluidaudio-libs/` and `fluidaudio-modules/` and are committed to git.

**Why it matters**: SPM packages cannot use `-I` / `-L` unsafe flags if they want to be depended on from another SPM package (swift-package-manager hard-errors on that). The CLI package works because it's a leaf (no upstream dependents). A Core target WILL have Draft as an upstream dependent.

**Fix options** (pick one; this is probably the single biggest decision in the merge plan):
1. **Binary XCFramework**: repackage the prebuilt FluidAudio into a `.xcframework` and reference it via `.binaryTarget(name: "FluidAudioBinary", path: "...")`. SPM supports this natively, no unsafe flags. Requires a one-time packaging script.
2. **Source dependency**: move FluidAudio to a real SPM package (upstream has one at `github.com/FluidInference/FluidAudio`). Means giving up the custom Swift 6.3 prebuild and accepting whatever version the upstream ships. Rebuild time jumps significantly.
3. **System library target**: define a `.systemLibrary` module with a modulemap. Works for C deps (FastClusterWrapper, yyjson, MachTaskSelfWrapper) but not for Swift `.swiftmodule` bundles.
4. **Keep Transcripted as an Xcode project (no SPM extraction)** and have Draft cross-link via an Xcode workspace. Avoids the SPM problem entirely but negates the "SPM package" framing of Phase 1.

**Commit `0908d05 chore: rebuild FluidAudio binaries for Swift 6.3 toolchain` (log)** suggests the team is already treating these binaries as artifacts to rebuild — the xcframework path is likely the cleanest.

### 11.8 Notification categories + UNNotificationCategoryIdentifier (LOW — depends on §11.2 fix)

`TranscriptSaver.notificationCategoryId = "TRANSCRIPT_SAVED"` and action id `"SHOW_IN_FINDER"` are referenced from `NotificationCoordinator.swift` (AppDelegate extension). If Core sheds UserNotifications per §11.2, these constants can move to the app target alongside the coordinator.

### 11.9 `Bundle.main.infoDictionary` for version strings (LOW — diagnostic only)

`DiagnosticExporter.swift:12-13` reads `CFBundleShortVersionString` / `CFBundleVersion` via `Bundle.main.infoDictionary`. Non-issue for functional Core (diagnostic feature). Easy to parameterize if kept in Core, or just leave `DiagnosticExporter` out of Core entirely (listed as Tier D above).

### 11.10 XCTest test host coupling (LOW — test strategy decision)

`TranscriptedTests/` uses `@testable import Transcripted` with an `XCTestConfigurationFilePath` env-var guard in `AppDelegate.applicationDidFinishLaunching` that skips full init during tests. If Core extracts, these tests either:
- Move into `Sources/TranscriptedCore/Tests/` and drop the host-app dependency (most — `Core/`, `Services/`, `Integration/` tests), or
- Stay in the Transcripted app target for UI tests (`TranscriptedTests/UI/`, which test Pill state etc.).
Neither is a blocker, but the user will want to see the Core tests move with Core.

### 11.11 No asset-catalog / storyboard / @IBOutlet coupling

Confirmed by inspection:
- `Assets.xcassets/` contains only `AccentColor.colorset` and `AppIcon.appiconset`. **Zero code lookups to asset names** in Core/Services (verified with grep for `NSImage(named:`, `Color("`, `UIImage`, `.xcassets` — only matches are in UI/Design, not Core/Services).
- **Zero storyboards** — the project is pure SwiftUI.
- **Zero `@IBOutlet`/`@IBAction`** — verified by grep (no hits in the whole tree under `Transcripted/`).
- **SwiftUI `#Preview`/`PreviewProvider` usage** is confined to `UI/` and `Design/` and `Onboarding/` (not Core/Services). Not an extraction blocker.
- **No `@objc` class inheritance from NSObject** in Core/Services except `AppDelegate` and `OnboardingWindowController` (both live in UI/app code, not Core). `SpeakerDatabase` is `final class … @unchecked Sendable`.

### 11.12 Singletons that Draft will see from both sides

- `SpeakerDatabase.shared`
- `StatsService.shared`
- `AppLogger.shared`

All three have hard-coded file paths. If Draft also touches these via Core (via `import TranscriptedCore`) AND Transcripted's own app target is running on the same machine, they'll race on the same files. This matters for development (testing both apps side-by-side) and for any future "Draft installs, migrates data from Transcripted" scenario. Decision needed: unify or isolate via `CoreStoragePaths` (§11.3).

---

## Hand-off notes for draft-mapper

- I read exhaustively from `<transcripted-root>` only and wrote only this file. No Draft-side files touched.
- **Expected overlap with Draft** — ask Draft for its equivalents; these are the areas where merge-plan.md will need collision-resolution sections:
  - **Audio capture**: Transcripted has a full dual-stream (mic + system audio, macOS 14.2+ CoreAudio process taps) capture layer in `Core/Audio.swift` + `Core/SystemAudioCapture.swift` (~1,400 LOC across 8 files, all NOT @MainActor). If Draft has its own, these stay out of Core.
  - **Speaker DB / matching**: `Services/SpeakerDatabase.swift` (SQLite, utility queue) + `SpeakerEmbeddingMatcher` + `SpeakerProfileMerger` + `EmbeddingClusterer`. If Draft has its own speaker store, one wins and the other is deleted.
  - **Markdown + YAML transcript output**: `TranscriptSaver` + `TranscriptFormatter` + `AgentOutput` (JSON sidecar). Transcripted's YAML schema (§8.2) is load-bearing for `TranscriptedMCP` — if Draft has a different format, one side has to convert.
  - **Stats DB**: `Core/StatsDatabase.swift`.
  - **Parakeet/PyAnnote via FluidAudio**: the whole pipeline is built on FluidAudio's `AsrManager` + `OfflineDiarizerManager`. If Draft uses a different STT/diarizer (WhisperKit, Apple Speech, etc.), this is the fork point.
  - **Logging**: `AppLogger` with 10 subsystems + JSONL file output.
  - **`@available(macOS 26.0, *)`**: check Draft's deployment target.
- **Biggest blocker for Phase 1 planning**: §11.7 (FluidAudio linked via unsafe flags) + §11.1 (`Bundle.main.resourcePath` in model services) + §11.3 (hard-coded `~/Documents/Transcripted` storage paths). Those three together determine the shape of Core's init API. Happy to answer follow-ups with specific file paths / signatures as you draft the merge plan.
