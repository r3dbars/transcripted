# Core Folder (App Target)

App-target coordinators and UI-side helpers. 11 Swift files.

**IMPORTANT**: Prior to merge-plan Phase 2 Lane A extraction (see root `CLAUDE.md`), this folder held 48 files including the entire audio/transcription/stats/speaker pipeline. That pipeline has moved to `Sources/TranscriptedCore/` as a Swift Package. What remains here is only the glue that depends on AppKit/NSApplication and cannot live in a UI-agnostic library.

## File Index

| File | Actor | Purpose |
|------|-------|---------|
| `MenuBarManager.swift` | @MainActor (AppDelegate extension) | Status bar icon setup, popover menu, stats rows (today/week/streak), recording toggle item, failed/processing menu items |
| `HotkeyManager.swift` | @MainActor (AppDelegate extension) | Global Cmd+Shift+R hotkey registration via Carbon, local/global NSEvent monitors |
| `NotificationCoordinator.swift` | @MainActor (AppDelegate extension) | UNUserNotificationCenter categories (`AUTO_DETECT_RECORDING`, `TRANSCRIPT_SAVED`), permission request, delegate forwarding. The `TRANSCRIPT_SAVED` category provides the "Show in Finder" action button; delivered notifications get tagged by `Transcripted/Services/TranscriptedNotificationsAdapter.swift` which conforms to Core's `TranscriptNotifier` protocol. |
| `WindowCoordinator.swift` | @MainActor (AppDelegate extension) | Settings / onboarding / failed transcriptions window lifecycle |
| `RecordingCoordinator.swift` | @MainActor (AppDelegate extension) | Recording toggle flow, `handleRecordingComplete(micURL:systemURL:)` → `TranscriptionTaskManager.startTranscription(...)`, orphaned file cleanup |
| `AppDelegateDebug.swift` | @MainActor (AppDelegate extension) | DEBUG-only helpers (reset onboarding, test speaker naming tray) |
| `Clipboard.swift` | -- | NSPasteboard helper |
| `TranscriptExporter.swift` | -- | NSSavePanel-based export to `.md` or `.txt` |
| `TranscriptStore.swift` | @MainActor | Reads saved transcripts from `~/Documents/Transcripted/` for the tray UI. `parseSingle(url:)` is also used by other code to pull YAML frontmatter metadata. |
| `DiagnosticExporter.swift` | -- | Diagnostic bundle export for bug reports |
| `SystemSettingsHelper.swift` | -- | `x-apple.systempreferences:` URL scheme helper (microphone, screen recording panes) |

## Where everything else went

The extraction moved these file groups to `Sources/TranscriptedCore/`:

| Old location (`Transcripted/Core/...`) | New location |
|---|---|
| `Audio.swift`, `AudioDeviceRecovery.swift`, `AudioFileManager.swift`, `AudioLevelMonitor.swift`, `SystemAudioCapture.swift`, `SystemAudioProcessTap.swift`, `SystemAudioBufferWriter.swift`, `CoreAudioUtils.swift` | `Sources/TranscriptedCore/Audio/` |
| `Transcription.swift`, `TranscriptionPipeline.swift`, `TranscriptionPipelineRunner.swift`, `TranscriptionTaskManager.swift` | `Sources/TranscriptedCore/Pipeline/` |
| `DisplayStatus.swift`, `FailedTranscription.swift`, `TranscriptionTypes.swift`, `TranscriptMetadataBuilder.swift` | `Sources/TranscriptedCore/Models/` |
| `TranscriptSaver.swift`, `TranscriptFormatter.swift`, `TranscriptScanner.swift`, `AgentOutput.swift` | `Sources/TranscriptedCore/Storage/` |
| `StatsDatabase.swift`, `StatsDatabaseModels.swift`, `StatsDatabaseQueries.swift`, `StatsService.swift` | `Sources/TranscriptedCore/Stats/` |
| `ModelDownloadService.swift`, `RecordingValidator.swift`, `FailedTranscriptionManager.swift`, `AppServices.swift`, `DiarizationService.swift`, `CoreStoragePaths.swift` | `Sources/TranscriptedCore/Services/` |
| `SpeakerNamingCoordinator.swift`, `SpeakerMatchingService.swift`, `RetroactiveSpeakerUpdater.swift` | `Sources/TranscriptedCore/Speaker/` |
| `Logging/AppLogger.swift`, `Logging/FileLogger.swift` | `Sources/TranscriptedCore/Logging/` |
| `DateFormattingHelper.swift`, `DateParser.swift`, `FilePermissions.swift`, `TranscriptUtils.swift` | `Sources/TranscriptedCore/Utilities/` |

If an older CLAUDE.md or comment still references `Transcripted/Core/Audio.swift`, `Transcripted/Core/Transcription.swift`, etc., treat it as stale and update the reference to `Sources/TranscriptedCore/...`.

## Critical Pattern: TranscriptNotifier wiring

`NotificationCoordinator.swift` in this folder owns the app-target notification category constants (`TRANSCRIPT_SAVED`, `SHOW_IN_FINDER`) and registers them via `UNUserNotificationCenter.setNotificationCategories(...)` during `setupApp()`. But Core's `TranscriptSaver` cannot set `content.categoryIdentifier` directly — Core is UI-framework-agnostic and only sees the `TranscriptNotifier` protocol. The bridge is `Transcripted/Services/TranscriptedNotificationsAdapter.swift`, which:

1. Conforms to `TranscriptedCore.TranscriptNotifier`
2. Is constructed in `TranscriptedApp.setupApp()` and passed as the `notifier:` parameter to `TranscriptionTaskManager.init`
3. In `notifyTranscriptSaved(fileURL:)`, builds a `UNMutableNotificationContent` with `categoryIdentifier = "TRANSCRIPT_SAVED"` and `userInfo = ["fileURL": savedPath]`
4. `handleNotificationResponse` in this file reads `userInfo["fileURL"]` on the `SHOW_IN_FINDER` action and calls `NSWorkspace.shared.activateFileViewerSelecting`

This pattern was introduced post-extraction to fix a regression where saved-transcript notifications stopped firing entirely because `TranscriptionTaskManager` was constructed without a notifier (the parameter defaulted to nil).

## Initialization

See `Transcripted/TranscriptedApp.swift:setupApp()` for the full boot sequence: `registerNotificationCategories()` → construct `FailedTranscriptionManager` / `Audio` / `ParakeetEngineAdapter` / `DiarizationService` / `TranscriptedNotificationsAdapter` → construct `TranscriptionTaskManager` with adapters injected → wire `onRecordingComplete` → start `MeetingDetector` → show floating panel.
