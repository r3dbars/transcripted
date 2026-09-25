// MenuBarPanelController.swift
// NSViewController that hosts the menubar popover and wires actions/subscriptions.

import AppKit
import Combine
import TranscriptedCore

struct MenuBarLaunchUISmokeReport: Codable, Equatable {
    let appLaunched: Bool
    let statusItemExists: Bool
    let popoverConfigured: Bool
    let onboardingCompleted: Bool
    let content: MenuBarContentSmokeSnapshot
    /// Wall-clock from kernel process-start to the moment the menu-bar UI is
    /// interactive (status item + popover configured). Powers the CI
    /// launch-to-interactive perf budget (PRD WS4.2). Optional so older report
    /// consumers and hand-built fixtures stay decodable.
    var launchToInteractiveMs: Double?
}

@MainActor
final class MenuBarPanelController: NSViewController {
    private let appState: TranscriptedAppState
    private let dismissPopover: () -> Void
    private let openSettingsWindow: (TranscriptedSettingsPage) -> Void
    private let preferredSourceAppProvider: () -> NSRunningApplication?

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
        content.primaryActionsView.onStartDictation = { [weak self] in self?.startDictationFromMenu() }
        content.primaryActionsView.onStartMeeting = { [weak self] in self?.startMeetingFromMenu() }
        content.headerView.onWarningAction = { [weak self] action in self?.handleShortcutWarningAction(action) }
        // Opens on Today; keeps the "home" action id so the menu_action series stays continuous.
        content.utilityActionsView.onOpenTranscripted = { [weak self] in self?.openSettingsFromMenu(.today, actionID: "home") }
        content.utilityActionsView.onCheckForUpdates = { [weak self] in self?.performUpdateActionFromMenu() }
        content.onUpdateAction = { [weak self] in self?.performUpdateActionFromMenu() }
        view = content
        contentView = content

        refresh()
        setupSubscriptions()
    }

    func refresh(allowUpdateRefresh: Bool = true) {
        scheduledRefreshTask?.cancel()
        scheduledRefreshTask = nil

        guard let content = contentView else { return }

        appState.contextCapture.refreshShortcutStatus()

        let warmupStatus = appState.meetingSession.warmupStatus
        let isMeetingRecording = appState.meetingSession.isCaptureSessionActive
        let capturePhase = MenuBarMeetingCapturePhase.resolve(appState.meetingSession.state)
        let modelState = appState.sttRouter.modelDownloadState
        let dictationState = FirstRunExperience.dictationAction(
            for: modelState,
            isDictating: appState.sttRouter.isRecording
        )
        let meetingState = FirstRunExperience.meetingAction(
            dictationReady: appState.sttRouter.isModelLoaded,
            meetingsStatus: warmupStatus.meetingsStatus,
            isRecording: isMeetingRecording,
            isSaving: capturePhase == .saving
        )
        let updatePresentation = menuUpdatePresentation(
            for: appState.sparkleUpdater.updateStatus,
            availableUpdateDownloadsAutomatically: appState.sparkleUpdater.availableUpdateDownloadsAutomatically
        )
        let updateActionEnabled = updateActionEnabled(for: appState.sparkleUpdater.updateStatus)
        let updateDetail = updateRowDetail(
            for: appState.sparkleUpdater.updateStatus,
            presentationDetail: updatePresentation.detail
        )

        content.headerView.update(
            warmupStatus: warmupStatus,
            // Shown even with dictation shortcuts off: the meeting and
            // paste shortcuts need the same event tap.
            shortcutWarning: shortcutWarningPresentation(),
            isMeetingRecording: isMeetingRecording,
            transcribingStatus: meetingTranscribingStatus(),
            capturePhase: capturePhase
        )

        // While a meeting records, the button's trailing slot shows the live
        // elapsed timer instead of the start shortcut.
        content.primaryActionsView.update(
            dictationTrailing: appState.contextCapture.dictationShortcutDisplay,
            meetingTrailing: isMeetingRecording
                ? MeetingDurationFormatter.formatDuration(appState.meetingSession.recordingDuration)
                : appState.contextCapture.meetingShortcutDisplay,
            dictationState: dictationState,
            meetingState: meetingState,
            isMeetingRecording: isMeetingRecording
        )

        content.updateProminentUpdate(
            symbolName: updatePresentation.symbolName,
            title: updatePresentation.title,
            detail: updateDetail,
            trailingText: updatePresentation.trailingText,
            tone: updatePresentation.tone,
            isVisible: updatePresentation.isProminent,
            isEnabled: updateActionEnabled
        )

        content.utilityActionsView.pasteAvailable = latestDictationLoaded ? (latestDictation != nil) : nil
        content.utilityActionsView.update(
            updateSymbolName: updatePresentation.symbolName,
            updateTitle: updatePresentation.title,
            updateDetail: updateDetail,
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
        launchToInteractiveMs: Double? = nil
    ) -> MenuBarLaunchUISmokeReport {
        loadViewIfNeeded()
        refresh(allowUpdateRefresh: false)
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
                updateCallout: MenuBarActionRowSmokeSnapshot(
                    title: "",
                    detail: "",
                    trailingText: "",
                    automationIdentifier: "",
                    isVisible: false,
                    isEnabled: false
                ),
                primaryActions: [:],
                utilityActions: [:]
            ),
            launchToInteractiveMs: launchToInteractiveMs
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

        // Keeps the meeting row's elapsed timer live while the popover is on
        // screen. Duration ticks arrive several times a second, so collapse
        // them to whole seconds and skip entirely when the popover is closed —
        // `refresh()` runs on every open, so the timer is current by the time
        // the user sees it.
        appState.meetingSession.$recordingDuration
            .map { Int($0) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isViewLoaded, self.view.window != nil else { return }
                self.scheduleRefresh()
            }
            .store(in: &subscriptions)

        appState.sttRouter.$modelDownloadState
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.scheduleRefresh()
            }
            .store(in: &subscriptions)

        // Keeps the header's "Transcribing 42%" current while the popover is
        // open. Progress moves often, so collapse it to whole percents and
        // skip when the popover is closed (refresh() runs on every open).
        appState.meetingSession.$displayStatus
            .map { MeetingPillFinishPresentation.percent(progress: $0.progress) }
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.isViewLoaded, self.view.window != nil else { return }
                self.scheduleRefresh()
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

        // The automatic-download setting changes whether an available update
        // reads as "Preparing Update" or "Install".
        appState.sparkleUpdater.$automaticUpdateSettings
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

    private func shortcutWarningPresentation() -> MenuBarShortcutWarningPresentation? {
        let systemAction = PhysicalDictationTriggerPreferences.functionKeySystemAction()
        return MenuBarShortcutWarningPresentation.resolve(
            hotkeyError: appState.contextCapture.hotkeyError,
            accessibilityErrorMessage: ContextCaptureEngine.accessibilityPermissionErrorMessage,
            functionKeyConflictWarning: PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                for: PhysicalDictationTriggerPreferences.pushToTalkBinding(),
                systemAction: systemAction
            ),
            functionKeySystemActionTitle: systemAction.title
        )
    }

    private func handleShortcutWarningAction(_ action: MenuBarShortcutWarningPresentation.Action) {
        trackMenuAction(action == .openAccessibilitySettings
            ? "shortcut_warning_open_accessibility"
            : "shortcut_warning_open_keyboard")
        dismissPopover()
        switch action {
        case .openAccessibilitySettings:
            TranscriptedPermissionAccess.openSettings(for: .accessibility)
        case .openKeyboardSettings:
            PhysicalDictationTriggerPreferences.openKeyboardSettings()
        }
    }

    /// "Transcribing 42%" while a meeting transcript is being made, else nil.
    private func meetingTranscribingStatus() -> String? {
        let session = appState.meetingSession
        guard case .transcribing = session.state else { return nil }
        // `menuStatus` shows no percent for the idle, saved and failed
        // values (0 or 1), so every status can pass straight through.
        return MeetingPillFinishPresentation.menuStatus(
            progress: session.displayStatus.progress,
            queuedCount: session.queuedTranscriptionCount
        )
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
        contentView?.scrollToTop()
    }

    private func startDictationFromMenu() {
        guard let session = appState.contextCapture.sessionController else { return }
        if appState.sttRouter.isRecording {
            trackMenuAction("stop_dictation")
            dismissPopover()
            session.stopDictationAndPaste(trigger: .menu)
            return
        }
        trackMenuAction("start_dictation")
        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        session.startDictation(sourceApp: sourceApp, trigger: .menu)
    }

    private func startMeetingFromMenu() {
        let meetingSession = appState.meetingSession
        let captureActive = meetingSession.isCaptureSessionActive
        trackMenuAction(captureActive ? "stop_meeting" : "start_meeting")
        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        Task { [meetingSession] in
            if meetingSession.isCaptureSessionActive {
                if case .startingRecording = meetingSession.state {
                    await meetingSession.stopRecordingJoiningPendingStart(reason: .menuBarStopButton)
                } else {
                    await meetingSession.stopRecording(reason: .menuBarStopButton)
                }
            } else {
                await meetingSession.startRecording(trigger: .menu)
            }
        }
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
        availableUpdateDownloadsAutomatically: Bool
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
            if availableUpdateDownloadsAutomatically {
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

    private var updateBlockedReason: UpdateBlockedReason? {
        UpdateBlockedReason.current(
            isRecording: appState.meetingSession.isRecording
                || appState.meetingSession.isCaptureSessionActive
                || appState.sttRouter.isRecording,
            isTranscribing: appState.meetingSession.hasRuntimeDiagnosticsWork || appState.sttRouter.isTranscribing,
            isSpeakerReviewPending: appState.meetingSession.isSpeakerReviewPending
        )
    }

    private var isCaptureActiveForUpdateSafety: Bool {
        updateBlockedReason != nil
    }

    /// The disabled row says what it's waiting on instead of just greying out.
    private func updateRowDetail(
        for status: SparkleUpdaterController.UpdateStatus,
        presentationDetail: String
    ) -> String {
        UpdateActionSafetyPolicy.blockedDetail(
            state: updateActionSafetyState(for: status.state),
            reason: updateBlockedReason
        ) ?? presentationDetail
    }

    private func updateActionEnabled(for status: SparkleUpdaterController.UpdateStatus) -> Bool {
        UpdateActionSafetyPolicy.canRunUserAction(
            state: updateActionSafetyState(for: status.state),
            sparkleCanRunUserAction: status.canRunUserUpdateAction,
            availableUpdateDownloadsAutomatically: appState.sparkleUpdater.availableUpdateDownloadsAutomatically,
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
}
