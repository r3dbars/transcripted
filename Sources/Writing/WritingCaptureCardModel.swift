#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import AppKit
import Carbon
import Combine
import Foundation

/// View model for the opt-in "Capture my writing" card on the Agent page.
/// Lives in `WritingBridge` so `UISettings` never names `WritingCore` types
/// directly.
@MainActor
final class WritingCaptureCardModel: ObservableObject {
    enum ScopeMode: String, CaseIterable, Equatable, Sendable {
        case all
        case picked
    }

    enum KeyboardStatus: Equatable, Sendable {
        case checking
        case ready
        case enabledNotSelected
        case needsUserToAdd
        case needsRelogin
    }

    struct AppChoice: Equatable, Identifiable, Sendable {
        let bundleIdentifier: String
        let name: String
        var id: String { bundleIdentifier }
    }

    private static var models: [ObjectIdentifier: WritingCaptureCardModel] = [:]

    static func shared(for controller: WritingController) -> WritingCaptureCardModel {
        let key = ObjectIdentifier(controller)
        if let existing = models[key] { return existing }
        let model = WritingCaptureCardModel(controller: controller)
        models[key] = model
        return model
    }

    let controller: WritingController

    @Published private(set) var isEnabled = false
    @Published private(set) var scopeMode: ScopeMode = .all
    @Published private(set) var pickedBundleIdentifiers: Set<String> = []
    @Published private(set) var keyboardStatus: KeyboardStatus = .checking
    @Published private(set) var saveProblem = false
    @Published private(set) var savedBytes: Int64 = 0
    @Published private(set) var installedApps: [AppChoice] = []
    @Published private(set) var isDeleting = false
    @Published private(set) var deleteFailed = false

    private var keyboardSetup: WritingKeyboardSetupState?
    private let keyboardRefresh = WritingKeyboardRefreshCoordinator<WritingKeyboardState>()
    private var isMounted = false
    private var hasLoadedInstalledApps = false
    private var observers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []

    init(controller: WritingController) {
        self.controller = controller
        refreshState()
    }

    var savedSummary: String {
        WritingStorageUsage(savedWritingBytes: savedBytes).summary
    }

    var writingFolderURL: URL {
        controller.writingDirectory()
    }

    var appChoices: [AppChoice] {
        let found = Set(installedApps.map(\.bundleIdentifier))
        let missing = pickedBundleIdentifiers
            .filter { !found.contains($0) }
            .map { AppChoice(bundleIdentifier: $0, name: $0) }
        return (installedApps + missing).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Lifecycle

    func appear() {
        isMounted = true
        refreshState()
        refreshKeyboard()
        refreshStorage()
        if scopeMode == .picked { loadInstalledAppsIfNeeded() }
        startObserving()
    }

    func disappear() {
        isMounted = false
        keyboardRefresh.setEnabled(false)
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
        observers.removeAll()
        for observer in distributedObservers {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
        distributedObservers.removeAll()
    }

    // MARK: - Actions

    func setEnabled(_ enabled: Bool) {
        guard !isDeleting, enabled != isEnabled else { return }
        controller.setSaveMyWriting(enabled)
        refreshState()
        if enabled {
            let controller = self.controller
            WritingKeyboardActivationFlow.start(
                admission: { controller.keyboardActionAdmission },
                attempt: { await controller.turnOnKeyboard(openSettingsOnFailure: false) },
                refresh: { [weak self] in self?.refreshKeyboard() },
                retryWait: { try await Task.sleep(for: .seconds(1)) }
            )
        } else {
            refreshKeyboard()
        }
        refreshStorage()
    }

    func setScopeMode(_ mode: ScopeMode) {
        guard mode != scopeMode else { return }
        if mode == .picked {
            loadInstalledAppsIfNeeded()
            controller.setAppScope(.picked(pickedBundleIdentifiers))
        } else {
            controller.setAppScope(.all)
        }
        refreshState()
    }

    func togglePickedApp(_ bundleIdentifier: String) {
        var next = pickedBundleIdentifiers
        if next.contains(bundleIdentifier) {
            next.remove(bundleIdentifier)
        } else {
            next.insert(bundleIdentifier)
        }
        pickedBundleIdentifiers = next
        controller.setAppScope(.picked(next))
        refreshState()
    }

    func openKeyboardSettings() {
        let controller = self.controller
        WritingKeyboardActivationFlow.start(
            admission: { controller.keyboardActionAdmission },
            attempt: { await controller.turnOnKeyboard(openSettingsOnFailure: true) },
            refresh: { [weak self] in self?.refreshKeyboard() }
        )
    }

    func deleteAllSavedWriting() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteFailed = false
        Task { [weak self] in
            guard let self else { return }
            let deleted = await self.controller.deleteAllWriting()
            self.isDeleting = false
            self.deleteFailed = !deleted
            self.refreshState()
            self.refreshStorage()
        }
    }

    // MARK: - Refresh

    func refreshState() {
        let enabled = controller.saveMyWritingEnabled
        if isEnabled != enabled { isEnabled = enabled }
        let scope = controller.appScope
        let mode: ScopeMode = scope.mode == .all ? .all : .picked
        if scopeMode != mode { scopeMode = mode }
        let picked = Set(scope.bundleIdentifiers)
        if pickedBundleIdentifiers != picked { pickedBundleIdentifiers = picked }
        let problem = controller.saveMyWritingProblem != nil
        if saveProblem != problem { saveProblem = problem }
    }

    func refreshKeyboard() {
        keyboardRefresh.setEnabled(isMounted)
        keyboardRefresh.request(operation: { [weak self] current in
            guard let self else { return nil }
            return await self.controller.keyboardState(previous: self.keyboardSetup, isCurrent: { [weak self] in
                guard let self, self.isMounted else { return false }
                return current()
            })
        }, publish: { [weak self] state in
            guard let self, self.isMounted else { return }
            self.keyboardSetup = state.setup
            let next: KeyboardStatus
            switch state.setup {
            case .selected: next = .ready
            case .enabledNotSelected: next = .enabledNotSelected
            case .needsRelogin: next = .needsRelogin
            case .needsUserToAdd, nil: next = .needsUserToAdd
            }
            if self.keyboardStatus != next { self.keyboardStatus = next }
        })
    }

    func refreshStorage() {
        Task { [weak self] in
            guard let self else { return }
            let usage = await self.controller.storageUsage()
            if self.savedBytes != usage.savedWritingBytes {
                self.savedBytes = usage.savedWritingBytes
            }
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

    private func startObserving() {
        guard observers.isEmpty, distributedObservers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .writingDayFileDidSave, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refreshState()
                self?.refreshStorage()
            }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isMounted else { return }
                self.refreshState()
                self.refreshKeyboard()
                self.refreshStorage()
            }
        })
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
                    guard let self, self.isMounted else { return }
                    self.refreshKeyboard()
                }
            })
        }
    }

    nonisolated private static func scanInstalledApps(
        excludedApps: Set<String>,
        ownBundleIdentifier: String?
    ) -> [AppChoice] {
        let fileManager = FileManager.default
        let roots = [
            "/Applications",
            "/Applications/Utilities",
            "/System/Applications",
            "/System/Applications/Utilities",
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path,
        ]
        var seen: Set<String> = []
        var apps: [AppChoice] = []
        for root in roots {
            guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { continue }
            for name in names where name.hasSuffix(".app") {
                let path = (root as NSString).appendingPathComponent(name)
                guard let identifier = Bundle(path: path)?.bundleIdentifier,
                      identifier != ownBundleIdentifier,
                      PersonalHistoryEvent.validBundleIdentifier(identifier),
                      !DefaultExcludedApps.isExcluded(identifier, configuredExcludedApps: excludedApps),
                      seen.insert(identifier).inserted
                else { continue }
                var displayName = fileManager.displayName(atPath: path)
                if displayName.hasSuffix(".app") { displayName = String(displayName.dropLast(4)) }
                apps.append(AppChoice(bundleIdentifier: identifier, name: displayName))
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
