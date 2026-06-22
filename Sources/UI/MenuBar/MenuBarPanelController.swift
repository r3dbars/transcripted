// MenuBarPanelController.swift
// NSViewController that hosts the menubar popover and wires actions/subscriptions.

import AppKit
import Combine

struct MenuBarLaunchUISmokeReport: Codable, Equatable {
    let appLaunched: Bool
    let statusItemExists: Bool
    let popoverConfigured: Bool
    let onboardingCompleted: Bool
    let content: MenuBarContentSmokeSnapshot
}

@MainActor
final class MenuBarPanelController: NSViewController {
    private let appState: TranscriptedAppState
    private let dismissPopover: () -> Void
    private let openSettingsWindow: (TranscriptedSettingsPage) -> Void
    private let preferredSourceAppProvider: () -> NSRunningApplication?
    private let textPaster = ClipboardRestoringTextPaster()

    private var contentView: MenuBarContentView?
    private var subscriptions = Set<AnyCancellable>()
    private var latestDictation: SavedDictationEntry?
    private var latestDictationLoaded = false
    private var latestDictationTask: Task<Void, Never>?
    private var scheduledRefreshTask: Task<Void, Never>?

    init(
        appState: TranscriptedAppState,
        preferredSourceAppProvider: @escaping () -> NSRunningApplication?,
        openSettingsWindow: @escaping (TranscriptedSettingsPage) -> Void,
        dismissPopover: @escaping () -> Void
    ) {
        self.appState = appState
        self.preferredSourceAppProvider = preferredSourceAppProvider
        self.openSettingsWindow = openSettingsWindow
        self.dismissPopover = dismissPopover
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        latestDictationTask?.cancel()
        scheduledRefreshTask?.cancel()
    }

    override func loadView() {
        let content = MenuBarContentView(frame: NSRect(x: 0, y: 0, width: MenuTokens.panelWidth, height: MenuTokens.panelHeight))
        content.appState = appState
        content.primaryActionsView.onOpenHome = { [weak self] in self?.openSettingsFromMenu(.home) }
        content.primaryActionsView.onStartDictation = { [weak self] in self?.startDictationFromMenu() }
        content.primaryActionsView.onStartMeeting = { [weak self] in self?.startMeetingFromMenu() }
        content.primaryActionsView.onPasteLastDictation = { [weak self] in self?.pasteLastDictationFromMenu() }
        content.primaryActionsView.onOpenRecentMeetings = { [weak self] in self?.openSettingsFromMenu(.home, actionID: "recent_meetings") }
        content.utilityActionsView.onOpenSettings = { [weak self] in self?.openSettingsFromMenu(.home) }
        content.utilityActionsView.onCheckForUpdates = { [weak self] in self?.performUpdateActionFromMenu() }
        content.utilityActionsView.onOpenConnectAgent = { [weak self] in self?.openSettingsFromMenu(.connectAgent) }
        content.utilityActionsView.onOpenSupport = { [weak self] in self?.openSettingsFromMenu(.support) }
        content.onUpdateAction = { [weak self] in self?.performUpdateActionFromMenu() }
        view = content
        contentView = content
        view.appearance = NSAppearance(named: .darkAqua)

        refresh()
        setupSubscriptions()
    }

    func refresh(
        menuVisibilityOverride: [MenuBarOptionalItem: Bool]? = nil,
        allowUpdateRefresh: Bool = true
    ) {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil

        guard let content = contentView else { return }

        appState.contextCapture.refreshShortcutStatus()

        let warmupStatus = appState.meetingSession.warmupStatus
        let modelState = FirstRunLocalModelState(appState.sttRouter.modelDownloadState)
        let dictationState = FirstRunExperience.dictationAction(for: modelState)
        let meetingState = FirstRunExperience.meetingAction(
            dictationReady: appState.sttRouter.isModelLoaded,
            meetingsStatus: warmupStatus.meetingsStatus,
            isRecording: appState.meetingSession.isRecording
        )
        let updatePresentation = menuUpdatePresentation(
            for: appState.sparkleUpdater.updateStatus,
            automaticDownloadsEnabled: appState.sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled
        )
        let updateActionEnabled = updateActionEnabled(for: appState.sparkleUpdater.updateStatus)
        let menuVisibility = menuVisibilityOverride ?? MenuBarVisibilityPreferences.snapshot()

        content.headerView.update(
            warmupStatus: warmupStatus,
            hotkeyError: appState.contextCapture.hotkeyError
        )

        content.primaryActionsView.update(
            dictationKey: appState.contextCapture.dictationShortcutDisplay,
            meetingKey: appState.contextCapture.meetingShortcutDisplay,
            dictationState: dictationState,
            meetingState: meetingState,
            pasteDetail: pasteDetail(for: latestDictation),
            pasteEnabled: latestDictation != nil,
            showStartDictation: menuVisibility[.startDictation] ?? true,
            showStartMeeting: menuVisibility[.startMeeting] ?? true,
            showPasteLastDictation: menuVisibility[.pasteLastDictation] ?? true,
            showRecentMeetings: menuVisibility[.recentMeetings] ?? true
        )

        content.updateProminentUpdate(
            symbolName: updatePresentation.symbolName,
            title: updatePresentation.title,
            detail: updatePresentation.detail,
            trailingText: updatePresentation.trailingText,
            tone: updatePresentation.tone,
            isVisible: updatePresentation.isProminent,
            isEnabled: updateActionEnabled
        )

        content.utilityActionsView.pasteAvailable = latestDictationLoaded ? (latestDictation != nil) : nil
        content.utilityActionsView.update(
            updateTitle: updatePresentation.title,
            updateDetail: updatePresentation.detail,
            updateVersion: updatePresentation.trailingText,
            updateTone: updatePresentation.tone,
            updateEnabled: updateActionEnabled,
            showUpdateRow: !updatePresentation.isProminent
        )

        if allowUpdateRefresh, case .unknown = appState.sparkleUpdater.updateStatus.state {
            appState.sparkleUpdater.refreshUpdateStatus()
        }

        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        preferredContentSize = content.preferredPanelSize
        refreshLatestDictationIfNeeded()
    }

    func launchUISmokeReport(
        statusItemExists: Bool,
        popoverConfigured: Bool,
        onboardingCompleted: Bool,
        menuVisibilityOverride: [MenuBarOptionalItem: Bool]
    ) -> MenuBarLaunchUISmokeReport {
        loadViewIfNeeded()
        refresh(menuVisibilityOverride: menuVisibilityOverride, allowUpdateRefresh: false)
        return MenuBarLaunchUISmokeReport(
            appLaunched: true,
            statusItemExists: statusItemExists,
            popoverConfigured: popoverConfigured,
            onboardingCompleted: onboardingCompleted,
            content: contentView?.smokeSnapshot ?? MenuBarContentSmokeSnapshot(
                header: MenuBarHeaderSmokeSnapshot(
                    statusText: "",
                    detailText: "",
                    warningText: "",
                    isReady: false
                ),
                primaryActions: [:],
                utilityActions: [:]
            )
        )
    }

    private func setupSubscriptions() {
        appState.meetingSession.$warmupStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &subscriptions)

        appState.meetingSession.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &subscriptions)

        appState.sttRouter.$modelDownloadState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &subscriptions)

        appState.contextCapture.$dictationShortcutDisplay
            .combineLatest(appState.contextCapture.$meetingShortcutDisplay)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.scheduleRefresh()
            }
            .store(in: &subscriptions)

        appState.contextCapture.$hotkeyError
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &subscriptions)

        appState.sparkleUpdater.$updateStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: .menuBarVisibilityPreferencesDidChange)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &subscriptions)

        NotificationCenter.default.publisher(for: .dictationTranscriptDidSave)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.latestDictationLoaded = false
                self?.refresh()
            }
            .store(in: &subscriptions)

    }

    private func scheduleRefresh() {
        guard scheduledRefreshTask == nil else { return }
        scheduledRefreshTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, !Task.isCancelled else { return }
            self.scheduledRefreshTask = nil
            self.refresh()
        }
    }

    func prepareForClose() {
        textPaster.cancelPendingClipboardRestore()
        contentView?.utilityActionsView.dismissTransientUI()
        contentView?.scrollToTop()
    }

    private func startDictationFromMenu() {
        guard let session = appState.contextCapture.sessionController else { return }
        trackMenuAction("start_dictation")
        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        session.startDictation(sourceApp: sourceApp, trigger: .menu)
    }

    private func startMeetingFromMenu() {
        let isRecording = appState.meetingSession.isRecording
        trackMenuAction(isRecording ? "stop_meeting" : "start_meeting")
        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        Task { [meetingSession = appState.meetingSession] in
            if isRecording {
                await meetingSession.stopRecording(reason: .menuBarStopButton)
            } else {
                await meetingSession.startRecording(trigger: .menu)
            }
        }
    }

    private func pasteLastDictationFromMenu() {
        trackMenuAction("paste_last_dictation")
        guard let latestText = DictationTranscriptStore.latestSavedText() else {
            PasteLastDictationFeedbackPresenter.shared.present(.noSavedDictation)
            return
        }

        let sourceApp = resolvedSourceApp()
        let pasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)
        dismissPopover()
        sourceApp?.activate(options: [])
        let outcome = textPaster.paste(latestText, target: pasteTarget)
        PasteLastDictationFeedbackPresenter.shared.present(.presentation(for: outcome))
    }

    private func openSettingsFromMenu(_ page: TranscriptedSettingsPage, actionID: String? = nil) {
        trackMenuAction(actionID ?? (page == .home ? "home" : "open_\(page.analyticsValue)"))
        dismissPopover()
        openSettingsWindow(page)
    }

    private func performUpdateActionFromMenu() {
        guard updateActionEnabled(for: appState.sparkleUpdater.updateStatus) else {
            NSSound.beep()
            return
        }
        trackMenuAction(menuUpdateActionID(for: appState.sparkleUpdater.updateStatus.state))
        dismissPopover()
        appState.sparkleUpdater.performUserUpdateAction(surface: "menu_bar")
    }

    private func trackMenuAction(_ actionID: String) {
        AnalyticsReporter.track(
            "menu_bar_action_clicked",
            properties: [
                "action_id": actionID,
                "dictation_ready": appState.sttRouter.isModelLoaded ? "true" : "false",
                "meeting_recording_ready": TranscriptedPermissionAccess.isGranted(.systemAudioRecording) ? "true" : "false",
                "paste_available": latestDictation == nil ? "false" : "true",
            ]
        )
    }

    private func refreshLatestDictationIfNeeded() {
        guard !latestDictationLoaded else { return }
        latestDictationTask?.cancel()
        latestDictationTask = Task { @MainActor [weak self] in
            let latest = await Task.detached(priority: .utility) {
                DictationTranscriptStore.latestSavedDictation()
            }.value
            guard let self, !Task.isCancelled else { return }
            self.latestDictation = latest
            self.latestDictationLoaded = true
            self.refresh()
        }
    }

    private func resolvedSourceApp() -> NSRunningApplication? {
        let app = preferredSourceAppProvider()
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    private func menuUpdatePresentation(
        for status: SparkleUpdaterController.UpdateStatus,
        automaticDownloadsEnabled: Bool
    ) -> (
        symbolName: String,
        title: String,
        detail: String,
        trailingText: String?,
        tone: MenuBarActionRowView.Tone,
        isProminent: Bool
    ) {
        switch status.state {
        case .unknown, .readyToCheck:
            return (
                "arrow.triangle.2.circlepath.circle",
                "Check for Updates",
                "",
                nil,
                .standard,
                false
            )
        case .checking:
            return (
                "arrow.triangle.2.circlepath.circle",
                "Checking for Updates…",
                "",
                nil,
                .standard,
                false
            )
        case .noUpdateAvailable:
            return (
                "arrow.triangle.2.circlepath.circle",
                "Check for Updates",
                "",
                nil,
                .standard,
                false
            )
        case .updateAvailable(let version):
            if automaticDownloadsEnabled {
                return (
                    "arrow.down.circle",
                    "Preparing Update",
                    "Transcripted will ask you to restart when \(version) is ready",
                    nil,
                    .standard,
                    false
                )
            }

            return (
                "arrow.down.circle.fill",
                "Update available: \(version)",
                "A new version is ready to install",
                "Install",
                .warning,
                true
            )
        case .downloading(let version):
            return (
                "arrow.down.circle",
                "Preparing Update",
                "Transcripted will ask you to restart when \(version) is ready",
                nil,
                .standard,
                false
            )
        case .readyToInstall(let version):
            return (
                "arrow.clockwise.circle.fill",
                "Restart to Update",
                "Version \(version) downloaded",
                "Restart",
                .warning,
                true
            )
        }
    }

    private func menuUpdateActionID(for state: SparkleUpdaterController.UpdateStatus.State) -> String {
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

    private var isCaptureActiveForUpdateSafety: Bool {
        appState.meetingSession.isRecording
            || appState.meetingSession.hasRuntimeDiagnosticsWork
            || appState.meetingSession.isSpeakerReviewPending
            || appState.sttRouter.isRecording
            || appState.sttRouter.isTranscribing
    }

    private func updateActionEnabled(for status: SparkleUpdaterController.UpdateStatus) -> Bool {
        UpdateActionSafetyPolicy.canRunUserAction(
            state: updateActionSafetyState(for: status.state),
            sparkleCanRunUserAction: status.canRunUserUpdateAction,
            automaticDownloadsEnabled: appState.sparkleUpdater.automaticUpdateSettings.automaticDownloadsEnabled,
            isCaptureActive: isCaptureActiveForUpdateSafety
        )
    }

    private func updateActionSafetyState(
        for state: SparkleUpdaterController.UpdateStatus.State
    ) -> UpdateActionSafetyState {
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

    private func pasteDetail(for entry: SavedDictationEntry?) -> String {
        guard let entry else {
            return "No saved dictation yet."
        }

        let collapsed = entry.text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""

        guard !collapsed.isEmpty else {
            return "Paste the newest saved dictation."
        }

        return shortenedPreview(for: collapsed, limit: 40)
    }

    private func shortenedPreview(for text: String, limit: Int) -> String {
        let normalized = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        guard normalized.count > limit else {
            return normalized
        }
        let truncated = normalized.prefix(max(0, limit - 1)).trimmingCharacters(in: .whitespaces)
        return "\(truncated)…"
    }
}
