#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import CoreGraphics
import Foundation

// Actions for the Writing tab (not the model switch or the keyboard step),
// split out of `WritingController.swift`.

extension WritingController {
    /// Save my writing is Tilde's Personal History switch. It goes through the
    /// controller when Writing runs, so consent rotates and text queued
    /// before the change is refused, as in Tilde.
    func setSaveMyWriting(_ enabled: Bool) {
        if let runtime {
            runtime.personalHistoryController.isEnabled = enabled
        } else {
            let settings = Self.settings()
            settings.personalHistoryConsentIdentifier = UUID().uuidString
            settings.personalHistoryEnabled = enabled
        }
    }

    /// Tilde's suggestions switch. Saves only; `applyRunState()` then starts
    /// or stops the model and helper.
    func setAutocomplete(_ enabled: Bool) {
        Self.settings().suggestionsEnabled = enabled
    }

    /// Off by default (decision 11). Serving also needs Save my writing on.
    func setPersonalizedSuggestions(_ enabled: Bool) {
        Self.preferences().personalizedSuggestionsEnabled = enabled
    }

    /// Tilde's "Pause for 1 hour", which here pauses Save my writing too:
    /// the keyboard stops suggesting, and text it sends meanwhile is
    /// acknowledged and never kept (`WritingPausableIngest`).
    func pause(for interval: TimeInterval) {
        Self.settings().pause(for: interval)
        applyFrontWindowWatch()
        log("WRITING | paused for \(Int(interval / 60)) min")
    }

    func resume() {
        Self.settings().resume()
        applyFrontWindowWatch()
        log("WRITING | resumed")
    }

    /// One scope for capture, the day files, Screen Memory context and
    /// suggestions. The keyboard picks it up on its next key.
    func setAppScope(_ scope: WritingAppScope) {
        Self.preferences().appScope = scope
        applyFrontWindowWatch()
    }

    /// Delete all writing: Tilde's delete-all (history, trained model,
    /// Keychain key, outcome ledger) plus every `Writing_*.md` in the writing
    /// folder. Like Tilde's, it turns Save my writing off. `true` when
    /// everything went.
    func deleteAllWriting() async -> Bool {
        let controller = runtime?.personalHistoryController ?? PersonalHistoryController(
            store: EncryptedPersonalHistoryStore(),
            settings: Self.settings(),
            diagnostics: .shared
        )
        var deleted = true
        do {
            try await controller.deleteAll()
        } catch {
            deleted = false
        }
        if !TildeLocalOutcomeStores.deleteAll() { deleted = false }
        let recorder = runtime?.dayFiles.recorder
        let directory = writingDirectory
        let filesDeleted = await Task.detached(priority: .userInitiated) {
            recorder?.deleteAll() ?? WritingDayFileStore.deleteAll(in: directory())
        }.value
        log("WRITING | delete all writing: \(deleted && filesDeleted ? "done" : "incomplete")")
        return deleted && filesDeleted
    }

    /// Shows the system Screen Recording prompt the first time. macOS then
    /// offers its own "Quit & Reopen", which goes through Transcripted's
    /// normal quit path and its meeting guard. Nothing here relaunches.
    @discardableResult
    func requestScreenRecording() -> Bool {
        Self.settings().screenRecordingRequested = true
        let granted = ScreenRecordingPermission.request()
        DiagnosticsLog.shared.record(
            "screen-recording-permission",
            metadata: ["outcome": granted ? "granted" : "requested"]
        )
        return granted
    }

    /// After the one system prompt, macOS only grants from System Settings.
    func openScreenRecordingSettings() {
        NSWorkspace.shared.open(ScreenRecordingPermission.systemSettingsURL)
    }

    /// Bytes on this Mac, for the Writing tab's storage meter. Reads sizes
    /// only, off the main thread.
    func storageUsage() async -> WritingStorageUsage {
        let historyController = runtime?.personalHistoryController
        let directory = writingDirectory
        let modelRoot = modelRoot
        let historyBytes: Int64
        if let historyController {
            historyBytes = await historyController.summary()?.approximateBytes ?? 0
        } else {
            historyBytes = (try? await EncryptedPersonalHistoryStore().summary().approximateBytes) ?? 0
        }
        return await Task.detached(priority: .utility) {
            WritingStorageUsage(
                savedWritingBytes: WritingStorageUsage.dayFileBytes(in: directory()),
                learningBytes: historyBytes + TildeLocalOutcomeStores.approximateBytes(),
                modelBytes: WritingStorageUsage.fileBytes(under: modelRoot)
            )
        }.value
    }
}
