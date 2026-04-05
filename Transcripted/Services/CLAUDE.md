# Services Folder (App Target)

Embedder adapters that conform to TranscriptedCore protocols, plus the meeting auto-detection scanner. 3 Swift files + `Protocols/` subdirectory.

**IMPORTANT**: Prior to merge-plan Phase 2 Lane A extraction, this folder held 16 files including `ParakeetService`, `DiarizationService`, `SpeakerDatabase`, `SpeakerEmbeddingMatcher`, `SpeakerProfile*`, `EmbeddingClusterer`, `AudioResampler`, `SpeakerClipExtractor`. The ML-heavy code moved to `Sources/TranscriptedCore/` as a Swift Package. What remains here is only the glue between Core's protocols and concrete platform APIs (FluidAudio, UserNotifications) plus the NSWorkspace-based meeting detector.

## File Index

| File | Actor | Purpose |
|------|-------|---------|
| `ParakeetEngineAdapter.swift` | @MainActor | App-target conformer for `TranscriptedCore.SpeechToTextEngine`. Wraps FluidAudio 0.7.9's `AsrManager` actor. Batch transcription only (Transcripted records first, then transcribes — no live streaming). Loads models from `Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/` via bundle. |
| `TranscriptedNotificationsAdapter.swift` | @MainActor | App-target conformer for `TranscriptedCore.TranscriptNotifier`. Wraps `UNUserNotificationCenter`; sets `content.categoryIdentifier = "TRANSCRIPT_SAVED"` on saved-transcript notifications so `NotificationCoordinator`'s "Show in Finder" action button fires, and stashes the path in `userInfo["fileURL"]`. See `Transcripted/Core/CLAUDE.md` § "TranscriptNotifier wiring". |
| `MeetingDetector.swift` | @MainActor | Monitors Zoom/Teams/Webex/FaceTime/Loom via NSWorkspace app launch/quit notifications + 1s polling. Auto-triggers recording when both mic + system audio are active for ≥5s; auto-stops after 15s silence. Only auto-stops recordings it auto-triggered. |

## Protocols/ subdirectory

Historical: `Transcripted/Services/Protocols/` used to hold the 6 Core protocols. Those protocol definitions moved to `Sources/TranscriptedCore/Protocols/` as part of the extraction. If a `Protocols/` folder still exists here it contains only app-target-specific shims or is empty.

## Pipeline Order (reference)

```
1. ParakeetEngineAdapter.transcribeSegment(samples, source) -> String     [this folder]
2. DiarizationService.diarizeOffline(samples, sampleRate) -> [SpeakerSegment]    [Sources/TranscriptedCore/Services/]
3. EmbeddingClusterer.postProcess(segments, profiles, skipPairwiseMerge) -> [SpeakerSegment]    [Sources/TranscriptedCore/Speaker/]
4. SpeakerDatabase.matchSpeaker(embedding, threshold) -> SpeakerMatchResult?    [Sources/TranscriptedCore/Speaker/]
```

Only step 1 lives in this folder — the rest live in TranscriptedCore.

## ParakeetEngineAdapter model state

```swift
enum ParakeetModelState: Equatable {
    case notLoaded
    case loading
    case ready
    case failed(String)
}
```

`@Published modelState` drives the status dot in the floating pill. Bundle layout expected: `Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/` with 6 CoreML model packages (encoder, decoder, joint). If models are missing, `ModelDownloadService` (in `Sources/TranscriptedCore/Services/`) downloads them from HuggingFace with mirror fallback.

## TranscriptedNotificationsAdapter details

- Guards on `UNUserNotificationCenter.getNotificationSettings(...).authorizationStatus == .authorized` before delivery to avoid `UNErrorDomain` error 1.
- Uses unique per-notification identifiers (`transcript-saved-<UUID>`) so multiple saves don't collapse into a single notification.
- `requestNotificationPermission()` is a no-op because permission is requested during `AppDelegate.registerNotificationCategories()` at launch.
- `notifyTranscriptionFailed(errorMessage:)` posts a plain "Transcription Failed" notification without any action button (no category tag).

## MeetingDetector

| Field | Value |
|---|---|
| Zoom bundle ID | `us.zoom.xos` |
| Teams bundle ID | `com.microsoft.teams2` |
| Webex bundle ID | `Cisco-Systems.Spark` |
| FaceTime bundle ID | `com.apple.FaceTime` |
| Loom bundle ID | `com.loom.desktop` |
| Auto-start threshold | mic + system audio level > 0.02 for ≥ 5 seconds |
| Auto-stop threshold | 15 seconds of combined silence |
| Manual override | MeetingDetector only auto-stops recordings it auto-started; manual recordings must be stopped manually |

## Threading Rules

- All three files in this folder are `@MainActor`.
- The ML code they delegate to (FluidAudio's `AsrManager`, Core's `DiarizationService`) is also `@MainActor`.
- `SpeakerDatabase` (in `Sources/TranscriptedCore/Speaker/`) is the exception — it uses a dedicated utility queue, NOT `@MainActor`.

## Where pre-extraction code lives now

If older CLAUDE.md or comments reference these paths, they've moved:

| Old path (`Transcripted/Services/...`) | New path |
|---|---|
| `ParakeetService.swift` | Split: protocol stays in `Sources/TranscriptedCore/Protocols/SpeechToTextEngine.swift`; FluidAudio adapter is now `Transcripted/Services/ParakeetEngineAdapter.swift` (this folder) |
| `DiarizationService.swift` | `Sources/TranscriptedCore/Services/DiarizationService.swift` |
| `SpeakerDatabase.swift` + `SpeakerEmbeddingMatcher.swift` + `SpeakerProfile.swift` + `SpeakerProfileMerger.swift` | `Sources/TranscriptedCore/Speaker/` |
| `EmbeddingClusterer.swift` | `Sources/TranscriptedCore/Speaker/EmbeddingClusterer.swift` |
| `AudioResampler.swift` | `Sources/TranscriptedCore/Audio/AudioResampler.swift` |
| `SpeakerClipExtractor.swift` | `Sources/TranscriptedCore/Speaker/SpeakerClipExtractor.swift` |
| `Protocols/SpeechToTextEngine.swift` + 5 others | `Sources/TranscriptedCore/Protocols/` |

See `Sources/TranscriptedCore/CLAUDE.md` (or the per-subfolder CLAUDE.md files under `Sources/TranscriptedCore/`) for full details on the moved code.
