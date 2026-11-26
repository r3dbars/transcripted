#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import Foundation

/// Whether the lightweight capture keyboard is installed and active.
struct WritingKeyboardState: Equatable {
    /// `~/Library/Input Methods/Transcripted Keyboard.app` exists.
    let installed: Bool
    /// Signed by this app's team, registered, and enabled in Input Sources.
    let enabled: Bool
    /// The current input source.
    let selected: Bool
    /// Guidance state, or `nil` while the keyboard isn't installed yet.
    let setup: WritingKeyboardSetupState?
}

extension Notification.Name {
    /// Posted on the main actor when Writing capture's runtime status (running,
    /// start failure, or pause window) changes.
    static let writingRuntimeStateDidChange = Notification.Name("Transcripted.WritingRuntimeStateDidChange")
}

/// Hosts opt-in writing capture inside Transcripted: the owner-only unix
/// socket the lightweight keyboard sends typed text over, the secret-scrubbed
/// Markdown day-file writer (`captures/writing/`), and the keyboard installer.
///
/// Off by default. Starts only when the user opts into "Save my writing" (or
/// sets the dev-only `WritingDebugEnabled` default). Never downloads models,
/// never runs `llama-server`, and never requests Screen Recording permission.
@MainActor
final class WritingController {
    nonisolated static let appSuiteName = "com.justinbetker.draft.writing"
    nonisolated static let debugEnabledKey = "WritingDebugEnabled"
    nonisolated static let keyboardFirstSetupKey = "KeyboardEnabledAndSelectedOnce"
    private nonisolated static let automaticTerminationReason = "Transcripted Writing capture serves the keyboard"

    /// Set by `noteTerminationRequest()` when macOS itself is quitting the app
    /// (logout, restart, shutdown).
    private(set) static var terminationIsSystemInitiated = false

    static func noteTerminationRequest() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let hasSystemQuitReason = event?.eventID == AEEventID(kAEQuitApplication)
            && event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        terminationIsSystemInitiated = hasSystemQuitReason
    }

    nonisolated static func appDefaults() -> UserDefaults {
        UserDefaults(suiteName: appSuiteName) ?? .standard
    }

    nonisolated static func settings() -> TildeSettings {
        TildeSettings(
            keyboard: UserDefaults(suiteName: TildeSettings.keyboardSuiteName),
            app: appDefaults()
        )
    }

    nonisolated static func preferences() -> WritingPreferences {
        WritingPreferences(
            keyboard: UserDefaults(suiteName: TildeSettings.keyboardSuiteName),
            app: appDefaults()
        )
    }

    // MARK: - State

    private(set) var isRunning = false
    private(set) var startFailed = false
    private var keyboardInstallTask: Task<GhostKeyboardInstallerHost.KeyboardInstallResult, Never>?
    private(set) var runtimeStopCount = 0
    var keyboardActionAdmission: Int? { isTerminated ? nil : runtimeStopCount }

    var saveMyWritingEnabled: Bool { Self.preferences().saveMyWritingEnabled }
    var saveMyWritingProblem: WritingDayFileRecorder.WriteFailure? { dayFiles?.recorder.lastWriteFailure }
    var appScope: WritingAppScope { Self.preferences().appScope }
    var setupCompleted: Bool { WritingSetupState.isCompleted(defaults: Self.appDefaults()) }
    var pausedUntil: Date? { Self.settings().pausedUntil }

    nonisolated static var keyboardIsInstalled: Bool {
        let installedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
            .appendingPathComponent(TildeProductProfile.current.inputMethodInstalledBundleName)
            .path
        return FileManager.default.fileExists(atPath: installedPath)
    }

    private var keyboardFirstInstalledThisLoginSession: Bool {
        WritingKeyboardFirstInstall.happenedThisLoginSession(
            currentSession: WritingLoginSession.currentIdentifier(),
            defaults: Self.appDefaults()
        )
    }

    let writingDirectory: @Sendable () -> URL
    let writingPendingDirectory: @Sendable () -> URL
    let appSupportRoot: @Sendable () -> URL
    let keyboardInstaller = GhostKeyboardInstallerHost()
    var inputSources: SystemWritingInputSources {
        SystemWritingInputSources(installer: keyboardInstaller)
    }

    private var dayFiles: WritingDayFileWriter?
    private var ghostBrainServerHost: GhostBrainServerHost?
    private var log: (String) -> Void = { _ in }
    private var hasStarted = false
    private var isTerminated = false
    private var quitAbandonsUnsavedWriting = false
    private var activationAllowed = false
    private var hasScheduledLaunchMaintenance = false

    init(
        writingDirectory: @escaping @Sendable () -> URL = WritingDayFileWriter.defaultDirectory,
        writingPendingDirectory: @escaping @Sendable () -> URL = WritingDayFileWriter.defaultPendingDirectory,
        appSupportRoot: @escaping @Sendable () -> URL = { FileManager.default.transcriptedAppSupportRootURL }
    ) {
        self.writingDirectory = writingDirectory
        self.writingPendingDirectory = writingPendingDirectory
        self.appSupportRoot = appSupportRoot
    }

    // MARK: - Lifecycle

    func startIfEnabled(log: @escaping (String) -> Void) {
        self.log = log
        activationAllowed = true
        applyRunState()
        runLaunchMaintenanceOnce()
    }

    private func runLaunchMaintenanceOnce() {
        guard !hasScheduledLaunchMaintenance, !isTerminated, !AutomatedLaunchEnvironment.isActive() else { return }
        hasScheduledLaunchMaintenance = true

        // Clean up legacy Personal History / Outcome Ledger / Word Diary /
        // next-sentence files and Keychain key left behind by older builds.
        // Leaves `<capture-library>/writing/` day files untouched.
        let appSupportRoot = self.appSupportRoot
        Task.detached(priority: .utility) {
            guard let result = LegacyWritingDataCleanup.runLaunchCleanupIfNeeded(
                appSupportRoot: appSupportRoot()
            ) else { return }
            if !result.removedRelativePaths.isEmpty || result.keychainItemsDeleted > 0 {
                DiagnosticsLog.shared.record(
                    "legacy-writing-data-cleaned",
                    metadata: [
                        "removed": String(result.removedRelativePaths.count),
                        "keychain": String(result.keychainItemsDeleted),
                    ]
                )
            }
        }

        // If `Transcripted Keyboard.app` is already installed from an older
        // build, update it to the silent pass-through keyboard even while
        // capture is off so an outdated keyboard doesn't hammer the socket.
        if !isRunning, Self.keyboardIsInstalled {
            Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, self.keyboardActionAdmission != nil else { return }
                _ = await self.installKeyboardRecordingFirstInstall()
            }
        }
    }

    func applyRunState() {
        guard activationAllowed, !isTerminated else { return }
        let shouldRun = WritingActivation.shouldRun(
            saveMyWriting: Self.settings().personalHistoryEnabled,
            debugEnabled: UserDefaults.standard.bool(forKey: Self.debugEnabledKey)
        )
        if !shouldRun {
            if hasStarted {
                log("WRITING | capture off; stopping")
                tearDown()
            } else if startFailed {
                startFailed = false
                NotificationCenter.default.post(name: .writingRuntimeStateDidChange, object: nil)
            }
        } else if !hasStarted {
            start(log: log)
        }
    }

    func start(log: @escaping (String) -> Void = { _ in }) {
        guard !hasStarted, !isTerminated else { return }
        hasStarted = true
        self.log = log

        ensureHistoryIdentifiers()

        let dayFiles = WritingDayFileWriter(
            directory: writingDirectory,
            pendingDirectory: writingPendingDirectory,
            preferences: { Self.preferences() },
            problemStarted: { [weak self] error in
                self?.log("WRITING | save my writing: day file write failed (\(error))")
            }
        )
        self.dayFiles = dayFiles

        let ingest = WritingHistoryIngest(
            dayFiles: dayFiles.recorder,
            appScope: { Self.preferences().appScope }
        )
        let server = GhostBrainServerHost(personalHistory: ingest)
        guard server.start() else {
            DiagnosticsLog.shared.record("duplicate-instance", metadata: [:])
            log("WRITING | socket server did not start (runtime lock held); capture stays off")
            hasStarted = false
            startFailed = true
            self.dayFiles = nil
            NotificationCenter.default.post(name: .writingRuntimeStateDidChange, object: nil)
            return
        }
        ghostBrainServerHost = server
        startFailed = false
        isRunning = true
        dayFiles.start()

        ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)
        installKeyboard()
        DiagnosticsLog.shared.record("launch", metadata: ["mode": "capture_only"])
        log("WRITING | capture started")
        NotificationCenter.default.post(name: .writingRuntimeStateDidChange, object: nil)
    }

    func stop() {
        isTerminated = true
        guard hasStarted else { return }
        tearDown()
    }

    func handleSystemWake() {
        // Capture-only runtime holds no external helper process to probe on wake.
    }

    func finishWritingForTermination() async -> Bool {
        guard let recorder = dayFiles?.recorder else { return true }
        return await Task.detached(priority: .userInitiated) {
            recorder.flush(sealForTermination: true)
        }.value
    }

    func abandonUnsavedWritingForTermination() {
        quitAbandonsUnsavedWriting = true
        dayFiles?.recorder.sealWithoutFlush()
    }

    private func tearDown() {
        let abandoning = isTerminated && quitAbandonsUnsavedWriting
        guard abandoning || dayFiles?.stop() != false else { return }
        hasStarted = false
        runtimeStopCount &+= 1
        let wasRunning = isRunning
        isRunning = false
        startFailed = false
        DiagnosticsLog.shared.record("shutdown", metadata: [:])
        DiagnosticsLog.shared.flush()
        ghostBrainServerHost?.stop()
        ghostBrainServerHost = nil
        dayFiles = nil
        if wasRunning {
            ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
        }
        NotificationCenter.default.post(name: .writingRuntimeStateDidChange, object: nil)
    }

    // MARK: - Opt-in actions

    func pauseForOneHour() {
        Self.settings().pause(for: 3_600)
        NotificationCenter.default.post(name: .writingRuntimeStateDidChange, object: nil)
    }

    func resumeCapture() {
        Self.settings().resume()
        NotificationCenter.default.post(name: .writingRuntimeStateDidChange, object: nil)
    }

    func setSaveMyWriting(_ enabled: Bool) {
        let settings = Self.settings()
        if enabled {
            ensureHistoryIdentifiers()
        }
        settings.personalHistoryConsentIdentifier = UUID().uuidString
        settings.personalHistoryEnabled = enabled
        if enabled {
            let isFirstSetup = !setupCompleted
            WritingSetupState.markCompleted(defaults: Self.appDefaults())
            if isFirstSetup {
                WritingAnalytics.trackSetupCompleted(WritingAnalytics.Setup(
                    saveEnabled: true,
                    appScope: appScope.mode == .all ? .all : .picked
                ))
            }
        }
        if let recorder = dayFiles?.recorder {
            recorder.enqueuePrivacyReconciliation()
        } else {
            WritingDayFileRecorder.reconcileStoredPrivacy(
                in: writingPendingDirectory(),
                gate: .init(preferences: Self.preferences()),
                failed: { DiagnosticsLog.shared.record("writing-pending-privacy-erase-failed") }
            )
        }
        applyRunState()
    }

    func setAppScope(_ scope: WritingAppScope) {
        Self.preferences().appScope = scope
        if let recorder = dayFiles?.recorder {
            recorder.enqueuePrivacyReconciliation()
        } else {
            WritingDayFileRecorder.reconcileStoredPrivacy(
                in: writingPendingDirectory(),
                gate: .init(preferences: Self.preferences()),
                failed: { DiagnosticsLog.shared.record("writing-pending-privacy-erase-failed") }
            )
        }
    }

    func deleteAllWriting() async -> Bool {
        let settings = Self.settings()
        settings.personalHistoryEnabled = false
        settings.resume()
        settings.personalHistoryIdentifier = UUID().uuidString
        settings.personalHistoryConsentIdentifier = UUID().uuidString

        let recorder = dayFiles?.recorder
        let directory = writingDirectory
        let pendingDirectory = writingPendingDirectory
        let appSupportRoot = self.appSupportRoot
        let filesDeleted: Bool
        if let recorder {
            filesDeleted = await Task.detached(priority: .userInitiated) { recorder.deleteAll() }.value
        } else {
            filesDeleted = await WritingDayFileRecorder.deleteStoredWriting(
                in: directory(),
                pendingDirectory: pendingDirectory()
            )
        }
        let legacyResult = await Task.detached(priority: .userInitiated) {
            LegacyWritingDataCleanup.cleanUp(appSupportRoot: appSupportRoot())
        }.value
        let allDeleted = filesDeleted && legacyResult.succeeded
        applyRunState()
        NotificationCenter.default.post(name: .writingRuntimeStateDidChange, object: nil)
        log("WRITING | delete all writing: \(allDeleted ? "done" : "incomplete")")
        return allDeleted
    }

    func storageUsage() async -> WritingStorageUsage {
        let directory = writingDirectory
        return await Task.detached(priority: .utility) {
            WritingStorageUsage(
                savedWritingBytes: WritingStorageUsage.dayFileBytes(in: directory())
            )
        }.value
    }

    // MARK: - Keyboard setup

    func keyboardState(
        previous: WritingKeyboardSetupState? = nil,
        isCurrent: @escaping @MainActor () -> Bool
    ) async -> WritingKeyboardState? {
        guard !Task.isCancelled, let admission = keyboardActionAdmission else { return nil }
        let current: @MainActor () -> Bool = { [weak self] in
            !Task.isCancelled && self?.keyboardActionAdmission == admission && isCurrent()
        }
        let provider = await inputSources.prepareTrustedProvider(isCurrent: current)
        guard current() else { return nil }
        let installed = Self.keyboardIsInstalled
        let firstInstalled = keyboardFirstInstalledThisLoginSession
        let refresh: WritingKeyboardInputSource.Refresh
        if let provider {
            refresh = WritingKeyboardInputSource.refresh(
                using: provider, previous: previous,
                firstInstalledThisLoginSession: firstInstalled,
                selectedOnce: Self.appDefaults().bool(forKey: Self.keyboardFirstSetupKey)
            )
        } else {
            refresh = .init(state: .resolve(
                enabled: false,
                selected: false,
                firstInstalledThisLoginSession: firstInstalled
            ), selectSucceeded: nil)
        }
        guard current() else { return nil }
        if let selected = refresh.selectSucceeded {
            let succeeded = selected && refresh.state == .selected
            log("WRITING | keyboard select after it was added: \(succeeded ? "selected" : "not selected")")
        }
        if refresh.state == .selected {
            Self.appDefaults().set(true, forKey: Self.keyboardFirstSetupKey)
        }
        let enabled = refresh.state == .selected || refresh.state == .enabledNotSelected
        return WritingKeyboardState(
            installed: installed,
            enabled: enabled,
            selected: refresh.state == .selected,
            setup: installed || enabled ? refresh.state : nil
        )
    }

    @discardableResult
    func turnOnKeyboard(openSettingsOnFailure: Bool = false) async -> Bool {
        guard !Task.isCancelled, let admission = keyboardActionAdmission else { return false }
        let installed = await installKeyboardRecordingFirstInstall()
        guard !Task.isCancelled, keyboardActionAdmission == admission else { return false }
        guard installed else {
            if openSettingsOnFailure { keyboardInstaller.openKeyboardSettings() }
            return false
        }
        let current: @MainActor () -> Bool = { [weak self] in
            !Task.isCancelled && self?.keyboardActionAdmission == admission
        }
        guard let selected = await enableAndSelectKeyboard(isCurrent: current), current() else { return false }
        if !selected, openSettingsOnFailure {
            keyboardInstaller.openKeyboardSettings()
        }
        return selected
    }

    func installKeyboardRecordingFirstInstall() async -> Bool {
        let task = keyboardInstallTask ?? startKeyboardInstall()
        let result = await task.value
        return result == .installed || result == .alreadyInstalled
    }

    private func installKeyboard() {
        Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled, let admission = self.keyboardActionAdmission,
                  await self.installKeyboardRecordingFirstInstall(),
                  self.keyboardActionAdmission == admission,
                  self.isRunning,
                  !Self.appDefaults().bool(forKey: Self.keyboardFirstSetupKey) else { return }
            await self.enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: true, admission: admission)
        }
    }

    private func enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: Bool, admission: Int) async {
        let current: @MainActor () -> Bool = { [weak self] in
            guard let self else { return false }
            return !Task.isCancelled && self.keyboardActionAdmission == admission && self.isRunning
                && !Self.appDefaults().bool(forKey: Self.keyboardFirstSetupKey)
        }
        guard current(), let selected = await enableAndSelectKeyboard(isCurrent: current) else { return }
        if !selected, retryAfterDelay, current() {
            try? await Task.sleep(for: .seconds(1))
            guard current() else { return }
            await enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: false, admission: admission)
        }
    }

    private func startKeyboardInstall() -> Task<GhostKeyboardInstallerHost.KeyboardInstallResult, Never> {
        let installer = keyboardInstaller
        let task = Task { @MainActor [weak self] () -> GhostKeyboardInstallerHost.KeyboardInstallResult in
            let wasInstalled = Self.keyboardIsInstalled
            let result = await installer.installOrUpdateIfNeeded()
            guard let self else { return result }
            self.keyboardInstallTask = nil
            self.log("WRITING | keyboard install: \(result)")
            if result == .installed, !wasInstalled {
                WritingKeyboardFirstInstall.record(
                    currentSession: WritingLoginSession.currentIdentifier(),
                    defaults: Self.appDefaults()
                )
            }
            return result
        }
        keyboardInstallTask = task
        return task
    }

    private func enableAndSelectKeyboard(isCurrent: @escaping @MainActor () -> Bool) async -> Bool? {
        guard !Task.isCancelled, isCurrent() else { return nil }
        let provider = await inputSources.prepareTrustedProvider(isCurrent: isCurrent)
        guard !Task.isCancelled, isCurrent() else { return nil }
        let enable = provider.map { WritingKeyboardInputSource.enable(using: $0) } ?? .notRegistered
        guard !Task.isCancelled, isCurrent() else { return nil }
        switch enable {
        case .enabled:
            log("WRITING | keyboard enable: enabled")
        case .alreadyEnabled:
            log("WRITING | keyboard enable: already enabled")
        case .needsUserToAdd:
            log("WRITING | keyboard enable: still off after TISEnableInputSource; add in Keyboard settings")
        case .notRegistered:
            log("WRITING | keyboard enable: not registered")
        case let .failed(status):
            log("WRITING | keyboard enable: TISEnableInputSource failed (\(status))")
        }
        guard enable.isEnabled, let provider else {
            log("WRITING | keyboard select: skipped, keyboard not enabled")
            return false
        }
        guard !Task.isCancelled, isCurrent() else { return nil }
        let selected = provider.selectTrustedSource()
        guard !Task.isCancelled, isCurrent() else { return nil }
        log("WRITING | keyboard select: \(selected ? "selected" : "not selected")")
        if selected {
            Self.appDefaults().set(true, forKey: Self.keyboardFirstSetupKey)
        }
        return selected
    }

    private func ensureHistoryIdentifiers() {
        let settings = Self.settings()
        if settings.personalHistoryIdentifier == nil {
            settings.personalHistoryIdentifier = UUID().uuidString
        }
        if settings.personalHistoryConsentIdentifier == nil {
            settings.personalHistoryConsentIdentifier = UUID().uuidString
        }
    }
}
