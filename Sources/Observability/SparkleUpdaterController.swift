import Combine
import Foundation
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    struct AutomaticUpdateSettings: Equatable {
        var automaticChecksEnabled: Bool
        var automaticDownloadsAllowed: Bool
        var automaticDownloadsEnabled: Bool
    }

    struct UpdateStatus: Equatable {
        enum State: Equatable {
            case unknown
            case readyToCheck
            case checking
            case noUpdateAvailable
            case updateAvailable(version: String)
            case downloading(version: String)
            case readyToInstall(version: String)
        }

        var state: State
        var canCheckForUpdates: Bool

        var availableUpdateVersion: String? {
            switch state {
            case .updateAvailable(let version), .downloading(let version), .readyToInstall(let version):
                return version
            case .unknown, .readyToCheck, .checking, .noUpdateAvailable:
                return nil
            }
        }

        var readyToInstallVersion: String? {
            guard case .readyToInstall(let version) = state else { return nil }
            return version
        }

        var canRunUserUpdateAction: Bool {
            switch state {
            case .checking, .downloading:
                return false
            case .readyToInstall:
                return true
            case .unknown, .readyToCheck, .noUpdateAvailable, .updateAvailable:
                return canCheckForUpdates
            }
        }
    }

    @Published private(set) var updateStatus = UpdateStatus(
        state: .unknown,
        canCheckForUpdates: false
    )
    @Published private(set) var automaticUpdateSettings = AutomaticUpdateSettings(
        automaticChecksEnabled: false,
        automaticDownloadsAllowed: false,
        automaticDownloadsEnabled: false
    )

    private lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private var canCheckObservation: NSKeyValueObservation?
    private var updaterSettingObservations: [NSKeyValueObservation] = []
    private var hasPerformedStartupCheck = false
    private var pendingImmediateInstallHandler: (() -> Void)?
    private var pendingImmediateInstallVersion: String?
    private var didTrackCurrentUpdateCycleFailure = false

    override init() {
        super.init()
        observeUpdaterReadiness()
        observeUpdaterSettings()
    }

    func performStartupUpdateCheckIfNeeded() {
        guard !hasPerformedStartupCheck else { return }
        hasPerformedStartupCheck = true

        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }

        if updaterController.updater.automaticallyChecksForUpdates {
            // Sparkle recommends forcing launch-time background checks, if
            // desired, immediately after the updater has started and only when
            // automatic checks are enabled.
            guard beginObservedUpdateCheckIfPossible(allowExistingSession: true) else { return }
            updaterController.updater.checkForUpdatesInBackground()
        } else {
            refreshUpdateStatus()
        }
    }

    func checkForUpdates() {
        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }

        guard beginObservedUpdateCheckIfPossible(allowExistingSession: true) else { return }
        updaterController.checkForUpdates(nil)
    }

    func refreshUpdateStatus() {
        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }

        guard beginObservedUpdateCheckIfPossible(allowExistingSession: false) else { return }
        updaterController.updater.checkForUpdateInformation()
    }

    func performUserUpdateAction(surface: String) {
        let state = updateStatus.state
        let version = updateStatus.availableUpdateVersion
        trackUpdateActionClicked(surface: surface, state: state, version: version)

        if case .readyToInstall(let version) = state, let pendingImmediateInstallHandler {
            pendingImmediateInstallVersion = version
            pendingImmediateInstallHandler()
            return
        }

        checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        guard hasConfiguredFeedURL else { return }
        updaterController.updater.automaticallyChecksForUpdates = enabled
        if !enabled {
            updaterController.updater.automaticallyDownloadsUpdates = false
        }
        syncAutomaticUpdateSettings(from: updaterController.updater)
        trackUpdateSettingChanged(settingID: "automatic_checks", enabled: enabled)

        if enabled {
            refreshUpdateStatus()
        }
    }

    func setAutomaticallyDownloadsUpdates(_ enabled: Bool) {
        guard hasConfiguredFeedURL else { return }

        if enabled {
            updaterController.updater.automaticallyChecksForUpdates = true
        }

        updaterController.updater.automaticallyDownloadsUpdates = enabled && updaterController.updater.allowsAutomaticUpdates
        syncAutomaticUpdateSettings(from: updaterController.updater)
        trackUpdateSettingChanged(
            settingID: "automatic_downloads",
            enabled: updaterController.updater.automaticallyDownloadsUpdates
        )

        guard updaterController.updater.automaticallyDownloadsUpdates,
              beginObservedUpdateCheckIfPossible(allowExistingSession: false) else { return }
        updaterController.updater.checkForUpdatesInBackground()
    }

    private func observeUpdaterReadiness() {
        canCheckObservation = updaterController.updater.observe(
            \.canCheckForUpdates,
            options: [.initial, .new]
        ) { [weak self] updater, _ in
            Task { @MainActor [weak self] in
                self?.syncReadiness(from: updater)
            }
        }
    }

    private func observeUpdaterSettings() {
        let updater = updaterController.updater
        updaterSettingObservations = [
            updater.observe(\.automaticallyChecksForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in
                    self?.syncAutomaticUpdateSettings(from: updater)
                }
            },
            updater.observe(\.automaticallyDownloadsUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in
                    self?.syncAutomaticUpdateSettings(from: updater)
                }
            },
            updater.observe(\.allowsAutomaticUpdates, options: [.initial, .new]) { [weak self] updater, _ in
                Task { @MainActor [weak self] in
                    self?.syncAutomaticUpdateSettings(from: updater)
                }
            },
        ]
    }

    private func beginObservedUpdateCheck() {
        switch updateStatus.state {
        case .updateAvailable, .downloading, .readyToInstall:
            syncReadiness(from: updaterController.updater)
        default:
            setUpdateStatus(.checking, canCheckForUpdates: updaterController.updater.canCheckForUpdates)
        }
    }

    private func beginObservedUpdateCheckIfPossible(allowExistingSession: Bool) -> Bool {
        let updater = updaterController.updater
        if updater.sessionInProgress {
            if allowExistingSession {
                beginObservedUpdateCheck()
            } else {
                syncReadiness(from: updater)
            }
            return false
        }

        guard updater.canCheckForUpdates else {
            markUpdaterIdle(from: updater)
            return false
        }

        didTrackCurrentUpdateCycleFailure = false
        beginObservedUpdateCheck()
        return true
    }

    private func syncReadiness(from updater: SPUUpdater) {
        let canCheckForUpdates = updater.canCheckForUpdates
        let nextState: UpdateStatus.State

        switch updateStatus.state {
        case .unknown where canCheckForUpdates:
            nextState = .readyToCheck
        default:
            nextState = updateStatus.state
        }

        setUpdateStatus(nextState, canCheckForUpdates: canCheckForUpdates)
    }

    private func syncAutomaticUpdateSettings(from updater: SPUUpdater) {
        let nextSettings = AutomaticUpdateSettings(
            automaticChecksEnabled: updater.automaticallyChecksForUpdates,
            automaticDownloadsAllowed: updater.allowsAutomaticUpdates,
            automaticDownloadsEnabled: updater.automaticallyDownloadsUpdates
        )
        guard nextSettings != automaticUpdateSettings else { return }
        automaticUpdateSettings = nextSettings
    }

    private func setUpdateStatus(_ state: UpdateStatus.State, canCheckForUpdates: Bool) {
        let nextStatus = UpdateStatus(state: state, canCheckForUpdates: canCheckForUpdates)
        guard nextStatus != updateStatus else { return }
        updateStatus = nextStatus
    }

    private func markNoUpdateAvailable(from updater: SPUUpdater) {
        if updateStatus.availableUpdateVersion != nil {
            trackUpdateCheckFinished(
                result: "no_change",
                state: updateStatus.state,
                version: updateStatus.availableUpdateVersion
            )
            return
        }

        let state = UpdateStatus.State.noUpdateAvailable
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        trackUpdateCheckFinished(result: "up_to_date", state: state, version: nil)
    }

    private func markUpdateCheckFailed(from updater: SPUUpdater) {
        markUpdateCheckFailed(from: updater, error: nil)
    }

    private func markUpdateCheckFailed(from updater: SPUUpdater, error: (any Error)?) {
        if error != nil {
            didTrackCurrentUpdateCycleFailure = true
        }

        if updateStatus.availableUpdateVersion == nil {
            let state: UpdateStatus.State = updater.canCheckForUpdates ? .readyToCheck : .unknown
            setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        }

        trackUpdateCheckFinished(
            result: "error",
            state: updateStatus.state,
            version: updateStatus.availableUpdateVersion,
            failureKind: UpdateFailureKind.classify(error).rawValue
        )
    }

    private func markUpdaterIdle(from updater: SPUUpdater) {
        guard updateStatus.availableUpdateVersion == nil else {
            syncReadiness(from: updater)
            return
        }

        let state: UpdateStatus.State = updater.canCheckForUpdates ? .readyToCheck : .unknown
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
    }

    private func versionString(for item: SUAppcastItem) -> String {
        Self.displayVersionString(for: item)
    }

    nonisolated private static func displayVersionString(for item: SUAppcastItem) -> String {
        let displayVersion = item.displayVersionString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !displayVersion.isEmpty {
            return displayVersion
        }

        let buildVersion = item.versionString.trimmingCharacters(in: .whitespacesAndNewlines)
        return buildVersion.isEmpty ? "unknown" : buildVersion
    }

    private var hasConfiguredFeedURL: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = normalizedHTTPSURL(value) else {
            return false
        }

        // Security: require an HTTPS Sparkle feed with a non-empty EdDSA public key.
        // If a tampered Info.plist swaps in HTTP or removes SUPublicEDKey, fail closed
        // instead of letting update checks proceed against an unsigned/plaintext channel.
        guard let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !publicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }

        return feedURL.host != nil
    }

    private func normalizedHTTPSURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme,
              scheme.caseInsensitiveCompare("https") == .orderedSame else {
            return nil
        }
        return url
    }

    private func trackUpdateActionClicked(surface: String, state: UpdateStatus.State, version: String?) {
        var properties = baseUpdateTelemetryProperties(state: state, version: version)
        properties["surface"] = surface
        properties["action_id"] = updateActionID(for: state)
        AnalyticsReporter.track("update_action_clicked", properties: properties)
    }

    private func trackUpdateSettingChanged(settingID: String, enabled: Bool) {
        AnalyticsReporter.track(
            "update_setting_changed",
            properties: [
                "enabled": enabled ? "true" : "false",
                "setting_id": settingID,
            ]
        )
    }

    private func trackUpdateCheckFinished(
        result: String,
        state: UpdateStatus.State,
        version: String?,
        failureKind: String? = nil
    ) {
        var properties = baseUpdateTelemetryProperties(state: state, version: version)
        properties["result"] = result
        if let failureKind {
            properties["failure_kind"] = failureKind
        }
        AnalyticsReporter.track("update_check_finished", properties: properties)
    }

    private func trackUpdateLifecycleEvent(
        _ event: String,
        state: UpdateStatus.State,
        version: String,
        failureKind: String? = nil
    ) {
        var properties = baseUpdateTelemetryProperties(state: state, version: version)
        if let failureKind {
            properties["failure_kind"] = failureKind
        }
        AnalyticsReporter.track(event, properties: properties)
    }

    private func baseUpdateTelemetryProperties(state: UpdateStatus.State, version: String?) -> [String: String] {
        var properties = [
            "automatic_downloads_enabled": automaticUpdateSettings.automaticDownloadsEnabled ? "true" : "false",
            "state": analyticsValue(for: state),
        ]
        if let version {
            properties["version"] = version
        }
        return properties
    }

    private func analyticsValue(for state: UpdateStatus.State) -> String {
        switch state {
        case .unknown:
            return "unknown"
        case .readyToCheck:
            return "ready"
        case .checking:
            return "checking"
        case .noUpdateAvailable:
            return "up_to_date"
        case .updateAvailable:
            return "available"
        case .downloading:
            return "downloading"
        case .readyToInstall:
            return "ready_to_install"
        }
    }

    private func updateActionID(for state: UpdateStatus.State) -> String {
        switch state {
        case .updateAvailable:
            return "install_update"
        case .readyToInstall:
            return "restart_to_update"
        case .checking, .downloading:
            return "view_update_progress"
        case .unknown, .readyToCheck, .noUpdateAvailable:
            return "check_updates"
        }
    }
}

extension SparkleUpdaterController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = versionString(for: item)
        let state = UpdateStatus.State.updateAvailable(version: version)
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        trackUpdateCheckFinished(result: "available", state: state, version: version)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        markUpdateCheckFailed(from: updater, error: error)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        markNoUpdateAvailable(from: updater)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let version = versionString(for: item)
        let state = UpdateStatus.State.downloading(version: version)
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        trackUpdateLifecycleEvent("update_download_started", state: state, version: version)
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        let version = versionString(for: item)
        let state = UpdateStatus.State.downloading(version: version)
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        trackUpdateLifecycleEvent("update_download_finished", state: state, version: version)
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: any Error) {
        let version = versionString(for: item)
        let state = UpdateStatus.State.updateAvailable(version: version)
        let failureKind = UpdateFailureKind.classify(error, fallback: .downloadFailed).rawValue
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        trackUpdateLifecycleEvent(
            "update_download_finished",
            state: state,
            version: version,
            failureKind: failureKind
        )
        trackUpdateCheckFinished(
            result: "download_failed",
            state: state,
            version: version,
            failureKind: failureKind
        )
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = versionString(for: item)
        let state = UpdateStatus.State.readyToInstall(version: version)
        pendingImmediateInstallHandler = immediateInstallHandler
        pendingImmediateInstallVersion = version
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        trackUpdateLifecycleEvent("update_ready_to_install", state: state, version: version)
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        if let error {
            guard !didTrackCurrentUpdateCycleFailure else { return }
            markUpdateCheckFailed(from: updater, error: error)
            return
        }

        didTrackCurrentUpdateCycleFailure = false
        let fallbackState: UpdateStatus.State
        switch updateStatus.state {
        case .checking, .unknown:
            fallbackState = updater.canCheckForUpdates ? .readyToCheck : .unknown
        default:
            fallbackState = updateStatus.state
        }

        setUpdateStatus(fallbackState, canCheckForUpdates: updater.canCheckForUpdates)
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        if let pendingImmediateInstallVersion {
            AnalyticsReporter.track(
                "update_relaunching",
                properties: ["version": pendingImmediateInstallVersion]
            )
        }
        pendingImmediateInstallHandler = nil
        pendingImmediateInstallVersion = nil
    }
}

extension SparkleUpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        update.isCriticalUpdate
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = Self.displayVersionString(for: update)
        let updateState: UpdateStatus.State
        switch state.stage {
        case .downloaded, .installing:
            updateState = .readyToInstall(version: version)
        case .notDownloaded:
            updateState = .updateAvailable(version: version)
        @unknown default:
            updateState = .updateAvailable(version: version)
        }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.setUpdateStatus(
                updateState,
                canCheckForUpdates: self.updaterController.updater.canCheckForUpdates
            )
        }
    }
}
