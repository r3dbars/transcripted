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
    /// closed, so the refresh timers idle unless it's showing.
    weak var hostWindow: NSWindow?

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
    @Published private(set) var keyboardAcceptedToday = 0
    @Published private(set) var storage: WritingStorageUsage?
    @Published private(set) var installedApps: [Presentation.AppChoice] = []
    @Published private(set) var isDeleting = false
    @Published private(set) var deleteFailed = false

    private var liveTimer: Timer?
    private var statsTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var todayLoadGeneration: UInt64 = 0
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
        refreshLive()
        refreshKeyboard()
        reloadToday()
        refreshStats()
        refreshStorage()
        startObserving()
    }

    func pageDisappeared() {
        liveTimer?.invalidate()
        liveTimer = nil
        statsTimer?.invalidate()
        statsTimer = nil
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
    }

    private func startObserving() {
        guard liveTimer == nil else { return }
        let live = Timer(timeInterval: Self.liveRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOnScreen else { return }
                self.refreshLive()
            }
        }
        let stats = Timer(timeInterval: Self.statsRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isOnScreen else { return }
                self.refreshStats()
            }
        }
        RunLoop.main.add(live, forMode: .common)
        RunLoop.main.add(stats, forMode: .common)
        liveTimer = live
        statsTimer = stats

        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .writingDayFileDidSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadToday() }
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
        // Input Sources changes from the menu bar or System Settings.
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
                Task { @MainActor in self?.refreshKeyboard() }
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
    /// never on the timer.
    func refreshKeyboard() {
        update(\.keyboardOn, controller.keyboardState().selected)
    }

    func refreshStats() {
        statsLoadGeneration &+= 1
        let generation = statsLoadGeneration
        let url = TildeLocalOutcomeStores.eventURL()
        Task { [weak self] in
            let summary = await OutcomeLedgerReader.summary(url: url)
            guard let self, generation == self.statsLoadGeneration else { return }
            self.update(\.ledger, summary)
            self.update(\.keyboardAcceptedToday, TildeStats.todaySuggestionsAccepted())
        }
    }

    func reloadToday() {
        todayLoadGeneration &+= 1
        let generation = todayLoadGeneration
        let directory = WritingDayFileWriter.defaultDirectory
        Task { [weak self] in
            let day = await Task.detached(priority: .userInitiated) {
                WritingDayFileReader.read(
                    url: directory().appendingPathComponent(WritingDayFileReader.fileName(for: Date()))
                )
            }.value
            guard let self, generation == self.todayLoadGeneration else { return }
            self.update(\.today, day)
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
        if clamped == 3 { refreshLive() }
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
    /// and select the keyboard, start Writing (which starts the model
    /// download in the background), and ask for Screen Recording last. The
    /// Screen Recording ask waits while anything records: macOS may ask
    /// Transcripted to quit and reopen after the grant.
    func turnOnWriting() {
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
        if choices.autocomplete, !controller.screenRecordingGranted, !isCaptureBusy() {
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
            // keyboard. One retry, then Keyboard settings.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.controller.turnOnKeyboard()
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
        controller.setAutocomplete(enabled)
        controller.applyRunState()
        refreshLive()
    }

    func setPersonalizedSuggestions(_ enabled: Bool) {
        controller.setPersonalizedSuggestions(enabled)
        refreshLive()
    }

    func selectModel(_ choice: TildeModelChoice) {
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

    func turnOnKeyboard() {
        controller.turnOnKeyboard()
        refreshKeyboard()
    }

    /// Never while anything records (see `turnOnWriting`). After the one
    /// system prompt, System Settings is the only way to grant it.
    func allowScreenRecording() {
        guard !isCaptureBusy() else {
            update(\.captureBusy, true)
            return
        }
        if controller.screenRecordingRequested {
            controller.openScreenRecordingSettings()
        } else {
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
