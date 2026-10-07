#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
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
    /// What the Writing tab tells the user, or `nil` while the keyboard
    /// isn't installed (before the first "Turn on writing").
    let setup: WritingKeyboardSetupState?
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
    private nonisolated static let automaticTerminationReason = "Transcripted Writing serves the keyboard"

    // MARK: - Read-only state for the Writing tab

    let physicalMemoryBytes: UInt64
    /// The model Writing runs: the saved choice, or Gemma when this Mac
    /// can't run the saved one.
    private(set) var selectedModel: TildeModelChoice
    /// The socket server is up and the runtime is live.
    private(set) var isRunning = false
    private(set) var keyboardInstallResult: GhostKeyboardInstallerHost.KeyboardInstallResult?
    /// What enabling the keyboard did on the last try, if it ran. On macOS
    /// 26 that's `.needsUserToAdd`: `TISEnableInputSource` returns `noErr`
    /// and the source stays off.
    private(set) var keyboardEnableResult: WritingKeyboardInputSource.EnableResult?
    /// Whether selecting the keyboard on the first setup worked, if it ran.
    private(set) var keyboardSelectSucceeded: Bool?

    /// Expensive: validates this app's and the keyboard's code signatures,
    /// and Text Input Sources wants the main thread. Call it when a screen
    /// needs it, not on a timer.
    ///
    /// `previous` is the state the tab showed last. When the keyboard has
    /// just become enabled (the user added it in Keyboard settings), this
    /// selects it once (`WritingKeyboardSetupState.shouldSelect`). It never
    /// enables the keyboard and never opens System Settings.
    func keyboardState(previous: WritingKeyboardSetupState? = nil) -> WritingKeyboardState {
        let installed = Self.keyboardIsInstalled
        let refresh = WritingKeyboardInputSource.refresh(
            using: inputSources,
            previous: previous,
            firstInstalledThisLoginSession: keyboardFirstInstalledThisLoginSession,
            selectedOnce: Self.appDefaults().bool(forKey: Self.keyboardFirstSetupKey)
        )
        if let selected = refresh.selectSucceeded {
            keyboardSelectSucceeded = selected && refresh.state == .selected
            log("WRITING | keyboard select after it was added: \(keyboardSelectSucceeded == true ? "selected" : "not selected")")
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

    private nonisolated static var keyboardIsInstalled: Bool {
        let installedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Input Methods", isDirectory: true)
            .appendingPathComponent(TildeProductProfile.current.inputMethodInstalledBundleName)
            .path
        return FileManager.default.fileExists(atPath: installedPath)
    }

    /// The app first copied the keyboard in during this login session, so
    /// Keyboard settings won't list it until the user logs out and back in.
    private var keyboardFirstInstalledThisLoginSession: Bool {
        WritingKeyboardFirstInstall.happenedThisLoginSession(
            currentSession: WritingLoginSession.currentIdentifier(),
            defaults: Self.appDefaults()
        )
    }

    // MARK: - Runtime

    struct Runtime {
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

    let modelRoot: URL
    /// `<capture-library>/writing`, for the day files and Delete all writing.
    let writingDirectory: @Sendable () -> URL
    private let keyboardInstaller = GhostKeyboardInstallerHost()
    private var inputSources: SystemWritingInputSources {
        SystemWritingInputSources(installer: keyboardInstaller)
    }
    var runtime: Runtime?
    /// Rebuilt on a model switch: its served configuration is per model.
    private var ghostBrainServerHost: GhostBrainServerHost?
    /// The model the runtime is built for. Differs from `selectedModel` only
    /// while a switch is between persisting and rebuilding.
    private var activeModel: TildeModelChoice?
    private(set) var log: (String) -> Void = { _ in }
    private var frontWindowObserver: WritingFrontWindowObserver?
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
        reapOrphanedHelperAtLaunch()
        applyRunState()
    }

    /// A helper orphaned by a crash would otherwise hold its port and memory
    /// until the next Autocomplete start. Reaps only this app's own helper
    /// binary, and only once it's re-parented to launchd; the probes shell
    /// out, so it runs off the main thread.
    private func reapOrphanedHelperAtLaunch() {
        guard WritingActivation.reapsOrphanedHelperAtLaunch(setupCompleted: setupCompleted) else { return }
        let port = TildeProductProfile.current.llamaServerPort
        Task.detached(priority: .utility) {
            LlamaServerProcessHost.reapOrphanedHelper(port: port)
        }
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
        let personalHistoryController = PersonalHistoryController(
            store: EncryptedPersonalHistoryStore(),
            settings: settings,
            diagnostics: .shared
        )
        let runtime = Runtime(
            models: models,
            llamaServerHost: llamaServerHost,
            scaffoldPrewarmer: ScaffoldPrewarmer(
                baseURL: llamaServerHost.baseURL,
                accessKey: llamaServerHost.accessKey,
                enabled: false,
                allowsApp: { bundleIdentifier in
                    Self.settings().pausedUntil == nil && Self.settings().suggestionsEnabled
                        && Self.preferences().allows(appBundleIdentifier: bundleIdentifier)
                }
            ),
            personalHistoryController: personalHistoryController,
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
            // Personal History takes only entries Save my writing cleared of
            // secrets, so it's reached through the day files, not the socket.
            dayFiles: WritingDayFileWriter(
                directory: writingDirectory,
                preferences: { Self.preferences() },
                personalHistory: personalHistoryController,
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

        let prewarmer = runtime.scaffoldPrewarmer
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
        applyFrontWindowWatch()
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
        frontWindowObserver?.stop()
        frontWindowObserver = nil
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
        applyFrontWindowWatch()
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
    private func installKeyboardRecordingFirstInstall() -> Bool {
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
    private func enableAndSelectKeyboard() -> Bool {
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
        // Runs on every exit, so the off branch tears the watchers down and
        // a Screen Memory change alone still starts or stops the poll.
        defer { applyFrontWindowWatch() }
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

    /// Delete model, Autocomplete already saved off: ends model work and
    /// waits for the helper to exit. `applyRunState()` settles the rest.
    func stopModelWork() async {
        let previous = modelTask
        modelTask?.cancel()
        modelTask = nil
        modelTaskID = nil
        wakeTask?.cancel()
        wakeTask = nil
        autocompleteRuntimeActive = false
        runtime?.models.manager.cancel()
        await previous?.value
        await stopHelper()
    }

    fileprivate func startHelper() {
        guard isRunning, autocompleteRuntimeActive else { return }
        runtime?.llamaServerHost.start()
    }

    // MARK: - Keyboard

    /// Install or update, register, and until the keyboard was selected
    /// once, try the enable and select. Every result lands in the state
    /// above and the app log. Never opens System Settings: the Writing tab
    /// shows the guidance and its button does that.
    private func installKeyboard() {
        guard installKeyboardRecordingFirstInstall(),
              !Self.appDefaults().bool(forKey: Self.keyboardFirstSetupKey) else { return }
        enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: true)
    }

    private func enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: Bool) {
        let selected = enableAndSelectKeyboard()
        // Text Input Sources can take a moment to list a just-registered or
        // just-enabled source. One retry; after that, the next start.
        if !selected, retryAfterDelay {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.isRunning else { return }
                self.enableAndSelectKeyboardOnFirstSetup(retryAfterDelay: false)
            }
        }
    }

    // MARK: - Screen Memory observation

    func applyFrontWindowWatch() {
        guard isRunning, let runtime else { return }
        if frontWindowObserver == nil {
            frontWindowObserver = WritingFrontWindowObserver(
                prewarmer: runtime.scaffoldPrewarmer,
                screenCaptureService: runtime.screenCaptureService
            )
        }
        frontWindowObserver?.update(autocompleteActive: autocompleteRuntimeActive)
    }

    nonisolated static func currentTypingTarget(
        sessionIdentifier: String
    ) -> TypingTargetIdentity? {
        WritingFrontWindowPoller.readFrontWindowIdentity().map {
            typingTarget(from: $0, sessionIdentifier: sessionIdentifier)
        }
    }

    nonisolated static func typingTarget(
        from identity: WritingFrontWindowIdentity,
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
