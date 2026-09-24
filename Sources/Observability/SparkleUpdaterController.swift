import AppKit
import Combine
import Foundation
import Network
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
        /// Sparkle will not fetch this available update on its own: a
        /// background download failed, or Sparkle handed the update back as a
        /// quiet reminder. The person has to start the install, so the update
        /// must read as actionable even when automatic downloads are on.
        var requiresUserInstall = false

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

        var actionSafetyState: UpdateActionSafetyState {
            switch state {
            case .unknown:
                return .unknown
            case .readyToCheck:
                return .readyToCheck
            case .checking:
                return .checking
            case .noUpdateAvailable:
                return .noUpdateAvailable
            case .updateAvailable:
                return .updateAvailable
            case .downloading:
                return .downloading
            case .readyToInstall:
                return .readyToInstall
            }
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

    /// True while a found update will be fetched by Sparkle without a click,
    /// so update surfaces show quiet progress instead of an Install button.
    var availableUpdateDownloadsAutomatically: Bool {
        Self.availableUpdateDownloadsAutomatically(status: updateStatus, settings: automaticUpdateSettings)
    }

    /// Drives the orange menu bar badge and the settings footer badge.
    var updateNeedsUserAction: Bool {
        Self.updateNeedsUserAction(status: updateStatus, settings: automaticUpdateSettings)
    }

    /// Static forms for Combine sinks: `@Published` emits before the stored
    /// value changes, so a sink must use the values it was handed.
    static func availableUpdateDownloadsAutomatically(
        status: UpdateStatus,
        settings: AutomaticUpdateSettings
    ) -> Bool {
        settings.automaticDownloadsEnabled && !status.requiresUserInstall
    }

    static func updateNeedsUserAction(status: UpdateStatus, settings: AutomaticUpdateSettings) -> Bool {
        UpdateAttentionPolicy.needsUserAction(
            state: status.actionSafetyState,
            availableUpdateDownloadsAutomatically: availableUpdateDownloadsAutomatically(
                status: status,
                settings: settings
            )
        )
    }

    /// Returns true while the Mac is busy (meeting capture, dictation,
    /// transcription or import work), so Sparkle does not start a large
    /// background download then. See `BackgroundUpdateDeferralPolicy`.
    private var shouldDeferBackgroundUpdateCheck: () -> Bool = { false }
    private let networkPathMonitor = NWPathMonitor()
    /// A phone hotspot (`isExpensive`) or Low Data Mode (`isConstrained`).
    private var isOnCostlyNetwork = false
    /// False until macOS reports the first network path. Until then the
    /// network counts as costly, so a launch-time download never starts on a
    /// hotspot just because the report was still on its way.
    private var hasReportedNetworkPath = false
    /// The launch-time check waits briefly for the first network report so it
    /// can download right away on a normal network instead of deferring.
    private var isStartupCheckWaitingForNetwork = false
    private static let startupNetworkWaitNanoseconds: UInt64 = 3_000_000_000
    /// True while Sparkle's own update UI shows or quietly holds an update,
    /// the only time its standard check brings that update forward.
    private var isSparkleHoldingUpdate = false
    /// An Install click that landed while Sparkle was still reading the feed.
    /// It is honored once Sparkle either holds the update or ends the cycle.
    private var hasPendingUserUpdateAction = false
    /// The kind of Sparkle check running now, recorded when Sparkle asks
    /// permission to start it. Tells a probe (no download follows) apart from
    /// a background check that downloads on its own.
    private var currentUpdateCheck: SPUUpdateCheck?

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
    private var lastTrackedReadyToInstallVersion: String?
    private var didTrackCurrentUpdateCycleFailure = false
    private var observedUpdateCheckTimeoutTask: Task<Void, Never>?
    private static let observedUpdateCheckTimeoutNanoseconds: UInt64 = 30_000_000_000
    private static let pendingInstalledUpdateVersionKey = "Transcripted.PendingInstalledUpdateVersion"
    private static let pendingInstalledUpdatePreviousVersionKey = "Transcripted.PendingInstalledUpdatePreviousVersion"
    private static let pendingInstalledUpdateKindKey = "Transcripted.PendingInstalledUpdateKind"
    private static let lastLaunchedAppVersionKey = "Transcripted.LastLaunchedAppVersion"
    private static let deferredBackgroundCheckErrorDomain = "Transcripted.UpdateCheckDeferred"
    private static var isLaunchUISmoke: Bool {
        AutomatedLaunchEnvironment.isActive()
    }

    override init() {
        super.init()
        guard !Self.isLaunchUISmoke else {
            applyLaunchUISmokeUpdateStateIfPresent()
            return
        }
        trackInstalledUpdateIfNeeded()
        observeNetworkCost()
        observeUpdaterReadiness()
        observeUpdaterSettings()
    }

    private func observeNetworkCost() {
        networkPathMonitor.pathUpdateHandler = { [weak self] path in
            let isCostly = path.isExpensive || path.isConstrained
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isOnCostlyNetwork = isCostly
                self.hasReportedNetworkPath = true
                self.runStartupUpdateCheckIfWaitingForNetwork()
            }
        }
        networkPathMonitor.start(queue: DispatchQueue(label: "com.transcripted.update-network-path", qos: .utility))
    }

    private func applyLaunchUISmokeUpdateStateIfPresent() {
        guard let state = Self.launchUISmokeUpdateState() else { return }
        updateStatus = UpdateStatus(state: state, canCheckForUpdates: true)
        automaticUpdateSettings = AutomaticUpdateSettings(
            automaticChecksEnabled: true,
            automaticDownloadsAllowed: true,
            automaticDownloadsEnabled: false
        )
    }

    nonisolated private static func launchUISmokeUpdateState() -> UpdateStatus.State? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawState = environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_UPDATE_STATE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            !rawState.isEmpty else {
            return nil
        }
        let version = environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_UPDATE_VERSION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let displayVersion = version?.isEmpty == false ? version! : "9.9.9"

        switch rawState {
        case "available", "update-available":
            return .updateAvailable(version: displayVersion)
        case "downloading", "download-progress":
            return .downloading(version: displayVersion)
        case "ready", "ready-to-install":
            return .readyToInstall(version: displayVersion)
        default:
            return nil
        }
    }

    func setBackgroundUpdateCheckDeferral(_ shouldDefer: @escaping () -> Bool) {
        shouldDeferBackgroundUpdateCheck = shouldDefer
    }

    func performStartupUpdateCheckIfNeeded() {
        guard !Self.isLaunchUISmoke else { return }
        guard !hasPerformedStartupCheck else { return }
        hasPerformedStartupCheck = true

        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }

        if updaterController.updater.automaticallyChecksForUpdates {
            guard hasReportedNetworkPath else {
                // Waiting a moment beats deferring the download for a whole
                // check interval because the network was not known yet.
                isStartupCheckWaitingForNetwork = true
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: Self.startupNetworkWaitNanoseconds)
                    self?.runStartupUpdateCheckIfWaitingForNetwork()
                }
                return
            }
            runStartupBackgroundUpdateCheck()
        } else {
            refreshUpdateStatus()
        }
    }

    private func runStartupUpdateCheckIfWaitingForNetwork() {
        guard isStartupCheckWaitingForNetwork else { return }
        isStartupCheckWaitingForNetwork = false
        guard updaterController.updater.automaticallyChecksForUpdates else {
            refreshUpdateStatus()
            return
        }
        // If the network is still unknown after the wait, the check runs
        // anyway; `mayPerform` treats that as costly and only reads the feed.
        runStartupBackgroundUpdateCheck()
    }

    private func runStartupBackgroundUpdateCheck() {
        // Sparkle recommends forcing launch-time background checks, if
        // desired, immediately after the updater has started and only when
        // automatic checks are enabled.
        guard beginObservedUpdateCheckIfPossible() else { return }
        updaterController.updater.checkForUpdatesInBackground()
    }

    func checkForUpdates() {
        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }

        guard beginObservedUpdateCheckIfPossible() else { return }
        updaterController.checkForUpdates(nil)
    }

    func refreshUpdateStatus() {
        guard !Self.isLaunchUISmoke else { return }
        guard hasConfiguredFeedURL else {
            setUpdateStatus(.unknown, canCheckForUpdates: false)
            return
        }

        guard beginObservedUpdateCheckIfPossible() else { return }
        updaterController.updater.checkForUpdateInformation()
    }

    func performUserUpdateAction(surface: String) {
        let state = updateStatus.state
        let version = updateStatus.availableUpdateVersion
        trackUpdateActionClicked(surface: surface, state: state, version: version)
        runUserUpdateAction()
    }

    /// Every route opens Sparkle's window, installs, or explains why it
    /// can't (#1830). See `UpdateClickRoutingPolicy`.
    private func runUserUpdateAction() {
        // Never start Sparkle for a build without a valid feed.
        let updater = hasConfiguredFeedURL ? updaterController.updater : nil
        let route = UpdateClickRoutingPolicy.route(
            state: updateStatus.actionSafetyState,
            hasConfiguredFeed: updater != nil,
            hasImmediateInstallHandler: pendingImmediateInstallHandler != nil,
            sessionInProgress: updater?.sessionInProgress ?? false,
            isSparkleHoldingUpdate: isSparkleHoldingUpdate,
            canCheckForUpdates: updater?.canCheckForUpdates ?? false
        )

        switch route {
        case .installImmediately:
            pendingImmediateInstallVersion = updateStatus.readyToInstallVersion
            pendingImmediateInstallHandler?()
        case .showHeldUpdate:
            // Sparkle keeps its session open while it holds this update, so
            // the guarded check path would do nothing. The standard controller
            // brings the held window forward instead.
            activateForUpdateWindow()
            updaterController.checkForUpdates(nil)
        case .startUserCheck:
            activateForUpdateWindow()
            checkForUpdates()
        case .waitForFeedRead:
            // Sparkle is still reading the feed (a probe, or the start of a
            // background check) and would ignore the click. Keep it until
            // Sparkle holds the update or ends the session.
            hasPendingUserUpdateAction = true
        case .explain(let problem):
            presentUpdateClickProblem(problem)
        }
    }

    /// Menu bar clicks leave another app active. Sparkle 2.9.1 activates with
    /// the cooperative `NSApp.activate()`, which macOS can refuse, and then
    /// its window opens behind the frontmost app. Activate the way the rest of
    /// the app does before it opens its own windows.
    private func activateForUpdateWindow() {
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentUpdateClickProblem(_ problem: UpdateClickProblem) {
        let message = UpdateClickRoutingPolicy.message(for: problem)
        activateForUpdateWindow()
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = message.title
        alert.informativeText = message.detail
        alert.addButton(withTitle: "Open Download Page")
        alert.addButton(withTitle: "OK")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(UpdateClickRoutingPolicy.downloadPageURL)
        }
    }

    private func performPendingUserUpdateAction() {
        // Only an update that still needs a click. A download that finished
        // meanwhile shows "Restart to Update" and waits for its own click.
        guard case .updateAvailable = updateStatus.state else { return }
        runUserUpdateAction()
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
              beginObservedUpdateCheckIfPossible() else { return }
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
            cancelObservedUpdateCheckTimeout()
            syncReadiness(from: updaterController.updater)
        default:
            setUpdateStatus(.checking, canCheckForUpdates: updaterController.updater.canCheckForUpdates)
            scheduleObservedUpdateCheckTimeout()
        }
    }

    private func beginObservedUpdateCheckIfPossible() -> Bool {
        let updater = updaterController.updater
        if updater.sessionInProgress {
            syncReadiness(from: updater)
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

    /// `requiresUserInstall` only describes one available update. When the
    /// caller leaves it nil it carries over while the state stays on that same
    /// available version, and clears on any other state.
    private func setUpdateStatus(
        _ state: UpdateStatus.State,
        canCheckForUpdates: Bool,
        requiresUserInstall: Bool? = nil
    ) {
        let carriedRequiresUserInstall: Bool
        if let requiresUserInstall {
            carriedRequiresUserInstall = requiresUserInstall
        } else if case .updateAvailable = state, state == updateStatus.state {
            carriedRequiresUserInstall = updateStatus.requiresUserInstall
        } else {
            carriedRequiresUserInstall = false
        }

        let nextStatus = UpdateStatus(
            state: state,
            canCheckForUpdates: canCheckForUpdates,
            requiresUserInstall: carriedRequiresUserInstall
        )
        guard nextStatus != updateStatus else { return }
        updateStatus = nextStatus
    }

    private func markNoUpdateAvailable(from updater: SPUUpdater) {
        cancelObservedUpdateCheckTimeout()
        // A found-but-not-downloaded update that a later check no longer
        // offers was skipped or pulled from the feed (background checks
        // filter skipped versions), so the badge must not stay on it.
        if case .updateAvailable = updateStatus.state {
            let state = UpdateStatus.State.noUpdateAvailable
            setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
            trackUpdateCheckFinished(result: "up_to_date", state: state, version: nil)
            return
        }

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

    private func markUpdateCheckFailed(
        from updater: SPUUpdater,
        error: (any Error)?,
        fallback: UpdateFailureKind = .unknown
    ) {
        cancelObservedUpdateCheckTimeout()
        didTrackCurrentUpdateCycleFailure = true

        if updateStatus.availableUpdateVersion == nil {
            let state: UpdateStatus.State = updater.canCheckForUpdates ? .readyToCheck : .unknown
            setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
        }

        trackUpdateCheckFinished(
            result: "error",
            state: updateStatus.state,
            version: updateStatus.availableUpdateVersion,
            failureKind: UpdateFailureKind.classify(error, fallback: fallback).rawValue,
            failureCode: UpdateFailureKind.diagnosticCode(error)
        )
    }

    private func markUpdaterIdle(from updater: SPUUpdater) {
        cancelObservedUpdateCheckTimeout()
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

    private func scheduleObservedUpdateCheckTimeout() {
        observedUpdateCheckTimeoutTask?.cancel()
        observedUpdateCheckTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.observedUpdateCheckTimeoutNanoseconds)
            guard let self, !Task.isCancelled, self.updateStatus.state == .checking else { return }
            self.markUpdateCheckFailed(
                from: self.updaterController.updater,
                error: nil,
                fallback: .checkTimedOut
            )
        }
    }

    private func cancelObservedUpdateCheckTimeout() {
        observedUpdateCheckTimeoutTask?.cancel()
        observedUpdateCheckTimeoutTask = nil
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
        failureKind: String? = nil,
        failureCode: String? = nil
    ) {
        var properties = baseUpdateTelemetryProperties(state: state, version: version)
        properties["result"] = result
        if let failureKind {
            properties["failure_kind"] = failureKind
        }
        if let failureCode {
            properties["failure_code"] = failureCode
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

        switch event {
        case "update_download_started":
            ProductFrictionTelemetry.track(
                surface: .update,
                stage: "update_download",
                result: .started
            )
        case "update_download_finished":
            ProductFrictionTelemetry.track(
                surface: .update,
                stage: "update_download",
                result: failureKind == nil ? .completed : .failed,
                failureKind: failureKind
            )
        default:
            break
        }
    }

    private func currentAppVersion() -> String {
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return version.isEmpty ? "unknown" : version
    }

    private func rememberPendingInstalledUpdate(version: String, kind: UpdateInstallKind) {
        let trimmedVersion = version.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty else { return }

        let defaults = UserDefaults.standard
        defaults.set(trimmedVersion, forKey: Self.pendingInstalledUpdateVersionKey)
        defaults.set(currentAppVersion(), forKey: Self.pendingInstalledUpdatePreviousVersionKey)
        defaults.set(kind.rawValue, forKey: Self.pendingInstalledUpdateKindKey)
    }

    /// Counts every install path once, on the first launch of a newer version:
    /// the in-app restart, Sparkle's silent install on quit, and installs from
    /// a DMG or Homebrew (`unattributed`). Before this, only the in-app
    /// restart was counted, so `update_installed` undercounted real installs.
    private func trackInstalledUpdateIfNeeded() {
        let defaults = UserDefaults.standard
        let currentVersion = currentAppVersion()
        let outcome = UpdateInstallDetection.detect(
            currentVersion: currentVersion,
            lastLaunchedVersion: defaults.string(forKey: Self.lastLaunchedAppVersionKey),
            pendingVersion: defaults.string(forKey: Self.pendingInstalledUpdateVersionKey),
            pendingPreviousVersion: defaults.string(forKey: Self.pendingInstalledUpdatePreviousVersionKey),
            pendingKind: defaults.string(forKey: Self.pendingInstalledUpdateKindKey)
        )

        if let record = outcome.record {
            var properties = [
                "install_kind": record.kind.rawValue,
                "version": record.version,
            ]
            if let previousVersion = record.previousVersion {
                properties["previous_version"] = previousVersion
            }
            AnalyticsReporter.track("update_installed", properties: properties)
        }

        if outcome.clearPendingMarkers {
            defaults.removeObject(forKey: Self.pendingInstalledUpdateVersionKey)
            defaults.removeObject(forKey: Self.pendingInstalledUpdatePreviousVersionKey)
            defaults.removeObject(forKey: Self.pendingInstalledUpdateKindKey)
        }

        if let versionToRemember = outcome.versionToRemember {
            defaults.set(versionToRemember, forKey: Self.lastLaunchedAppVersionKey)
        }
    }

    private func markUpdateReadyToInstall(from updater: SPUUpdater, version: String) {
        let state = UpdateStatus.State.readyToInstall(version: version)
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)

        guard lastTrackedReadyToInstallVersion != version else { return }
        lastTrackedReadyToInstallVersion = version
        trackUpdateLifecycleEvent("update_ready_to_install", state: state, version: version)
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
        cancelObservedUpdateCheckTimeout()
        let version = versionString(for: item)
        if case .readyToInstall(let heldVersion) = updateStatus.state, heldVersion == version {
            // A probe resumes an update Sparkle already downloaded and still
            // holds. It is still ready to install; keep "Restart to Update".
            syncReadiness(from: updater)
            return
        }
        let state = UpdateStatus.State.updateAvailable(version: version)
        // A probe only reads the feed; nothing downloads after it, so the
        // update needs a click even with automatic downloads on.
        setUpdateStatus(
            state,
            canCheckForUpdates: updater.canCheckForUpdates,
            requiresUserInstall: currentUpdateCheck == .updateInformation ? true : nil
        )
        trackUpdateCheckFinished(result: "available", state: state, version: version)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        if UpdateFailureKind.isNoUpdate(error) {
            markNoUpdateAvailable(from: updater)
            return
        }

        markUpdateCheckFailed(from: updater, error: error)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        markNoUpdateAvailable(from: updater)
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        let version = versionString(for: item)
        let state = UpdateStatus.State.downloading(version: version)
        // The download itself answers an Install click made during the
        // feed read; the menu now shows it preparing.
        hasPendingUserUpdateAction = false
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
        let failureCode = UpdateFailureKind.diagnosticCode(error)
        // Sparkle will not retry until its next scheduled check, hours away.
        // Hand the update to the person instead of showing "Preparing Update"
        // with a disabled button until then.
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates, requiresUserInstall: true)
        // This cycle's failure is counted here; the cycle-finished callback
        // that follows must not count it again as a check error.
        didTrackCurrentUpdateCycleFailure = true
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
            failureKind: failureKind,
            failureCode: failureCode
        )
    }

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        let version = versionString(for: item)
        pendingImmediateInstallHandler = immediateInstallHandler
        pendingImmediateInstallVersion = version
        // Sparkle installs a staged update whenever the app quits. Record it
        // now so the next launch can count that install; a relaunch through
        // "Restart to Update" overwrites the kind with `restart`.
        rememberPendingInstalledUpdate(version: version, kind: .quit)
        markUpdateReadyToInstall(from: updater, version: version)
        return true
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        let isBackgroundCheck = updateCheck == .updatesInBackground
        let reason = BackgroundUpdateDeferralPolicy.deferralReason(
            isBackgroundCheck: isBackgroundCheck,
            automaticDownloadsEnabled: updater.automaticallyDownloadsUpdates,
            isBusy: isBackgroundCheck && shouldDeferBackgroundUpdateCheck(),
            isOnCostlyNetwork: isOnCostlyNetwork || !hasReportedNetworkPath
        )
        guard let reason else {
            currentUpdateCheck = updateCheck
            return
        }

        currentUpdateCheck = nil
        // Sparkle ends this cycle with the error, shows nothing, and keeps its
        // normal schedule, so the next background check runs an interval later.
        // Sparkle cannot pause a download that already started; this only
        // stops new ones.
        throw NSError(
            domain: Self.deferredBackgroundCheckErrorDomain,
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Background update download deferred (\(reason.rawValue))."]
        )
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: (any Error)?) {
        cancelObservedUpdateCheckTimeout()
        // Each cycle dedupes its own failure. Reset when it ends so the next
        // scheduled check (which never passes through the observed-check
        // entry point) can report its own failure.
        let hadPendingUserUpdateAction = hasPendingUserUpdateAction
        defer {
            didTrackCurrentUpdateCycleFailure = false
            currentUpdateCheck = nil
            isSparkleHoldingUpdate = false
            hasPendingUserUpdateAction = false
            if hadPendingUserUpdateAction {
                // The Install click came in while Sparkle was reading the
                // feed. Run it now that the session is over, after this
                // callback returns so Sparkle keeps its schedule.
                Task { @MainActor [weak self] in
                    self?.performPendingUserUpdateAction()
                }
            }
        }

        if let error, (error as NSError).domain == Self.deferredBackgroundCheckErrorDomain {
            if case .checking = updateStatus.state {
                markUpdaterIdle(from: updater)
            } else {
                cancelObservedUpdateCheckTimeout()
                syncReadiness(from: updater)
            }
            // A downloaded update is already on screen as "Restart to
            // Update"; a probe would only resume it.
            if case .readyToInstall = updateStatus.state { return }
            // Still read the feed (a few KB) so a waiting update shows up with
            // an Install button; only the automatic download waits. Run it
            // after this callback returns: starting a session inside it would
            // stop Sparkle from scheduling its next check.
            Task { @MainActor [weak self] in
                self?.refreshUpdateStatus()
            }
            return
        }

        // A cycle never ends mid-download when things go well: a staged update
        // stalls the cycle (install on quit), and a dismissed downloaded update
        // is already `.readyToInstall`. Still `.downloading` here means the
        // download or the install prep after it failed or was canceled
        // (unarchive, signature, disk space). Hand it back as an Install
        // action instead of a disabled "Preparing Update" for hours.
        if case .downloading(let version) = updateStatus.state {
            setUpdateStatus(
                .updateAvailable(version: version),
                canCheckForUpdates: updater.canCheckForUpdates,
                requiresUserInstall: true
            )
        }

        if let error {
            if UpdateFailureKind.isNoUpdate(error) {
                guard !didTrackCurrentUpdateCycleFailure else { return }
                // `updaterDidNotFindUpdate` already handled this result unless
                // the observed check is still waiting on it.
                if case .checking = updateStatus.state {
                    markNoUpdateAvailable(from: updater)
                }
                return
            }

            guard !didTrackCurrentUpdateCycleFailure else { return }
            markUpdateCheckFailed(from: updater, error: error)
            return
        }

        let fallbackState: UpdateStatus.State
        switch updateStatus.state {
        case .checking, .unknown:
            fallbackState = updater.canCheckForUpdates ? .readyToCheck : .unknown
        default:
            fallbackState = updateStatus.state
        }

        setUpdateStatus(fallbackState, canCheckForUpdates: updater.canCheckForUpdates)
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .skip:
            // Background checks never offer a skipped version again, so
            // nothing else would clear the badge for the rest of the session.
            setUpdateStatus(.readyToCheck, canCheckForUpdates: updater.canCheckForUpdates, requiresUserInstall: false)
        case .dismiss:
            switch state.stage {
            case .downloaded, .installing:
                // Sparkle keeps a dismissed downloaded update and installs it
                // on quit, so it reads as ready to restart, not "Preparing".
                markUpdateReadyToInstall(from: updater, version: versionString(for: updateItem))
            case .notDownloaded:
                // "Remind me later": the badge is that reminder.
                break
            @unknown default:
                break
            }
        case .install:
            break
        @unknown default:
            break
        }
    }

    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        // Sparkle's own install-and-relaunch (standard UI) never sets the
        // immediate-install version, so fall back to the update on screen.
        if let relaunchVersion = pendingImmediateInstallVersion ?? updateStatus.availableUpdateVersion {
            rememberPendingInstalledUpdate(version: relaunchVersion, kind: .restart)
            AnalyticsReporter.track(
                "update_relaunching",
                properties: ["version": relaunchVersion]
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
            self.isSparkleHoldingUpdate = true
            if self.hasPendingUserUpdateAction {
                self.hasPendingUserUpdateAction = false
                if !handleShowingUpdate {
                    // A quiet reminder: bring it forward for the Install
                    // click that arrived during the feed read.
                    self.activateForUpdateWindow()
                    self.updaterController.checkForUpdates(nil)
                }
            }
            switch updateState {
            case .readyToInstall(let version):
                self.markUpdateReadyToInstall(from: self.updaterController.updater, version: version)
            case .updateAvailable:
                // Sparkle hands an update to its user driver only when it will
                // not download it silently, so the person has to act on it.
                self.setUpdateStatus(
                    updateState,
                    canCheckForUpdates: self.updaterController.updater.canCheckForUpdates,
                    requiresUserInstall: true
                )
            case .unknown, .readyToCheck, .checking, .noUpdateAvailable, .downloading:
                self.setUpdateStatus(
                    updateState,
                    canCheckForUpdates: self.updaterController.updater.canCheckForUpdates
                )
            }
        }
    }
}
