import AppKit
import CoreGraphics
import Foundation

/// Whether the Writing keyboard is on this Mac and in use.
struct WritingKeyboardState: Equatable {
    /// `~/Library/Input Methods/Transcripted Keyboard.app` exists.
    let installed: Bool
    /// Signed by this app's team, registered, and enabled in Input Sources.
    let enabled: Bool
    /// The current input source.
    let selected: Bool
}

/// Hosts Writing's runtime inside Transcripted: the socket the keyboard talks
/// to, the `llama-server` helper and its model, Screen Memory, personal
/// history, and the keyboard installer. It replaces the lifecycle half of
/// Tilde's `AppDelegate` and `TildeApplicationState` at `f36f6562`
/// (docs/writing-port-ledger.md), minus Tilde's dev-only launch modes, its
/// install-location check, its launch-time Accessibility prompt, its login
/// item (Transcripted's `LaunchAtLoginController` owns that), its status
/// menu and its setup window.
///
/// `TranscriptedAppState` owns one and calls `startIfEnabled(log:)` from
/// `initialize()`. It runs once the Writing tab's setup is done and Save my
/// writing or Autocomplete is on (`WritingActivation`), or behind the phase 2
/// `WritingDebugEnabled` default. The Writing tab calls `applyRunState()`
/// after "Turn on writing" and after a feature toggle, which starts it or,
/// with both features off, stops it until they come back on.
///
/// Autocomplete alone needs the model, the `llama-server` helper and Screen
/// Memory; with only Save my writing on, none of them run.
///
/// Nothing here relaunches the app. Tilde relaunched itself after a model
/// switch and after the Screen Recording grant; here a switch restarts only
/// the helper, and the grant only changes state the UI reads.
@MainActor
final class WritingController {
    /// Tilde's app-owned keys (`TildeSettings.AppKey`, the model choice) live
    /// in this suite, apart from Transcripted's `.standard`. The keyboard's
    /// keys stay in the keyboard's own domain, shared with its process.
    nonisolated static let appSuiteName = "com.justinbetker.draft.writing"
    /// Phase 2's switch in Transcripted's `.standard` defaults, kept for
    /// development: it starts Writing even before setup finishes.
    nonisolated static let debugEnabledKey = "WritingDebugEnabled"
    /// Keyboard-suite flag: when set, the keyboard stops opening the app
    /// after a failed request. Tilde's name, which the keyboard reads.
    nonisolated static let quietQuitKey = "GhostBrainQuietQuit"

    /// Set by `noteTerminationRequest()` when macOS itself is quitting the
    /// app (logout, restart, shutdown). Only a quit the user chose sets the
    /// keyboard's quiet-quit flag.
    private(set) static var terminationIsSystemInitiated = false

    /// Call first thing in `applicationShouldTerminate`. The system attaches
    /// a quit reason to the quit Apple event it sends at logout, restart and
    /// shutdown; ⌘Q, the menu Quit items and Sparkle's relaunch don't.
    static func noteTerminationRequest() {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let hasSystemQuitReason = event?.eventID == AEEventID(kAEQuitApplication)
            && event?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason)) != nil
        terminationIsSystemInitiated = hasSystemQuitReason
    }
    /// App-suite flag: the keyboard was enabled and selected once. Later
    /// starts leave Input Sources to the user.
    nonisolated static let keyboardFirstSetupKey = "KeyboardEnabledAndSelectedOnce"
    private nonisolated static let automaticTerminationReason = "Transcripted Writing serves the keyboard"

    nonisolated static var defaultModelRoot: URL {
        FileManager.default.transcriptedAppSupportRootURL
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("writing", isDirectory: true)
    }

    nonisolated static func appDefaults() -> UserDefaults {
        UserDefaults(suiteName: appSuiteName) ?? .standard
    }

    /// A fresh view of every Writing setting, read on each use like Tilde's
    /// `TildeSettings()`, so a change from either process applies at once.
    nonisolated static func settings() -> TildeSettings {
        TildeSettings(
            keyboard: UserDefaults(suiteName: TildeSettings.keyboardSuiteName),
            app: appDefaults()
        )
    }

    /// Writing's own preferences (Save my writing, personalized suggestions,
    /// the app scope), read fresh on each use like `settings()`.
    nonisolated static func preferences() -> WritingPreferences {
        WritingPreferences(
            keyboard: UserDefaults(suiteName: TildeSettings.keyboardSuiteName),
            app: appDefaults()
        )
    }

    // MARK: - Read-only state for the Writing tab

    let physicalMemoryBytes: UInt64
    /// The model Writing runs: the saved choice, or Gemma when this Mac
    /// can't run the saved one.
    private(set) var selectedModel: TildeModelChoice
    /// The socket server is up and the runtime is live.
    private(set) var isRunning = false
    private(set) var keyboardInstallResult: GhostKeyboardInstallerHost.KeyboardInstallResult?
    /// What `TISEnableInputSource` returned on the first setup, if it ran.
    private(set) var keyboardEnableResult: WritingKeyboardInputSource.EnableResult?
    /// Whether selecting the keyboard on the first setup worked, if it ran.
    private(set) var keyboardSelectSucceeded: Bool?

    var isQwenEligible: Bool {
        WritingModelEligibility.isEligible(.qwen35B9B, physicalMemoryBytes: physicalMemoryBytes)
    }

    var modelState: ModelState? { runtime?.models.manager.state }

    var modelProgress: Double? {
        guard case let .downloading(receivedBytes, totalBytes) = modelState, totalBytes > 0 else {
            return nil
        }
        return min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
    }

    var runtimeState: LlamaRuntimeSnapshot? { runtime?.llamaServerHost.snapshot }

    var screenRecordingGranted: Bool { ScreenRecordingPermission.isGranted() }

    var saveMyWritingEnabled: Bool { Self.preferences().saveMyWritingEnabled }
    /// Set while Save my writing can't write its day files (for example a
    /// capture library on a NAS that won't take owner-only permissions);
    /// `nil` again after the next write that works. The Writing tab shows
    /// "Writing couldn't be saved to this folder." The error case and a
    /// time only, never a path.
    var saveMyWritingProblem: WritingDayFileRecorder.WriteFailure? { runtime?.dayFiles.recorder.lastWriteFailure }
    /// Tilde's suggestions switch (`GhostSuggestionsEnabled`), on by default.
    var autocompleteEnabled: Bool { Self.settings().suggestionsEnabled }
    var personalizedSuggestionsEnabled: Bool { Self.preferences().personalizedSuggestionsEnabled }
    var appScope: WritingAppScope { Self.preferences().appScope }
    /// "Turn on writing" finished at least once.
    var setupCompleted: Bool { WritingSetupState.isCompleted(defaults: Self.appDefaults()) }
    /// Autocomplete and Save my writing are paused until then.
    var pausedUntil: Date? { Self.settings().pausedUntil }

    /// The prompt was shown at least once. With `screenRecordingGranted`
    /// still false, the UI asks the user to reopen Transcripted (macOS
    /// usually applies the grant to a new process only).
    var screenRecordingRequested: Bool { Self.settings().screenRecordingRequested }

    /// Expensive: validates this app's and the keyboard's code signatures,
    /// and Text Input Sources wants the main thread. Call it when a screen
    /// needs it, not on a timer.
    func keyboardState() -> WritingKeyboardState {
        let installedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
            .appendingPathComponent(TildeProductProfile.current.inputMethodInstalledBundleName)
            .path
        let status = keyboardInstaller.inputSourceStatus()
        return WritingKeyboardState(
            installed: FileManager.default.fileExists(atPath: installedPath),
            enabled: status != .missing,
            selected: status == .selected
        )
    }

    // MARK: - Runtime

    private struct Runtime {
        let models: WritingModelManagerBox
        let llamaServerHost: LlamaServerProcessHost
        /// Keeps the frontmost app's register scaffold in the helper's
        /// prompt cache so the first suggestion after launch, a helper
        /// restart, or an app switch pays only for the scene block and field
        /// text.
        let scaffoldPrewarmer: ScaffoldPrewarmer
        let personalHistoryController: PersonalHistoryController
        /// Memory-only screen context. `enabled` reads the settings live on
        /// every trigger, so flipping the toggle off takes effect on the very
        /// next trigger. `excludedApps` is the SAME list Personal History
        /// uses, per the covenant's "shared with Personal History" rule.
        let screenCaptureService: ScreenCaptureService
        /// Save my writing's Markdown day files.
        let dayFiles: WritingDayFileWriter
    }

    private let modelRoot: URL
    /// `<capture-library>/writing`, for the day files and Delete all writing.
    private let writingDirectory: @Sendable () -> URL
    private let keyboardInstaller = GhostKeyboardInstallerHost()
    private var runtime: Runtime?
    /// Rebuilt on a model switch: its served configuration is per model.
    private var ghostBrainServerHost: GhostBrainServerHost?
    /// The model the runtime is built for. Differs from `selectedModel` only
    /// while a switch is between persisting and rebuilding.
    private var activeModel: TildeModelChoice?
    private var log: (String) -> Void = { _ in }
    private var frontmostAppObserver: NSObjectProtocol?
    // Backstop for `frontmostAppObserver`: NSWorkspace only tells us when a
    // DIFFERENT app becomes frontmost, never when the focused window changes
    // within the SAME app (e.g. Cmd+`, clicking a different document window,
    // a new tab-window). This timer polls the true frontmost window's
    // identity — no new permission needed, `CGWindowListCopyWindowInfo`'s
    // layer/pid/window-number fields are unrestricted — and fires the same
    // window-changed trigger on any change, cross- or same-app alike.
    private var windowIdentityPollTimer: Timer?
    private var lastFrontWindowIdentity: FrontWindowIdentity?
    /// Model preparation at start, or a model switch. At most one runs.
    private var modelTask: Task<Void, Never>?
    private var modelTaskID: UUID?
    private var wakeTask: Task<Void, Never>?
    private var hasStarted = false
    /// Set by `stop()` at quit. Nothing starts after it.
    private var isTerminated = false
    /// Set by `startIfEnabled(log:)`. Until launch allows it, the Writing tab
    /// can't start Writing, so automated launches never do.
    private var activationAllowed = false
    /// The model and helper run for Autocomplete. Follows the Autocomplete
    /// switch while Writing runs.
    private var autocompleteRuntimeActive = false

    init(
        physicalMemoryBytes: UInt64 = ProcessInfo.processInfo.physicalMemory,
        modelRoot: URL = WritingController.defaultModelRoot,
        writingDirectory: @escaping @Sendable () -> URL = WritingDayFileWriter.defaultDirectory
    ) {
        self.physicalMemoryBytes = physicalMemoryBytes
        self.modelRoot = modelRoot
        self.writingDirectory = writingDirectory
        // Transcripted's bundles always resolve to the production profile,
        // so the saved choice is never nil here; Gemma is Tilde's default.
        self.selectedModel = WritingModelEligibility.resolvedChoice(
            for: TildeProductProfile.current,
            defaults: Self.appDefaults(),
            physicalMemoryBytes: physicalMemoryBytes
        ) ?? .gemma4E2B
    }

    // MARK: - Lifecycle

    /// Launch: keeps the log sink for later starts, then starts Writing if it
    /// should run (`applyRunState()`).
    func startIfEnabled(log: @escaping (String) -> Void) {
        self.log = log
        activationAllowed = true
        applyRunState()
    }

    /// Brings the runtime in line with the saved setup: starts it when
    /// `WritingActivation` says so, stops it when both features are off, and
    /// starts or stops the model and helper as Autocomplete turns on or off.
    /// The Writing tab calls it after every change it saves.
    func applyRunState() {
        guard activationAllowed, !isTerminated else { return }
        let settings = Self.settings()
        let shouldRun = WritingActivation.shouldRun(
            setupCompleted: setupCompleted,
            saveMyWriting: settings.personalHistoryEnabled,
            autocomplete: settings.suggestionsEnabled,
            debugEnabled: UserDefaults.standard.bool(forKey: Self.debugEnabledKey)
        )
        if !shouldRun {
            if hasStarted {
                log("WRITING | both features off; stopping")
                tearDown()
            }
        } else if hasStarted {
            applyAutocompleteToRuntime()
        } else {
            start(log: log)
        }
    }

    /// Tilde's startup order (`AppDelegate.applicationDidFinishLaunching`).
    /// Runs once per start; after `stop()` nothing starts again.
    func start(log: @escaping (String) -> Void = { _ in }) {
        guard !hasStarted, !isTerminated else { return }
        hasStarted = true
        self.log = log

        let settings = Self.settings()
        let models = WritingModelManagerBox(makeModelManager(for: selectedModel))
        let llamaServerHost = LlamaServerProcessHost(
            port: TildeProductProfile.current.llamaServerPort,
            modelFileProvider: { models.manager.verifiedInstalledModelFile() }
        )
        let runtime = Runtime(
            models: models,
            llamaServerHost: llamaServerHost,
            scaffoldPrewarmer: ScaffoldPrewarmer(baseURL: llamaServerHost.baseURL),
            personalHistoryController: PersonalHistoryController(
                store: EncryptedPersonalHistoryStore(),
                settings: settings,
                diagnostics: .shared
            ),
            // Screen Memory serves Autocomplete only: with it off, nothing
            // on screen is read, even with Screen Recording granted.
            screenCaptureService: ScreenCaptureService(
                enabled: {
                    let settings = Self.settings()
                    // Pause stops screen reading too, not just suggestions.
                    return settings.screenMemoryEnabled && settings.suggestionsEnabled
                        && settings.pausedUntil == nil
                },
                excludedApps: { Self.settings().personalHistoryExcludedApps }
            ),
            dayFiles: WritingDayFileWriter(
                directory: writingDirectory,
                preferences: { Self.preferences() },
                problemStarted: { [weak self] error in
                    self?.log("WRITING | save my writing: day file write failed (\(error))")
                }
            )
        )
        self.runtime = runtime
        activeModel = selectedModel

        // The process-held runtime lock makes this the only socket/model
        // owner. Tilde quit when it lost the lock; Transcripted keeps running
        // and leaves Writing off.
        let server = makeServerHost(runtime, model: selectedModel)
        guard server.start() else {
            DiagnosticsLog.shared.record("duplicate-instance", metadata: [:])
            log("WRITING | socket server did not start (runtime lock held); Writing stays off")
            return
        }
        ghostBrainServerHost = server
        isRunning = true
        runtime.dayFiles.start()

        // The keyboard is only as smart as this process is alive.
        ProcessInfo.processInfo.disableAutomaticTermination(Self.automaticTerminationReason)

        startObservingFrontmostAppForScreenMemory()
        let prewarmer = runtime.scaffoldPrewarmer
        prewarmer.noteFrontmostApp(bundleIdentifier: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        llamaServerHost.setReadinessObserver { ready in
            if ready { prewarmer.noteHelperReady() } else { prewarmer.noteHelperUnavailable() }
        }
        if llamaServerHost.snapshot == .ready { prewarmer.noteHelperReady() }
        // No Accessibility prompt: Transcripted already holds Accessibility
        // for paste-back, and Writing asks for nothing at launch. The model
        // (a 3.4 or 5.6 GB download) and the helper are Autocomplete's only.
        if settings.suggestionsEnabled {
            autocompleteRuntimeActive = true
            startModelPreparation()
        }
        installKeyboard()
        // Any start means the brain is wanted again: lift the keyboard's
        // stay-quiet flag from a deliberate quit.
        UserDefaults(suiteName: TildeSettings.keyboardSuiteName)?.removeObject(forKey: Self.quietQuitKey)
        DiagnosticsLog.shared.record("launch", metadata: ["model": runtime.models.manager.descriptor.identifier])
        log("WRITING | started with \(selectedModel.rawValue)")
        emitDailyCountsIfDue()
    }

    /// Tilde's stop order (`AppDelegate.applicationWillTerminate`). Safe to
    /// call more than once. `TranscriptedAppState.shutdown()` calls it on
    /// every graceful quit, which is when the user quits on purpose; a crash
    /// or force quit skips it, so the keyboard still summons the app back.
    func stop() {
        isTerminated = true
        guard hasStarted else { return }
        tearDown()
    }

    /// The stop itself, shared by the quit and by turning both features off.
    /// A later `start` builds a fresh runtime.
    private func tearDown() {
        hasStarted = false
        autocompleteRuntimeActive = false
        let wasRunning = isRunning
        isRunning = false
        if wasRunning && !Self.terminationIsSystemInitiated {
            // Tilde's Quit sets this before terminating. Written before the
            // socket closes, so a request that fails from here on already
            // finds it and doesn't reopen the app on its way out. Logout,
            // restart and shutdown don't set it: after a reboot without
            // launch at login, the keyboard must still be able to wake us.
            UserDefaults(suiteName: TildeSettings.keyboardSuiteName)?.set(true, forKey: Self.quietQuitKey)
        }
        // Deaths must leave a trace: flush, or the exit races the log queue.
        DiagnosticsLog.shared.record("shutdown", metadata: [:])
        DiagnosticsLog.shared.flush()
        ghostBrainServerHost?.stop()
        ghostBrainServerHost = nil
        // The last open entry goes to its day file before the app quits.
        runtime?.dayFiles.stop()
        // A download in flight stops too; its resumable partial stays.
        runtime?.models.manager.cancel()
        if let host = runtime?.llamaServerHost {
            if isTerminated {
                // The quit waits for the helper, as Tilde's did.
                host.stop()
            } else {
                // Up to 1.2 s of TERM-then-KILL; keep it off the main thread.
                Task.detached(priority: .userInitiated) { host.stop() }
            }
        }
        if let frontmostAppObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(frontmostAppObserver)
            self.frontmostAppObserver = nil
        }
        windowIdentityPollTimer?.invalidate()
        windowIdentityPollTimer = nil
        lastFrontWindowIdentity = nil
        modelTask?.cancel()
        modelTask = nil
        modelTaskID = nil
        wakeTask?.cancel()
        wakeTask = nil
        runtime = nil
        activeModel = nil
        if wasRunning {
            ProcessInfo.processInfo.enableAutomaticTermination(Self.automaticTerminationReason)
        }
    }

    /// Tilde had no wake handling. A helper that exited is restarted by its
    /// host already; this also catches one that survived sleep but stopped
    /// answering, and a runtime that had given up.
    func handleSystemWake() {
        guard isRunning, let runtime else { return }
        emitDailyCountsIfDue()
        // With Autocomplete off there's no helper to look after.
        guard autocompleteRuntimeActive else { return }
        wakeTask?.cancel()
        wakeTask = Task { @MainActor [weak self] in
            let host = runtime.llamaServerHost
            var healthy = false
            for attempt in 0..<WritingHelperWakePolicy.healthProbeAttempts {
                if attempt > 0 { try? await Task.sleep(for: .seconds(1)) }
                guard !Task.isCancelled, host.snapshot == .ready else { break }
                healthy = await WritingHelperHealthProbe.isHealthy(host)
                if healthy { break }
            }
            // A model preparation or switch owns the helper while it runs.
            guard let self, !Task.isCancelled, self.isRunning, self.autocompleteRuntimeActive,
                  self.modelTask == nil else { return }
            let snapshot = host.snapshot
            let action = WritingHelperWakePolicy.action(
                modelReady: runtime.models.manager.state.isReady,
                snapshot: snapshot,
                helperHealthy: healthy
            )
            self.log("WRITING | wake: helper \(Self.describe(snapshot)), \(action == .restart ? "restarting" : "left running")")
            guard action == .restart else { return }
            DiagnosticsLog.shared.record("llama-server-wake-restart", metadata: [:])
            await Task.detached(priority: .utility) { host.stop() }.value
            guard !Task.isCancelled, self.isRunning, self.autocompleteRuntimeActive,
                  self.modelTask == nil else { return }
            host.start()
        }
    }

    /// Yesterday's count-only `writing_daily_counts`, at most once a day,
    /// from the text-free outcome ledger summary.
    private func emitDailyCountsIfDue() {
        let ledgerURL = TildeLocalOutcomeStores.eventURL()
        let preferences = Self.preferences()
        let setup = WritingAnalytics.Setup(
            saveEnabled: preferences.saveMyWritingEnabled,
            autocompleteEnabled: Self.settings().suggestionsEnabled,
            appScope: preferences.appScope.mode == .all ? .all : .picked,
            model: selectedModel
        )
        WritingAnalytics.emitDailyCountsIfDue(defaults: Self.appDefaults(), setup: setup) { day in
            let facts = OutcomeLedgerReader.facts(in: OutcomeLedgerReader.readTail(url: ledgerURL))
            let summary = OutcomeLedgerSummary.make(facts: facts.filter { $0.occurredAt < day.end }, now: day.start)
            return WritingAnalytics.DailyCounts(
                suggestionsShown: summary.ghostsShownToday,
                suggestionsAccepted: summary.acceptedGhostsToday,
                acceptedCharacters: summary.keystrokesSavedToday
            )
        }
    }

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
        log("WRITING | paused for \(Int(interval / 60)) min")
    }

    func resume() {
        Self.settings().resume()
        log("WRITING | resumed")
    }

    /// One scope for capture, the day files, Screen Memory context and
    /// suggestions. The keyboard picks it up on its next key.
    func setAppScope(_ scope: WritingAppScope) {
        Self.preferences().appScope = scope
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

    /// The Writing tab's keyboard step: install or update, register, enable
    /// and select, every time it's asked (the launch path does the enable and
    /// select only on the first setup). With `openSettingsOnFailure`, falls
    /// back to Keyboard settings when it can't. `true` once the keyboard is
    /// the selected input source.
    @discardableResult
    func turnOnKeyboard(openSettingsOnFailure: Bool = true) -> Bool {
        let result = keyboardInstaller.installOrUpdateIfNeeded()
        keyboardInstallResult = result
        log("WRITING | keyboard install: \(result)")
        guard result == .installed || result == .alreadyInstalled else {
            if openSettingsOnFailure { keyboardInstaller.openKeyboardSettings() }
            return false
        }
        let enable = WritingKeyboardInputSource.enable()
        keyboardEnableResult = enable
        log("WRITING | keyboard enable (TISEnableInputSource): \(enable)")
        let selected = (enable == .enabled || enable == .alreadyEnabled)
            && keyboardInstaller.selectInputSourceIfAvailable()
        keyboardSelectSucceeded = selected
        log("WRITING | keyboard select: \(selected ? "selected" : "not selected")")
        if selected {
            Self.appDefaults().set(true, forKey: Self.keyboardFirstSetupKey)
        } else if openSettingsOnFailure {
            keyboardInstaller.openKeyboardSettings()
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

    // MARK: - Model

    private func makeModelManager(for model: TildeModelChoice) -> ModelManager {
        ModelManager(
            descriptor: TildeModelSelection.descriptor(
                for: TildeProductProfile.current,
                productionChoice: model
            ),
            rootDirectory: modelRoot
        )
    }

    private func startModelPreparation() {
        guard let runtime else { return }
        let previous = modelTask
        runModelTask { controller in
            // Turning Autocomplete back on right after turning it off: let
            // that stop finish before this start.
            await previous?.value
            guard !Task.isCancelled, controller.isRunning, controller.autocompleteRuntimeActive else { return }
            let ready = await controller.prepareCurrentModel()
            guard !Task.isCancelled, controller.isRunning, controller.autocompleteRuntimeActive else { return }
            if ready { runtime.llamaServerHost.start() }
        }
    }

    /// Autocomplete on: prepare the model (downloading it if needed) and
    /// start the helper. Off: stop the download and the helper.
    private func applyAutocompleteToRuntime() {
        guard isRunning, let runtime else { return }
        let wanted = Self.settings().suggestionsEnabled
        guard wanted != autocompleteRuntimeActive else { return }
        autocompleteRuntimeActive = wanted
        if wanted {
            log("WRITING | autocomplete on; preparing \(selectedModel.rawValue)")
            startModelPreparation()
        } else {
            log("WRITING | autocomplete off; stopping the model and helper")
            let manager = runtime.models.manager
            runModelTask { controller in
                manager.cancel()
                await controller.stopHelper()
            }
        }
    }

    /// Adopts Tilde's copy when this model isn't installed yet, then lets
    /// `ModelManager` check, download and verify it. `true` once it's ready.
    fileprivate func prepareCurrentModel() async -> Bool {
        guard let runtime else { return false }
        let manager = runtime.models.manager
        let descriptor = manager.descriptor
        let modelDirectory = manager.modelDirectory
        let tildeModelsRoot = WritingModelAdoption.defaultTildeModelsRoot
        let adoption = await Task.detached(priority: .utility) {
            WritingModelAdoption.adoptIfNeeded(
                descriptor: descriptor,
                modelDirectory: modelDirectory,
                tildeModelsRoot: tildeModelsRoot
            )
        }.value
        if adoption != .alreadyInstalled {
            log("WRITING | Tilde model adoption for \(descriptor.identifier): \(adoption)")
        }
        guard !Task.isCancelled else { return false }
        manager.prepare()
        await manager.waitUntilSettled()
        let state = manager.state
        log("WRITING | model \(descriptor.identifier): \(Self.describe(state))")
        return state.isReady
    }

    private func runModelTask(_ work: @escaping @MainActor (WritingController) async -> Void) {
        modelTask?.cancel()
        let id = UUID()
        modelTaskID = id
        modelTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await work(self)
            if self.modelTaskID == id {
                self.modelTask = nil
                self.modelTaskID = nil
            }
        }
    }

    // MARK: - Socket server

    private func makeServerHost(_ runtime: Runtime, model: TildeModelChoice) -> GhostBrainServerHost {
        let profile = TildeProductProfile.current
        let completionProfile = TildeModelSelection.completionProfile(for: profile, productionChoice: model)
        // One configuration for both processes: the build's interaction
        // policy, the model choice's generator and decision policies.
        let configuration = TildeEffectiveConfiguration.resolve(
            build: profile,
            completionProfile: completionProfile,
            modelIdentifier: runtime.models.manager.descriptor.identifier
        )
        // Phrase continuations go to the llama engine. Mid-word completion
        // belongs only to the keyboard's system spell-checker path.
        return GhostBrainServerHost(
            runtime: runtime.llamaServerHost,
            personalHistory: WritingPausableIngest(
                base: WritingHistoryIngest(
                    personalHistory: runtime.personalHistoryController,
                    dayFiles: runtime.dayFiles.recorder,
                    appScope: { Self.preferences().appScope }
                ),
                isPaused: { Self.settings().pausedUntil != nil }
            ),
            sceneProvider: Self.sceneProvider(for: runtime.screenCaptureService),
            targetProvider: { appBundleIdentifier, fieldSessionIdentifier in
                Self.suggestionTargetProvider(appBundleIdentifier, fieldSessionIdentifier)
            },
            // A bare activity pulse only — see GhostBrainServerHost's doc comment.
            onCompletionActivity: Self.completionActivityHandler(
                for: runtime.screenCaptureService,
                prewarmer: runtime.scaffoldPrewarmer
            ),
            onScreenMemoryEvent: Self.screenMemoryEventHandler(for: runtime.screenCaptureService),
            suggestionsGate: { Self.suggestionsGate(appBundleIdentifier: $0) },
            personalSuggestionsGate: { Self.personalSuggestionsGate() },
            personalNextWordProvider: Self.personalNextWordProvider(for: runtime.personalHistoryController),
            configuration: configuration,
            productProfile: completionProfile
        )
    }

    /// A model switch swaps the model store and the served configuration.
    /// The socket goes away for a moment; the keyboard treats that like the
    /// helper being down, which it is for the whole switch anyway.
    fileprivate func rebuildRuntime(for model: TildeModelChoice) {
        guard let runtime else { return }
        // The superseded manager's download would otherwise keep running.
        runtime.models.manager.cancel()
        runtime.models.manager = makeModelManager(for: model)
        activeModel = model
        ghostBrainServerHost?.stop()
        let server = makeServerHost(runtime, model: model)
        if server.start() {
            ghostBrainServerHost = server
        } else {
            ghostBrainServerHost = nil
            log("WRITING | socket server did not restart after the model switch")
        }
    }

    fileprivate func persistModelChoice(_ model: TildeModelChoice) {
        TildeModelSelection.persist(model, defaults: Self.appDefaults())
        selectedModel = model
        DiagnosticsLog.shared.record("model-selected", metadata: ["model": model.rawValue])
    }

    fileprivate func stopHelper() async {
        guard let host = runtime?.llamaServerHost else { return }
        // Up to 1.2 s of TERM-then-KILL; keep it off the main thread.
        await Task.detached(priority: .userInitiated) { host.stop() }.value
    }

    fileprivate func startHelper() {
        guard isRunning, autocompleteRuntimeActive else { return }
        runtime?.llamaServerHost.start()
    }

    // MARK: - Keyboard

    /// Install or update, register, and the first time only, enable and
    /// select. Every result lands in the state above and the app log.
    private func installKeyboard() {
        let result = keyboardInstaller.installOrUpdateIfNeeded()
        keyboardInstallResult = result
        log("WRITING | keyboard install: \(result)")
        guard result == .installed || result == .alreadyInstalled,
              !Self.appDefaults().bool(forKey: Self.keyboardFirstSetupKey) else { return }
        enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: true)
    }

    private func enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: Bool) {
        let enable = WritingKeyboardInputSource.enable()
        keyboardEnableResult = enable
        log("WRITING | keyboard enable (TISEnableInputSource): \(enable)")
        let selected = (enable == .enabled || enable == .alreadyEnabled)
            && keyboardInstaller.selectInputSourceIfAvailable()
        keyboardSelectSucceeded = selected
        log("WRITING | keyboard select: \(selected ? "selected" : "not selected")")
        if selected {
            Self.appDefaults().set(true, forKey: Self.keyboardFirstSetupKey)
        } else if retryAfterDelay {
            // Text Input Sources can take a moment to list a just-registered
            // or just-enabled source. One retry; after that, the next start.
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRunning else { return }
                self.enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: false)
            }
        }
    }

    // MARK: - Screen Memory observation

    /// The window-change trigger: macOS already tells every app when a
    /// different app becomes frontmost, so Screen Memory needs no IME/socket
    /// changes to observe it — `NSWorkspace` gives it directly. This alone
    /// misses same-app window changes (see `windowIdentityPollTimer`'s doc
    /// comment), so a lightweight poll backs it up.
    private func startObservingFrontmostAppForScreenMemory() {
        guard let runtime else { return }
        let prewarmer = runtime.scaffoldPrewarmer
        let screenCaptureService = runtime.screenCaptureService
        frontmostAppObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { notification in
            let activated = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            prewarmer.noteFrontmostApp(bundleIdentifier: activated?.bundleIdentifier)
            Task {
                let target = Self.currentTypingTarget(sessionIdentifier: "")
                guard Self.preferences().allows(appBundleIdentifier: target?.bundleIdentifier) else { return }
                await screenCaptureService.noteWindowChanged(target: target)
            }
        }
        lastFrontWindowIdentity = Self.currentFrontWindowIdentity()
        windowIdentityPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollFrontWindowIdentityForScreenMemory() }
        }
    }

    /// Fires the window-changed trigger whenever the true frontmost window
    /// (by process + `CGWindowID`) differs from the last poll — this catches
    /// a same-app window switch that `NSWorkspace` cannot see. The service's
    /// central cadence gate coalesces overlapping triggers before capture.
    private func pollFrontWindowIdentityForScreenMemory() {
        guard let screenCaptureService = runtime?.screenCaptureService else { return }
        let identity = Self.currentFrontWindowIdentity()
        guard identity != lastFrontWindowIdentity else { return }
        lastFrontWindowIdentity = identity
        Task {
            let target = identity.map { Self.typingTarget(from: $0, sessionIdentifier: "") }
            guard Self.preferences().allows(appBundleIdentifier: target?.bundleIdentifier) else { return }
            await screenCaptureService.noteWindowChanged(target: target)
        }
    }

    struct FrontWindowIdentity: Equatable, Sendable {
        let ownerProcessIdentifier: pid_t
        let windowNumber: CGWindowID
        let bundleIdentifier: String?
    }

    /// The true frontmost on-screen window, system-wide, identified by owning
    /// process + window number — `CGWindowListCopyWindowInfo` documents its
    /// result as front-to-back ordered, so the first normal-layer (`0`)
    /// window found is frontmost. Deliberately does not request window
    /// names/titles: this only needs an identity to detect change, and
    /// nothing here reads or stores what the window is titled.
    private nonisolated static func currentFrontWindowIdentity() -> FrontWindowIdentity? {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let windowNumber = info[kCGWindowNumber as String] as? CGWindowID
            else { continue }
            return FrontWindowIdentity(
                ownerProcessIdentifier: pid,
                windowNumber: windowNumber,
                bundleIdentifier: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
            )
        }
        return nil
    }

    private nonisolated static func currentTypingTarget(
        sessionIdentifier: String
    ) -> TypingTargetIdentity? {
        currentFrontWindowIdentity().map {
            typingTarget(from: $0, sessionIdentifier: sessionIdentifier)
        }
    }

    private nonisolated static func typingTarget(
        from identity: FrontWindowIdentity,
        sessionIdentifier: String
    ) -> TypingTargetIdentity {
        TypingTargetIdentity(
            bundleIdentifier: identity.bundleIdentifier,
            processIdentifier: identity.ownerProcessIdentifier,
            windowIdentifier: identity.windowNumber,
            fieldSessionIdentifier: sessionIdentifier,
            generation: 0
        )
    }

    // MARK: - Server closures

    /// Screen Recording is required for any suggestion, and the request's app
    /// must be in the Writing scope; see `WritingSuggestionsGate` for the
    /// whole rule. Read fresh on every completion request (never cached), so
    /// a permission revoked or granted mid-session applies to the very next
    /// request.
    private nonisolated static func suggestionsGate(appBundleIdentifier: String?) -> Bool {
        WritingSuggestionsGate.allows(WritingSuggestionsGate.Inputs(
            preferences: preferences(),
            appBundleIdentifier: appBundleIdentifier,
            screenRecordingGranted: ScreenRecordingPermission.isGranted()
        ))
    }

    /// Tilde had one choice: Personal History on meant personal suggestions
    /// on. Transcripted splits them (decision 11): personalized suggestions
    /// are their own switch, off by default, and still need Save my writing,
    /// which is what the predictor learns from.
    private nonisolated static func personalSuggestionsGate() -> Bool {
        preferences().personalSuggestionsAllowed
    }

    /// `nonisolated` for the same reason `sceneProvider`/
    /// `completionActivityHandler` are: the closure captures and calls an
    /// actor-isolated method (`PersonalHistoryController.
    /// personalNextWordPrediction`) from inside a `@MainActor` type.
    /// Per-app exclusions are enforced on the other side of this closure,
    /// inside the controller — see its doc comment.
    private nonisolated static func personalNextWordProvider(
        for controller: PersonalHistoryController
    ) -> @Sendable ([String], String?) async -> PersonalNextWordPrediction? {
        { tailWords, appBundleIdentifier in
            await controller.personalNextWordPrediction(
                afterTailWords: tailWords,
                appBundleIdentifier: appBundleIdentifier
            )
        }
    }

    /// `nonisolated` so the closure it returns has no ambiguous isolation of
    /// its own to infer: the compiler cannot otherwise tell whether a closure
    /// written inside a `@MainActor` type belongs to the main actor or to
    /// `ScreenCaptureService`'s own actor.
    private nonisolated static func completionActivityHandler(
        for service: ScreenCaptureService,
        prewarmer: ScaffoldPrewarmer
    ) -> @Sendable () -> Void {
        {
            prewarmer.noteCompletionActivity()
            Task { await service.noteCompletionActivity() }
        }
    }

    private nonisolated static func screenMemoryEventHandler(
        for service: ScreenCaptureService
    ) -> @Sendable (ScreenMemoryInputEvent) -> Void {
        { event in
            Task {
                guard event.kind != .textFieldBlurred else {
                    await service.noteTextFieldBlurred(sessionIdentifier: event.sessionIdentifier)
                    return
                }
                let target = Self.currentTypingTarget(sessionIdentifier: event.sessionIdentifier)
                // Screen Memory reads only apps in the Writing scope. A field
                // outside it ends the capture session instead of starting one.
                guard Self.preferences().allows(appBundleIdentifier: target?.bundleIdentifier) else {
                    await service.noteTextFieldBlurred(sessionIdentifier: event.sessionIdentifier)
                    return
                }
                switch event.kind {
                case .textFieldFocused:
                    _ = await service.noteTextFieldFocused(
                        sessionIdentifier: event.sessionIdentifier,
                        target: target
                    )
                case .typingPaused:
                    _ = await service.noteTypingPaused(
                        sessionIdentifier: event.sessionIdentifier,
                        target: target
                    )
                case .textFieldBlurred:
                    break
                case .contentReset:
                    _ = await service.noteContentReset(
                        sessionIdentifier: event.sessionIdentifier,
                        target: target
                    )
                }
            }
        }
    }

    /// The same settings gate `screenCaptureService`'s own `enabled`
    /// closure uses — a request must never surface screen context capture
    /// itself would refuse to have started. When the toggle is off, or
    /// Screen Recording was never granted (so no snapshot exists),
    /// `freshScene` returns `nil` and the prompt falls back to plain
    /// autocomplete — degraded, not dead.
    private nonisolated static func sceneProvider(
        for service: ScreenCaptureService
    ) -> @Sendable (
        String?, String, String?, TypingTargetIdentity?
    ) async -> ScreenScene.Scene? {
        { appBundleIdentifier, fieldText, fieldSessionIdentifier, expectedTarget in
            guard settings().screenMemoryEnabled,
                  preferences().allows(appBundleIdentifier: appBundleIdentifier) else { return nil }
            return await service.freshScene(
                frontmostBundleID: appBundleIdentifier,
                fieldText: fieldText,
                fieldSessionIdentifier: fieldSessionIdentifier,
                expectedTarget: expectedTarget
            )
        }
    }

    private nonisolated static func suggestionTargetProvider(
        _ appBundleIdentifier: String?,
        _ fieldSessionIdentifier: String?
    ) -> TypingTargetIdentity? {
        guard let fieldSessionIdentifier,
              let target = currentTypingTarget(sessionIdentifier: fieldSessionIdentifier),
              appBundleIdentifier == nil || target.bundleIdentifier == appBundleIdentifier else {
            return nil
        }
        return target
    }

    // MARK: - Log text

    /// State names for the app log, never a path.
    private static func describe(_ state: ModelState) -> String {
        switch state {
        case .checking: "checking"
        case .missing: "missing"
        case .downloading: "downloading"
        case .verifying: "verifying"
        case .ready: "ready"
        case let .failed(failure): "failed (\(failure))"
        }
    }

    private static func describe(_ snapshot: LlamaRuntimeSnapshot) -> String {
        switch snapshot {
        case .starting: "starting"
        case .ready: "ready"
        case let .retrying(reason): "retrying (\(reason))"
        case let .failed(reason): "failed (\(reason))"
        }
    }
}

/// "Pause for 1 hour" pauses Save my writing as well as suggestions. Tilde's
/// pause stopped only the ghost, and its keyboard keeps sending typed text
/// while paused; here that text is acknowledged and never kept, so the
/// keyboard doesn't retry it.
struct WritingPausableIngest: PersonalHistoryIngesting {
    let base: any PersonalHistoryIngesting
    let isPaused: @Sendable () -> Bool

    func ingest(_ events: [PersonalHistoryEvent]) async -> Bool {
        guard !isPaused() else { return PersonalHistoryEvent.validBatch(events) }
        return await base.ingest(events)
    }
}

/// The model store the helper launches from. A model switch swaps it while
/// the one `LlamaServerProcessHost` stays, so the host's model provider
/// reads through here.
private final class WritingModelManagerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: ModelManager

    init(_ manager: ModelManager) {
        current = manager
    }

    var manager: ModelManager {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
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
