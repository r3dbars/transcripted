#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import Carbon
import Combine
import Foundation

/// The Writing tab's state and actions: which screen shows (intro, setup,
/// everyday), the setup draft, and a read of `WritingController` refreshed
/// while the tab is on screen. Replaces Tilde's `TildeSettingsViewModel` and
/// `YourTildeViewModel`. Every runtime change goes through the controller;
/// this only reads and asks.
///
/// One model per controller (`shared(for:)`), so a setup in progress
/// survives switching tabs.
@MainActor
final class WritingSettingsModel: ObservableObject {
    typealias Presentation = WritingSetupPresentation

    enum Screen: Equatable {
        /// Intro page 1 or 2.
        case intro(page: Int)
        /// Setup step 1, 2 or 3.
        case setup(step: Int)
        case everyday
    }

    private static var models: [ObjectIdentifier: WritingSettingsModel] = [:]

    static func shared(for controller: WritingController) -> WritingSettingsModel {
        let key = ObjectIdentifier(controller)
        if let model = models[key] { return model }
        let model = WritingSettingsModel(controller: controller)
        models[key] = model
        return model
    }

    static let pauseInterval: TimeInterval = 60 * 60
    private static let liveRefreshInterval: TimeInterval = 1
    private static let statsRefreshInterval: TimeInterval = 5

    let controller: WritingController
    /// A meeting records, a dictation records, or meeting audio is still
    /// being transcribed. Set by the page from the settings shell.
    var isCaptureBusy: () -> Bool = { false }
    /// The Settings window, reported by the page. It stays alive when
    /// closed, so the refresh timers idle unless it's showing, and stop
    /// altogether while it's closed or covered (see `observeHostWindow`).
    weak var hostWindow: NSWindow? {
        didSet {
            guard hostWindow !== oldValue, isPageMounted else { return }
            observeHostWindow()
        }
    }

    private var isOnScreen: Bool {
        hostWindow?.writingIsShowingContent ?? true
    }

    @Published var screen: Screen
    @Published var draft = Presentation.Draft()
    @Published private(set) var isEditingSetup = false
    @Published var showsAllApps = false

    @Published private(set) var saveMyWriting = false
    @Published private(set) var autocomplete = true
    @Published private(set) var personalizedSuggestions = false
    @Published private(set) var scope: Presentation.ScopeMode = .all
    @Published private(set) var pickedCount = 0
    @Published private(set) var selectedModel: TildeModelChoice
    @Published private(set) var modelStatus: Presentation.ModelStatus = .waiting
    /// The Transcripted keyboard is the selected input source. `nil` until
    /// first read.
    @Published private(set) var keyboardOn: Bool?
    /// Where the keyboard stands, for the guidance in step 3 and the
    /// everyday view. `nil` until first read, and while the keyboard isn't
    /// installed yet.
    @Published private(set) var keyboardSetup: WritingKeyboardSetupState?
    @Published private(set) var screenRecordingGranted = false
    @Published private(set) var screenRecordingRequested = false
    @Published private(set) var captureBusy = false
    @Published private(set) var pausedUntil: Date?
    /// Save my writing couldn't write its day file (for example a NAS
    /// library that refuses owner-only permissions). Cleared by the next
    /// successful write.
    @Published private(set) var saveProblem = false
    @Published private(set) var today = WritingDayFileReader.Day.empty
    @Published private(set) var ledger = OutcomeLedgerSummary.empty
    /// What `ledger` was computed from, so an unchanged ledger costs a
    /// `fstat` instead of a full re-read. Set together with `ledger`.
    private var ledgerStamp: OutcomeLedgerReader.Stamp?
    @Published private(set) var keyboardAcceptedToday = 0
    @Published private(set) var storage: WritingStorageUsage?
    @Published private(set) var installedApps: [Presentation.AppChoice] = []
    @Published private(set) var isDeleting = false
    @Published private(set) var deleteFailed = false
    /// Delete model left files behind.
    @Published private(set) var deleteModelFailed = false
    /// The delete in flight is Delete model, for the spinner's place.
    @Published private(set) var isDeletingModel = false

    private let timers = WritingRefreshTimers(
        liveInterval: WritingSettingsModel.liveRefreshInterval,
        statsInterval: WritingSettingsModel.statsRefreshInterval
    )
    private var isPageMounted = false
    private var observers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var todayLoadGeneration: UInt64 = 0
    private var todayRefresh = CoalescedRefreshState(isEnabled: false)
    private var statsLoadGeneration: UInt64 = 0
    private var hasLoadedInstalledApps = false

    init(controller: WritingController) {
        self.controller = controller
        selectedModel = controller.selectedModel
        screen = controller.setupCompleted ? .everyday : .intro(page: 1)
        refreshLive()
    }

    var isQwenEligible: Bool { controller.isQwenEligible }

    /// Today's `Writing_<date>.md`, whether or not it exists yet.
    var todayFileURL: URL {
        WritingDayFileWriter.defaultDirectory()
            .appendingPathComponent(WritingDayFileReader.fileName(for: Date()))
    }

    // MARK: - Page lifecycle

    func pageAppeared() {
        if !controller.setupCompleted, screen == .everyday {
            screen = .intro(page: 1)
        }
        isPageMounted = true
        todayRefresh.isEnabled = isOnScreen
        refreshLive()
        refreshKeyboard()
        reloadToday()
        refreshStats()
        refreshStorage()
        startObserving()
        observeHostWindow()
        if isOnScreen { armTimers() }
    }

    func pageDisappeared() {
        isPageMounted = false
        todayRefresh.isEnabled = false
        timers.suspend()
        for observer in observers + windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        windowObservers.removeAll()
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
    }

    /// Stops the 1 s and 5 s refreshes while the page stays mounted, for a
    /// window that closed or is fully covered. Observers stay.
    func suspendTimers() {
        todayRefresh.isEnabled = false
        timers.suspend()
    }

    /// Restarts the refreshes after `suspendTimers`, once: a no-op while the
    /// page isn't mounted or the timers already run. Reads the live state
    /// right away so the first frame isn't a second stale.
    func resumeTimers() {
        guard isPageMounted, isOnScreen, armTimers() else { return }
        todayRefresh.isEnabled = true
        reloadToday()
        refreshLive()
        refreshStats()
    }

    @discardableResult
    private func armTimers() -> Bool {
        timers.resume(
            live: { [weak self] in
                guard let self, self.isOnScreen else { return }
                self.refreshLive()
            },
            stats: { [weak self] in
                guard let self, self.isOnScreen else { return }
                self.refreshStats()
            }
        )
    }

    /// Closing the Settings window doesn't fire `onDisappear`, so the page
    /// follows its window: closed or covered suspends the timers, shown or
    /// made key again resumes them.
    private func observeHostWindow() {
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        windowObservers.removeAll()
        guard let window = hostWindow else { return }
        let center = NotificationCenter.default
        windowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.suspendTimers() }
        })
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification] {
            windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.isOnScreen {
                        self.resumeTimers()
                    } else {
                        self.suspendTimers()
                    }
                }
            })
        }
    }

    private func startObserving() {
        guard observers.isEmpty, distributedObservers.isEmpty else { return }

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .writingDayFileDidSave, object: nil, queue: .main) { [weak self] note in
            let savedURL = note.object as? URL
            Task { @MainActor in
                guard let self,
                      WritingDayRefreshPolicy.shouldReload(savedURL: savedURL, todayURL: self.todayFileURL) else { return }
                self.todayRefresh.isEnabled = self.isPageMounted && self.isOnScreen
                self.reloadToday()
            }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Only while the page is showing: refreshKeyboard validates code
                // signatures on the main thread, and the Settings window can
                // close without onDisappear.
                guard let self, self.isOnScreen else { return }
                self.refreshKeyboard()
                self.refreshLive()
            }
        })
        // Input Sources changes from the menu bar or System Settings: the
        // user added the keyboard, or picked it. Only while the page is
        // showing, like activation above.
        let inputSourceNotifications: [CFString?] = [
            kTISNotifySelectedKeyboardInputSourceChanged,
            kTISNotifyEnabledKeyboardInputSourcesChanged,
        ]
        for case let name? in inputSourceNotifications {
            distributedObservers.append(DistributedNotificationCenter.default().addObserver(
                forName: Notification.Name(name as String),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.isOnScreen else { return }
                    self.refreshKeyboard()
                }
            })
        }
    }

    // MARK: - Reading state

    /// Cheap reads, once a second while the tab shows.
    func refreshLive() {
        update(\.saveMyWriting, controller.saveMyWritingEnabled)
        update(\.autocomplete, controller.autocompleteEnabled)
        update(\.personalizedSuggestions, controller.personalizedSuggestionsEnabled)
        let appScope = controller.appScope
        update(\.scope, appScope.mode == .all ? .all : .picked)
        update(\.pickedCount, appScope.bundleIdentifiers.count)
        update(\.selectedModel, controller.selectedModel)
        update(\.modelStatus, Self.modelStatus(
            isRunning: controller.isRunning,
            model: controller.modelState,
            helper: controller.runtimeState
        ))
        update(\.screenRecordingGranted, controller.screenRecordingGranted)
        update(\.screenRecordingRequested, controller.screenRecordingRequested)
        update(\.pausedUntil, controller.pausedUntil)
        update(\.saveProblem, controller.saveMyWritingProblem != nil)
        update(\.captureBusy, isCaptureBusy())
    }

    /// Validates code signatures and asks Text Input Sources, so it runs on
    /// appear, on app activation, on Input Sources changes and after actions,
    /// never on the timer. When the keyboard has just been added in Keyboard
    /// settings, the controller selects it once here. Never opens System
    /// Settings.
    func refreshKeyboard() {
        let state = controller.keyboardState(previous: keyboardSetup)
        update(\.keyboardSetup, state.setup)
        update(\.keyboardOn, state.selected)
    }

    func refreshStats() {
        statsLoadGeneration &+= 1
        let generation = statsLoadGeneration
        let url = TildeLocalOutcomeStores.eventURL()
        let previous = ledgerStamp.map { (stamp: $0, summary: ledger) }
        Task { [weak self] in
            let (summary, stamp) = await OutcomeLedgerReader.summary(url: url, reusing: previous)
            guard let self, generation == self.statsLoadGeneration else { return }
            self.ledgerStamp = stamp
            self.update(\.ledger, summary)
            self.update(\.keyboardAcceptedToday, TildeStats.todaySuggestionsAccepted())
        }
    }

    func reloadToday() {
        guard todayRefresh.request() else { return }
        startTodayLoad()
    }

    private func startTodayLoad() {
        todayLoadGeneration &+= 1
        let generation = todayLoadGeneration
        let directory = WritingDayFileWriter.defaultDirectory
        Task { [weak self] in
            let day = await Task.detached(priority: .userInitiated) {
                WritingDayFileReader.read(
                    url: directory().appendingPathComponent(WritingDayFileReader.fileName(for: Date()))
                )
            }.value
            guard let self else { return }
            if generation == self.todayLoadGeneration, self.todayRefresh.isEnabled {
                self.update(\.today, day)
            }
            if self.todayRefresh.finished() { self.startTodayLoad() }
        }
    }

    func refreshStorage() {
        Task { [weak self] in
            guard let self else { return }
            let usage = await self.controller.storageUsage()
            self.update(\.storage, usage)
        }
    }

    private func loadInstalledAppsIfNeeded() {
        guard !hasLoadedInstalledApps else { return }
        hasLoadedInstalledApps = true
        let excluded = WritingController.settings().personalHistoryExcludedApps
        let own = Bundle.main.bundleIdentifier
        Task { [weak self] in
            let apps = await Task.detached(priority: .userInitiated) {
                Self.scanInstalledApps(excludedApps: excluded, ownBundleIdentifier: own)
            }.value
            self?.installedApps = apps
        }
    }

    /// Installed apps plus any picked app that wasn't found, preferred apps
    /// first.
    var appChoices: [Presentation.AppChoice] {
        let found = Set(installedApps.map(\.bundleIdentifier))
        let missing = draft.pickedBundleIdentifiers
            .filter { !found.contains($0) }
            .map { Presentation.AppChoice(bundleIdentifier: $0, name: $0) }
        return Presentation.orderedApps(installedApps + missing)
    }

    // MARK: - Intro and setup

    func showIntroPage(_ page: Int) {
        screen = .intro(page: min(max(1, page), Presentation.introPageCount))
    }

    /// "Set up writing": a fresh draft with both features on and all apps.
    /// "Not now" on the intro: Writing stays off and the sidebar's "New"
    /// badge goes away (plan: it stays until setup finishes or the intro is
    /// dismissed).
    func dismissNewBadge() {
        UserDefaults.standard.set(true, forKey: WritingSidebarNewBadge.dismissedDefaultsKey)
    }

    func beginSetup() {
        isEditingSetup = false
        draft = Presentation.Draft(model: controller.selectedModel)
        screen = .setup(step: 1)
    }

    /// "Edit setup": the steps again, starting from what's saved now.
    func editSetup() {
        isEditingSetup = true
        let appScope = controller.appScope
        draft = Presentation.Draft(
            saveMyWriting: controller.saveMyWritingEnabled,
            autocomplete: controller.autocompleteEnabled,
            scope: appScope.mode == .all ? .all : .picked,
            pickedBundleIdentifiers: Set(appScope.bundleIdentifiers),
            model: controller.selectedModel
        )
        screen = .setup(step: 1)
    }

    func cancelSetup() {
        isEditingSetup = false
        screen = controller.setupCompleted ? .everyday : .intro(page: 1)
    }

    func showStep(_ step: Int) {
        let clamped = min(max(1, step), Presentation.setupStepCount)
        if clamped == 2 { loadInstalledAppsIfNeeded() }
        if clamped == 3 {
            refreshLive()
            refreshKeyboard()
        }
        screen = .setup(step: clamped)
    }

    func toggleApp(_ bundleIdentifier: String) {
        if draft.pickedBundleIdentifiers.contains(bundleIdentifier) {
            draft.pickedBundleIdentifiers.remove(bundleIdentifier)
        } else {
            draft.pickedBundleIdentifiers.insert(bundleIdentifier)
        }
    }

    /// "Turn on writing", in the approved order: save the choices, install
    /// the keyboard and select it if it's on, start Writing (which starts the
    /// model download in the background), and ask for Screen Recording last.
    /// The Screen Recording ask waits while anything records: macOS may ask
    /// Transcripted to quit and reopen after the grant.
    ///
    /// It never waits on the keyboard. macOS 26 won't let an app turn a
    /// keyboard on, so until the user adds it the keyboard row shows as
    /// pending with the steps (`WritingKeyboardSetupState`), and nothing
    /// opens System Settings unasked.
    func turnOnWriting() {
        // A model prepared now would land in the folder Delete model is
        // emptying, and Autocomplete would read on with no model.
        guard !isDeleting else { return }
        let choices = draft
        guard choices.canContinueStep1, choices.canContinueStep2 else { return }

        controller.setAppScope(
            choices.scope == .all ? .all : .picked(choices.pickedBundleIdentifiers)
        )
        if choices.autocomplete {
            controller.selectModel(choices.model)
        }
        // Save my writing rotates its consent on every change, so only a
        // real change goes through.
        if choices.saveMyWriting != controller.saveMyWritingEnabled {
            controller.setSaveMyWriting(choices.saveMyWriting)
        }
        controller.setAutocomplete(choices.autocomplete)
        let isFirstSetup = !controller.setupCompleted
        WritingSetupState.markCompleted(defaults: WritingController.appDefaults())

        let keyboardSelected = controller.turnOnKeyboard(openSettingsOnFailure: false)
        controller.applyRunState()
        if Presentation.asksForScreenRecordingAfterSetup(
            autocomplete: choices.autocomplete,
            granted: controller.screenRecordingGranted,
            captureBusy: isCaptureBusy()
        ) {
            controller.requestScreenRecording()
        }

        // First setup only; Edit setup saves without re-counting the funnel.
        if isFirstSetup {
            WritingAnalytics.trackSetupCompleted(WritingAnalytics.Setup(
                saveEnabled: choices.saveMyWriting,
                autocompleteEnabled: choices.autocomplete,
                appScope: choices.scope == .all ? .all : .picked,
                model: controller.selectedModel
            ))
        }
        UserDefaults.standard.set(true, forKey: WritingSidebarNewBadge.dismissedDefaultsKey)

        isEditingSetup = false
        screen = .everyday
        if !keyboardSelected {
            // Text Input Sources can take a moment to list a just-registered
            // keyboard. One retry; after that the guidance stays up.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.controller.turnOnKeyboard(openSettingsOnFailure: false)
                self.refreshKeyboard()
            }
        }
        refreshLive()
        refreshKeyboard()
        reloadToday()
        refreshStats()
        refreshStorage()
    }

    // MARK: - Everyday actions

    func setSaveMyWriting(_ enabled: Bool) {
        guard enabled != controller.saveMyWritingEnabled else { return }
        controller.setSaveMyWriting(enabled)
        controller.applyRunState()
        refreshLive()
    }

    func setAutocomplete(_ enabled: Bool) {
        // Turning it on mid-delete would start a download into the folder
        // Delete model is emptying.
        guard !isDeleting else { return }
        controller.setAutocomplete(enabled)
        controller.applyRunState()
        refreshLive()
    }

    func setPersonalizedSuggestions(_ enabled: Bool) {
        controller.setPersonalizedSuggestions(enabled)
        refreshLive()
    }

    func selectModel(_ choice: TildeModelChoice) {
        guard !isDeleting else { return }
        controller.selectModel(choice)
        refreshLive()
        refreshStorage()
    }

    func pauseForAnHour() {
        controller.pause(for: Self.pauseInterval)
        refreshLive()
    }

    func resume() {
        controller.resume()
        refreshLive()
    }

    /// "Open Keyboard Settings": tries the install, enable and select once
    /// more, then opens Keyboard settings if the keyboard still isn't the
    /// input source. The only path that opens System Settings for it.
    func openKeyboardSettings() {
        controller.turnOnKeyboard(openSettingsOnFailure: true)
        refreshKeyboard()
    }

    /// Never while anything records (see `turnOnWriting`). After the one
    /// system prompt, System Settings is the only way to grant it.
    func allowScreenRecording() {
        switch Presentation.screenRecordingAsk(
            captureBusy: isCaptureBusy(),
            alreadyRequested: controller.screenRecordingRequested
        ) {
        case .waitForCapture:
            update(\.captureBusy, true)
            return
        case .openSettings:
            controller.openScreenRecordingSettings()
        case .request:
            controller.requestScreenRecording()
        }
        refreshLive()
    }

    func deleteAllWriting() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteFailed = false
        Task { [weak self] in
            guard let self else { return }
            let deleted = await self.controller.deleteAllWriting()
            // Delete all turns Save my writing off; with Autocomplete off
            // too, Writing stops.
            self.controller.applyRunState()
            self.isDeleting = false
            self.deleteFailed = !deleted
            self.refreshLive()
            self.reloadToday()
            self.refreshStats()
            self.refreshStorage()
        }
    }

    /// Delete model. Shares `isDeleting` with Delete all writing so only
    /// one delete runs at a time.
    func deleteModel() {
        guard !isDeleting else { return }
        isDeleting = true
        isDeletingModel = true
        deleteModelFailed = false
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.controller.deleteDownloadedModels()
            // Autocomplete is off now; with Save my writing off too, Writing
            // stops.
            self.controller.applyRunState()
            self.isDeleting = false
            self.isDeletingModel = false
            if case .incomplete = outcome { self.deleteModelFailed = true }
            self.refreshLive()
            self.refreshStorage()
        }
    }

    // MARK: - Helpers

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<WritingSettingsModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    static func modelStatus(
        isRunning: Bool,
        model: ModelState?,
        helper: LlamaRuntimeSnapshot?
    ) -> Presentation.ModelStatus {
        guard isRunning, let model else { return .waiting }
        switch model {
        case .checking:
            return .checking
        case .missing:
            return .notDownloaded
        case let .downloading(receivedBytes, totalBytes):
            let fraction = totalBytes > 0
                ? min(1, max(0, Double(receivedBytes) / Double(totalBytes)))
                : nil
            return .downloading(fraction: fraction)
        case .verifying:
            return .verifying
        case let .failed(failure):
            switch failure {
            case .offline: return .failed(.offline)
            case .insufficientDiskSpace: return .failed(.diskSpace)
            case .serverRejectedRequest: return .failed(.rejected)
            case .checksumMismatch, .invalidModel: return .failed(.verification)
            case .installationFailed: return .failed(.install)
            }
        case .ready:
            switch helper {
            case .ready?: return .ready
            case .retrying?: return .restarting
            case .failed?: return .stopped
            case .starting?, nil: return .starting
            }
        }
    }

    /// Top-level apps in the usual Applications folders, without password
    /// managers, the user's excluded apps, or Transcripted itself. Reads
    /// each bundle's identifier and display name only.
    nonisolated static func scanInstalledApps(
        excludedApps: Set<String>,
        ownBundleIdentifier: String?
    ) -> [Presentation.AppChoice] {
        let fileManager = FileManager.default
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        var apps: [Presentation.AppChoice] = []
        for root in roots {
            guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(name)
                guard let identifier = Bundle(path: path)?.bundleIdentifier,
                      identifier != ownBundleIdentifier,
                      PersonalHistoryEvent.validBundleIdentifier(identifier),
                      !DefaultExcludedApps.isExcluded(identifier, configuredExcludedApps: excludedApps)
                else { continue }
                var displayName = fileManager.displayName(atPath: path)
                if displayName.hasSuffix(".app") { displayName = String(displayName.dropLast(4)) }
                apps.append(Presentation.AppChoice(bundleIdentifier: identifier, name: displayName))
            }
        }
        return Presentation.orderedApps(apps)
    }
}
