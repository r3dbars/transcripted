#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import CoreGraphics
import Foundation

extension WritingController {
    // MARK: - Actions for the Writing tab

    /// Switches the model without a relaunch: the helper stops, the new
    /// model is adopted or downloaded and verified, the helper restarts.
    /// An ineligible choice (Qwen under 16 GiB) is ignored.
    func selectModel(_ choice: TildeModelChoice) {
        guard WritingModelEligibility.isEligible(choice, physicalMemoryBytes: physicalMemoryBytes) else {
            log("WRITING | \(choice.rawValue) needs 16 GB of memory; staying on \(selectedModel.rawValue)")
            return
        }
        guard isRunning else {
            TildeModelSelection.persist(choice, defaults: Self.appDefaults())
            selectedModel = choice
            return
        }
        guard autocompleteRuntimeActive else {
            // No helper and no download with Autocomplete off: save the
            // choice and serve its configuration. Turning Autocomplete on
            // prepares this model.
            guard choice != activeModel else { return }
            persistModelChoice(choice)
            rebuildRuntime(for: choice)
            return
        }
        // An interrupted switch leaves the runtime's model unknown, so the
        // next one runs every step even back to the same model.
        let current = modelTask == nil ? activeModel : nil
        let steps = WritingModelSwitchSteps(controller: self)
        let memory = physicalMemoryBytes
        runModelTask { controller in
            let outcome = await WritingModelSwitch.perform(
                from: current,
                to: choice,
                physicalMemoryBytes: memory,
                host: steps
            )
            controller.log("WRITING | model switch to \(choice.rawValue): \(outcome)")
        }
    }

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

    /// The Writing tab's keyboard step: install or update, register, try to
    /// enable, and select when it's enabled, every time it's asked (the
    /// launch path tries the enable and select only on the first setup).
    /// macOS 26 ignores the enable, so until the user adds the keyboard in
    /// Keyboard settings this ends not selected. `openSettingsOnFailure` is
    /// only for the tab's "Open Keyboard Settings" button: nothing else opens
    /// System Settings. `true` once the keyboard is the selected input
    /// source.
    @discardableResult
    func turnOnKeyboard(openSettingsOnFailure: Bool = false) -> Bool {
        guard installKeyboardRecordingFirstInstall() else {
            if openSettingsOnFailure { keyboardInstaller.openKeyboardSettings() }
            return false
        }
        let selected = enableAndSelectKeyboard()
        if !selected, openSettingsOnFailure {
            keyboardInstaller.openKeyboardSettings()
        }
        return selected
    }

    /// Install or update and register. When this copied the keyboard in
    /// where none was before, remembers the login session it happened in
    /// (`WritingKeyboardFirstInstall`). `true` when the keyboard is in place.
    func installKeyboardRecordingFirstInstall() -> Bool {
        let wasInstalled = Self.keyboardIsInstalled
        let result = keyboardInstaller.installOrUpdateIfNeeded()
        keyboardInstallResult = result
        log("WRITING | keyboard install: \(result)")
        if result == .installed, !wasInstalled {
            WritingKeyboardFirstInstall.record(
                currentSession: WritingLoginSession.currentIdentifier(),
                defaults: Self.appDefaults()
            )
        }
        return result == .installed || result == .alreadyInstalled
    }

    /// Tries `TISEnableInputSource`, checks it took, and selects the
    /// keyboard when it's enabled. Logs what actually happened. `true` once
    /// the keyboard is the selected input source.
    func enableAndSelectKeyboard() -> Bool {
        let enable = WritingKeyboardInputSource.enable(using: inputSources)
        keyboardEnableResult = enable
        switch enable {
        case .enabled:
            log("WRITING | keyboard enable: enabled")
        case .alreadyEnabled:
            log("WRITING | keyboard enable: already enabled")
        case .needsUserToAdd:
            log("WRITING | keyboard enable: still off after TISEnableInputSource returned noErr; the user has to add it in Keyboard settings")
        case .notRegistered:
            log("WRITING | keyboard enable: not registered")
        case let .failed(status):
            log("WRITING | keyboard enable: TISEnableInputSource failed (\(status))")
        }
        guard enable.isEnabled else {
            keyboardSelectSucceeded = false
            log("WRITING | keyboard select: skipped, keyboard not enabled")
            return false
        }
        let selected = keyboardInstaller.selectInputSourceIfAvailable()
        keyboardSelectSucceeded = selected
        log("WRITING | keyboard select: \(selected ? "selected" : "not selected")")
        if selected {
            Self.appDefaults().set(true, forKey: Self.keyboardFirstSetupKey)
        }
        return selected
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

/// Drives `WritingModelSwitch` against the live runtime without making
/// those steps part of the controller's own API.
@MainActor
private final class WritingModelSwitchSteps: WritingModelSwitchHost {
    private weak var controller: WritingController?

    init(controller: WritingController) {
        self.controller = controller
    }

    func stopHelper() async { await controller?.stopHelper() }
    func persistModelChoice(_ choice: TildeModelChoice) { controller?.persistModelChoice(choice) }
    func rebuildRuntime(for choice: TildeModelChoice) { controller?.rebuildRuntime(for: choice) }
    func prepareModel() async -> Bool { await controller?.prepareCurrentModel() ?? false }
    func startHelper() { controller?.startHelper() }
}
