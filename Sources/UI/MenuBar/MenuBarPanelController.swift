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
    var meetingOverlayActionFailures: [String]?
    var meetingOverlayDurationUpdates: [Int]?
}

@MainActor
final class MenuBarPanelController: NSViewController {
    private let appState: TranscriptedAppState
    private let dismissPopover: () -> Void
    private let openSettingsWindow: (TranscriptedSettingsPage) -> Void
    private let preferredSourceAppProvider: () -> NSRunningApplication?

    private var contentView: MenuBarContentView?
    private var subscriptions = Set<AnyCancellable>()
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
        scheduledRefreshTask?.cancel()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        contentView?.menuWillAppear()
    }

    override func loadView() {
        let content = MenuBarContentView(frame: NSRect(x: 0, y: 0, width: MenuTokens.panelWidth, height: MenuTokens.panelHeight))
        content.appState = appState
        content.primaryActionsView.onStartDictation = { [weak self] in self?.startDictationFromMenu() }
        content.primaryActionsView.onStartMeeting = { [weak self] in self?.startMeetingFromMenu() }
        content.headerView.onWarningAction = { [weak self] action in self?.handleShortcutWarningAction(action) }
        // Opens on Meetings (`.home`); keeps the "home" action id so the menu_action series stays continuous.
        content.utilityActionsView.onOpenTranscripted = { [weak self] in self?.openSettingsFromMenu(.home, actionID: "home") }
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
        // While the update waits on a recording, drop the "Restart" button
        // label: the row can't be pressed yet, and its detail says why.
        let updateIsWaiting = !updateActionEnabled && updateDetail != updatePresentation.detail
        let updateTrailing = updateIsWaiting ? nil : updatePresentation.trailingText

        content.headerView.update(
            warmupStatus: warmupStatus,
            // Shown even with dictation shortcuts off: the meeting
            // shortcut needs the same event tap.
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
            trailingText: updateTrailing,
            tone: updatePresentation.tone,
            isVisible: updatePresentation.isProminent,
            isEnabled: updateActionEnabled
        )

        content.utilityActionsView.update(
            updateSymbolName: updatePresentation.symbolName,
            updateTitle: updatePresentation.title,
            updateDetail: updateDetail,
            updateVersion: updateTrailing,
            updateTone: updatePresentation.tone,
            updateEnabled: updateActionEnabled,
            showUpdateRow: updatePresentation.isVisible && !updatePresentation.isProminent
        )

        if allowUpdateRefresh, case .unknown = appState.sparkleUpdater.updateStatus.state {
            appState.sparkleUpdater.refreshUpdateStatus()
        }

        content.needsLayout = true
        content.layoutSubtreeIfNeeded()
        preferredContentSize = content.preferredPanelSize
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
                    displayTitle: "",
                    detail: "",
                    toolTip: "",
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
            .wholeSecondTicks()
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
            .combineLatest(appState.contextCapture.$secureKeyboardEntryNotice)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _ in
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

    }

    private func shortcutWarningPresentation() -> MenuBarShortcutWarningPresentation? {
        // Skip the Fn-key lookup when there is no hotkeyError: it syncs
        // system preferences on every popover refresh.
        var hotkeyWarning: MenuBarShortcutWarningPresentation?
        if let hotkeyError = appState.contextCapture.hotkeyError, !hotkeyError.isEmpty {
            hotkeyWarning = MenuBarShortcutWarningPresentation.resolve(
                hotkeyError: hotkeyError,
                accessibilityErrorMessage: ContextCaptureEngine.accessibilityPermissionErrorMessage,
                functionKeyConflictWarning: PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                    for: PhysicalDictationTriggerPreferences.pushToTalkBinding(),
                    systemAction: PhysicalDictationTriggerPreferences.functionKeySystemAction()
                )
            )
        }
        return MenuBarShortcutWarningPresentation.resolve(
            hotkeyWarning: hotkeyWarning,
            secureKeyboardEntryNotice: appState.contextCapture.secureKeyboardEntryNotice
        )
    }

    private func handleShortcutWarningAction(_ action: MenuBarShortcutWarningPresentation.Action) {
        trackMenuAction("shortcut_warning_open_accessibility")
        dismissPopover()
        switch action {
        case .openAccessibilitySettings:
            TranscriptedPermissionAccess.openSettings(for: .accessibility)
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
        trackMenuAction(MenuBarMeetingMenuAction.resolve(meetingSession.state).analyticsActionID)
        let sourceApp = resolvedSourceApp()
        dismissPopover()
        sourceApp?.activate(options: [])
        Task { [meetingSession] in
            switch MenuBarMeetingMenuAction.resolve(meetingSession.state) {
            case .stopJoiningPendingStart:
                await meetingSession.stopRecordingJoiningPendingStart(reason: .menuBarStopButton)
            case .stop:
                await meetingSession.stopRecording(reason: .menuBarStopButton)
            case .start:
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
            ]
        )
    }

    private func resolvedSourceApp() -> NSRunningApplication? {
        let app = preferredSourceAppProvider()
        guard app?.bundleIdentifier != Bundle.main.bundleIdentifier else { return nil }
        return app
    }

    /// The popover's update row. Nothing shows while there's nothing to do:
    /// the manual check lives in About (and the app menu). A download in
    /// progress is a quiet row; an update that needs a click is the filled
    /// callout. Words come from `UpdateStatusWords`.
    private func menuUpdatePresentation(
        for status: SparkleUpdaterController.UpdateStatus,
        availableUpdateDownloadsAutomatically: Bool
    ) -> (
        symbolName: String,
        title: String,
        detail: String,
        trailingText: String?,
        tone: MenuBarActionRowView.Tone,
        isProminent: Bool,
        isVisible: Bool
    ) {
        let phase = UpdateStatusWords.Phase(status.state)
        let auto = availableUpdateDownloadsAutomatically
        let title = UpdateStatusWords.title(for: phase, downloadsAutomatically: auto)
        let detail = UpdateStatusWords.detail(for: phase, downloadsAutomatically: auto) ?? ""
        let action = UpdateStatusWords.action(for: phase, downloadsAutomatically: auto)
        switch phase {
        case .idle, .checking:
            return ("arrow.triangle.2.circlepath.circle", title, detail, nil, .standard, false, false)
        case .available, .downloading:
            if action != nil {
                return ("arrow.down.circle.fill", title, detail, action, .standard, true, true)
            }
            return ("arrow.down.circle", title, detail, nil, .standard, false, true)
        case .readyToInstall:
            return ("arrow.clockwise.circle.fill", title, detail, action, .standard, true, true)
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
