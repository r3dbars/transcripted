import AppKit
import Combine
import Foundation
import Network
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
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
    var shouldDeferBackgroundUpdateCheck: () -> Bool = { false }
    private let networkPathMonitor = NWPathMonitor()
    /// A phone hotspot (`isExpensive`) or Low Data Mode (`isConstrained`).
    var isOnCostlyNetwork = false
    /// False until macOS reports the first network path. Until then the
    /// network counts as costly, so a launch-time download never starts on a
    /// hotspot just because the report was still on its way.
    var hasReportedNetworkPath = false
    /// The launch-time check waits briefly for the first network report so it
    /// can download right away on a normal network instead of deferring.
    private var isStartupCheckWaitingForNetwork = false
    private static let startupNetworkWaitNanoseconds: UInt64 = 3_000_000_000
    /// True while Sparkle's own update UI shows or quietly holds an update,
    /// the only time its standard check brings that update forward.
    var isSparkleHoldingUpdate = false
    /// An Install click that landed while Sparkle was still reading the feed.
    /// It is honored once Sparkle either holds the update or ends the cycle.
    var hasPendingUserUpdateAction = false
    /// Answers a parked click if Sparkle hasn't within this long. Replays can
    /// park the click again (a probe or background check can start right as a
    /// cycle ends), so without a deadline it could wait for Sparkle's next
    /// scheduled check, hours away (#1830). A feed read takes seconds.
    private var pendingUserUpdateActionTimeout: Task<Void, Never>?
    private static let pendingUserUpdateActionTimeoutNanoseconds: UInt64 = 20_000_000_000
    /// The kind of Sparkle check running now, recorded when Sparkle asks
    /// permission to start it. Tells a probe (no download follows) apart from
    /// a background check that downloads on its own.
    var currentUpdateCheck: SPUUpdateCheck?

    lazy var updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: self,
        userDriverDelegate: self
    )
    private var canCheckObservation: NSKeyValueObservation?
    private var updaterSettingObservations: [NSKeyValueObservation] = []
    private var hasPerformedStartupCheck = false
    var pendingImmediateInstallHandler: (() -> Void)?
    var pendingImmediateInstallVersion: String?
    var lastTrackedReadyToInstallVersion: String?
    var didTrackCurrentUpdateCycleFailure = false
    private var observedUpdateCheckTimeoutTask: Task<Void, Never>?
    private static let observedUpdateCheckTimeoutNanoseconds: UInt64 = 30_000_000_000
    static let pendingInstalledUpdateVersionKey = "Transcripted.PendingInstalledUpdateVersion"
    static let pendingInstalledUpdatePreviousVersionKey = "Transcripted.PendingInstalledUpdatePreviousVersion"
    static let pendingInstalledUpdateKindKey = "Transcripted.PendingInstalledUpdateKind"
    static let lastLaunchedAppVersionKey = "Transcripted.LastLaunchedAppVersion"
    static let deferredBackgroundCheckErrorDomain = "Transcripted.UpdateCheckDeferred"
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
    private func runUserUpdateAction(allowsWaiting: Bool = true) {
        // Never start Sparkle for a build without a valid feed.
        let updater = hasConfiguredFeedURL ? updaterController.updater : nil
        let route = UpdateClickRoutingPolicy.route(
            state: updateStatus.actionSafetyState,
            hasConfiguredFeed: updater != nil,
            hasImmediateInstallHandler: pendingImmediateInstallHandler != nil,
            sessionInProgress: updater?.sessionInProgress ?? false,
            isSparkleHoldingUpdate: isSparkleHoldingUpdate,
            canCheckForUpdates: updater?.canCheckForUpdates ?? false,
            allowsWaiting: allowsWaiting
        )
        if route != .waitForFeedRead {
            // This answers any earlier parked click too, so a later cycle end
            // or held-update callback must not replay it and reopen the window.
            hasPendingUserUpdateAction = false
            cancelPendingUserUpdateActionTimeout()
        }

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
            // Sparkle holds the update or ends the session, or the deadline.
            hasPendingUserUpdateAction = true
            schedulePendingUserUpdateActionTimeout()
        case .explain(let problem):
            presentUpdateClickProblem(problem)
        }
    }

    /// Menu bar clicks leave another app active. Sparkle 2.9.1 activates with
    /// the cooperative `NSApp.activate()`, which macOS can refuse, and then
    /// its window opens behind the frontmost app. Activate the way the rest of
    /// the app does before it opens its own windows.
    func activateForUpdateWindow() {
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

    func performPendingUserUpdateAction(allowsWaiting: Bool = true) {
        // Only an update that still needs a click. A download that finished
        // meanwhile shows "Restart to Update" and waits for its own click.
        guard case .updateAvailable = updateStatus.state,
              canReplayParkedUserUpdateAction() else {
            hasPendingUserUpdateAction = false
            cancelPendingUserUpdateActionTimeout()
            return
        }
        runUserUpdateAction(allowsWaiting: allowsWaiting)
    }

    /// A parked click runs later, when something else may have started. The
    /// menu row is disabled while the Mac is recording, dictating or
    /// transcribing, so a replay must not pull the app forward (or open an
    /// alert) then either. The row keeps saying what it waits on, so the
    /// person can click again once that finishes.
    func canReplayParkedUserUpdateAction() -> Bool {
        !shouldDeferBackgroundUpdateCheck()
    }

    private func schedulePendingUserUpdateActionTimeout() {
        // A replay that parks again keeps the first click's deadline.
        guard pendingUserUpdateActionTimeout == nil else { return }
        pendingUserUpdateActionTimeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.pendingUserUpdateActionTimeoutNanoseconds)
            guard !Task.isCancelled else { return }
            self?.expirePendingUserUpdateAction()
        }
    }

    func cancelPendingUserUpdateActionTimeout() {
        pendingUserUpdateActionTimeout?.cancel()
        pendingUserUpdateActionTimeout = nil
    }

    private func expirePendingUserUpdateAction() {
        pendingUserUpdateActionTimeout = nil
        guard hasPendingUserUpdateAction else { return }
        hasPendingUserUpdateAction = false
        // Open Sparkle's window if it's free now; otherwise say it's busy.
        performPendingUserUpdateAction(allowsWaiting: false)
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
                self?.answerPendingUserUpdateActionIfUpdaterReady(updater)
            }
        }
    }

    /// Sparkle turns `canCheckForUpdates` back on when a session ends or its
    /// driver shows an update. Either way a parked click can run now instead
    /// of waiting out the 20 s backstop. The cycle-end and held-update
    /// callbacks may get there first; whichever runs clears the flag, so the
    /// click runs once.
    private func answerPendingUserUpdateActionIfUpdaterReady(_ updater: SPUUpdater) {
        guard hasPendingUserUpdateAction, updater.canCheckForUpdates else { return }
        hasPendingUserUpdateAction = false
        performPendingUserUpdateAction()
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

    func syncReadiness(from updater: SPUUpdater) {
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
    func setUpdateStatus(
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

    func markNoUpdateAvailable(from updater: SPUUpdater) {
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

    func markUpdateCheckFailed(from updater: SPUUpdater) {
        markUpdateCheckFailed(from: updater, error: nil)
    }

    func markUpdateCheckFailed(
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

    func markUpdaterIdle(from updater: SPUUpdater) {
        cancelObservedUpdateCheckTimeout()
        guard updateStatus.availableUpdateVersion == nil else {
            syncReadiness(from: updater)
            return
        }

        let state: UpdateStatus.State = updater.canCheckForUpdates ? .readyToCheck : .unknown
        setUpdateStatus(state, canCheckForUpdates: updater.canCheckForUpdates)
    }

    func versionString(for item: SUAppcastItem) -> String {
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

    func cancelObservedUpdateCheckTimeout() {
        observedUpdateCheckTimeoutTask?.cancel()
        observedUpdateCheckTimeoutTask = nil
    }

    nonisolated static func displayVersionString(for item: SUAppcastItem) -> String {
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
}
