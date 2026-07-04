// TranscriptedApp.swift
// Menubar app for local dictation + meeting transcription

import SwiftUI
import AppKit
import AVFoundation
import Carbon
import Combine
import Darwin
import TranscriptedCore
import UniformTypeIdentifiers

@main
struct TranscriptedApp: App {
    @NSApplicationDelegateAdaptor(TranscriptedAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
            .commands {
                TranscriptedMenuCommands(appDelegate: appDelegate)
            }
    }
}

// MARK: - App Delegate

@MainActor
class TranscriptedAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    private var lastExternalApplication: NSRunningApplication?
    private var hasPresentedInitialOnboarding = false
    private let statusItemUpdateBadge = NSView(frame: .zero)
    private var statusItemSubscriptions: Set<AnyCancellable> = []
    private var statusItemMeetingRecording = false
    private var statusItemDictationRecording = false
    private var statusItemUpdateVersion: String?
    private let settingsTextPaster = ClipboardRestoringTextPaster()
    private lazy var settingsActions = TranscriptedSettingsActions(
        startDictation: { [weak self] in self?.startDictationFromSettings() },
        startMeeting: { [weak self] in self?.startMeetingFromSettings() },
        importAudioFile: { [weak self] in self?.importAudioFileFromSettings() },
        pasteLastDictation: { [weak self] in self?.pasteLastDictationFromSettings() },
        openConnectAgent: { [weak self] in self?.showSettingsWindow(page: .connectAgent, source: "settings_action") },
        checkForUpdates: { [weak self] in self?.appState.sparkleUpdater.checkForUpdates() },
        sendFeedback: { [weak self] in
            guard let self else { return }
            TranscriptedSupportActions.sendFeedback(appState: self.appState)
        },
        copyDiagnostics: { [weak self] in
            guard let self else { return false }
            return TranscriptedSupportActions.copyDiagnostics(appState: self.appState)
        },
        sendDiagnosticEvent: { [weak self] in
            guard let self else { return nil }
            return TranscriptedSupportActions.sendDiagnosticEvent(appState: self.appState)
        }
    )
    private lazy var settingsWindowController = TranscriptedSettingsWindowController(
        appState: appState,
        actions: settingsActions
    )
    private lazy var onboardingWindowController = TranscriptedOnboardingWindowController(
        makeView: { [unowned self] in self.makeOnboardingView() },
        onPresent: { [weak self] entrypoint in
            self?.trackOnboardingShown(entrypoint: entrypoint)
        }
    )
    private lazy var menuPanelController = MenuBarPanelController(
        appState: appState,
        preferredSourceAppProvider: { [weak self] in self?.lastExternalApplication },
        openSettingsWindow: { [weak self] page in self?.showSettingsWindow(page: page, source: "menu_bar") },
        dismissPopover: { [weak self] in self?.closePopover() }
    )

    private let singleInstanceGuard = SingleInstanceGuard()
    private var singleInstanceReopenObserver: NSObjectProtocol?
    private var duplicateInstanceShouldTerminateImmediately = false

    let appState = TranscriptedAppState()
    let overlayController = FloatingOverlayController()
    let sessionController = DictationSessionController()
    /// Second non-activating panel for meeting mode (Lane C). Distinct from
    /// the dictation overlay so regressions to one can't break the other.
    @available(macOS 14.0, *)
    lazy var meetingOverlayController = MeetingOverlayController()
    @available(macOS 14.0, *)
    lazy var capturePillController = CapturePillController()
    @available(macOS 14.0, *)
    lazy var meetingPromptDetector = MeetingPromptDetector()
    @available(macOS 14.0, *)
    lazy var micActivityMonitor = MicActivityMonitor()
    @available(macOS 14.0, *)
    lazy var cameraActivityMonitor = CameraActivityMonitor()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var micPreferenceObserver: NSObjectProtocol?
    private var terminationCleanupStarted = false
    private var terminationCleanupFinished = false
    private var pendingTerminationReplyCount = 0

    /// Keeps NSApp in sync with the Dock visibility setting and promotes
    /// the app to `.regular` during active recording for force-quit
    /// recovery. Initialized in `applicationDidFinishLaunching` after
    /// AppKit is ready.
    private var activationPolicyController: ActivationPolicyController?
    private var activationPolicySubscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if DictationStopBenchmarkRunner.runFromEnvironmentIfRequested() {
            return
        }

        guard acquireSingleInstanceLock() else { return }

        // Crash reporting
        CrashReporter.setup()

        let activationController = ActivationPolicyController(
            actualPolicy: { NSApp.activationPolicy() }
        )
        activationPolicyController = activationController
        wireActivationPolicy(controller: activationController)
        DispatchQueue.main.async { [weak activationController] in
            activationController?.reapplyCurrentPolicy()
        }

        // Wire session controller
        sessionController.appState = appState
        sessionController.overlayController = overlayController
        appState.contextCapture.sessionController = sessionController

        // Set up the floating overlay panel (pure AppKit — no NSHostingView)
        overlayController.setup(sttRouter: appState.sttRouter)

        // Meeting overlay + hotkey + speaker naming — Lane C wiring.
        if #available(macOS 14.0, *) {
            let meetingSession = appState.meetingSession
            meetingSession.calendarSuggestedTitleProvider = { [weak self] in
                self?.meetingPromptDetector.currentSuggestedTranscriptTitle()
            }
            meetingPromptDetector.shouldSkipPromptEvaluation = { [weak self] in
                guard let self else { return false }
                return !MeetingPromptSessionPromptState(
                    self.appState.meetingSession.state
                ).allowsDetectedMeetingPrompt
            }
            meetingOverlayController.setup(meetingSession: meetingSession)
            let recordPrompt: (MeetingPromptDetector.Candidate) -> Void = { [weak self] candidate in
                guard let self else { return }
                AnalyticsReporter.track(
                    "meeting_prompt_record_selected",
                    properties: MeetingPromptTelemetry.properties(
                        for: candidate,
                        readiness: self.meetingPromptTelemetryReadiness(),
                        signals: self.meetingPromptDetector.currentSignalSnapshot()
                    )
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let started = await self.appState.meetingSession.startRecording(
                        trigger: .detectedPrompt,
                        suggestedTitle: candidate.suggestedTranscriptTitle
                    )
                    if started {
                        self.meetingPromptDetector.markAccepted(candidate: candidate)
                    }
                }
            }
            let dismissPrompt: (MeetingPromptDetector.Candidate) -> Void = { [weak self] candidate in
                guard let self else { return }
                let backoffDecision = self.meetingPromptDetector.dismiss(candidate: candidate)
                AnalyticsReporter.track(
                    "meeting_prompt_dismissed",
                    properties: MeetingPromptTelemetry.properties(
                        for: candidate,
                        readiness: self.meetingPromptTelemetryReadiness(),
                        backoffKind: backoffDecision.kind,
                        signals: self.meetingPromptDetector.currentSignalSnapshot(),
                        dismissStreak: self.meetingPromptDetector.dismissStreak(for: candidate.provider)
                    )
                )
                ActivationTelemetry.trackWorkflowAbandoned(
                    workflowKind: .meetingPrompt,
                    stage: "prompt_shown",
                    reasonKind: .dismissed,
                    surface: .meetingOverlay,
                    priorReadyState: MeetingPromptTelemetry.readyState(
                        readiness: self.meetingPromptTelemetryReadiness()
                    )
                )
            }
            meetingOverlayController.onPromptExpired = { [weak self] candidate in
                guard let self else { return }
                let backoffDecision = self.meetingPromptDetector.expire(candidate: candidate)
                AnalyticsReporter.track(
                    "meeting_prompt_dismissed",
                    properties: MeetingPromptTelemetry.properties(
                        for: candidate,
                        readiness: self.meetingPromptTelemetryReadiness(),
                        backoffKind: backoffDecision.kind,
                        signals: self.meetingPromptDetector.currentSignalSnapshot()
                    )
                )
                ActivationTelemetry.trackWorkflowAbandoned(
                    workflowKind: .meetingPrompt,
                    stage: "prompt_shown",
                    reasonKind: .expired,
                    surface: .meetingOverlay,
                    priorReadyState: MeetingPromptTelemetry.readyState(
                        readiness: self.meetingPromptTelemetryReadiness()
                    )
                )
            }
            meetingOverlayController.onPromptRecord = recordPrompt
            meetingOverlayController.onPromptDismiss = dismissPrompt
            meetingOverlayController.onPromptRemindSoon = { [weak self] candidate in
                guard let self else { return }
                let backoffDecision = self.meetingPromptDetector.remindSoon(candidate: candidate)
                AnalyticsReporter.track(
                    "meeting_prompt_dismissed",
                    properties: MeetingPromptTelemetry.properties(
                        for: candidate,
                        readiness: self.meetingPromptTelemetryReadiness(),
                        backoffKind: backoffDecision.kind,
                        signals: self.meetingPromptDetector.currentSignalSnapshot()
                    )
                )
                ActivationTelemetry.trackWorkflowAbandoned(
                    workflowKind: .meetingPrompt,
                    stage: "prompt_shown",
                    reasonKind: .remindedLater,
                    surface: .meetingOverlay,
                    priorReadyState: MeetingPromptTelemetry.readyState(
                        readiness: self.meetingPromptTelemetryReadiness()
                    )
                )
            }
            capturePillController.onRecord = recordPrompt
            capturePillController.onDismiss = dismissPrompt
            capturePillController.onRemind = meetingOverlayController.onPromptRemindSoon
            capturePillController.onExpired = meetingOverlayController.onPromptExpired
            meetingPromptDetector.onPromptSuppressed = { [weak self] suppression in
                guard let self else { return }
                AnalyticsReporter.track(
                    "meeting_prompt_suppressed",
                    properties: MeetingPromptTelemetry.properties(
                        for: suppression,
                        readiness: self.meetingPromptTelemetryReadiness(),
                        signals: self.meetingPromptDetector.currentSignalSnapshot()
                    )
                )
                ActivationTelemetry.trackWorkflowAbandoned(
                    workflowKind: .meetingPrompt,
                    stage: "pre_prompt",
                    reasonKind: .suppressed,
                    surface: .meetingOverlay,
                    priorReadyState: MeetingPromptTelemetry.readyState(
                        readiness: self.meetingPromptTelemetryReadiness()
                    )
                )
            }
            meetingPromptDetector.onPromptRequest = { [weak self] candidate in
                guard PermissionsOnboardingPreferences.hasCompleted() else { return false }
                guard let self else { return false }
                let timeout = MeetingPromptHeuristics.promptTimeoutSeconds(
                    for: candidate.reason,
                    calendarDefault: 30
                )
                let presented = self.capturePillController.present(candidate: candidate, timeout: TimeInterval(timeout))
                if presented {
                    AnalyticsReporter.track(
                        "meeting_prompt_shown",
                        properties: MeetingPromptTelemetry.properties(
                            for: candidate,
                            readiness: self.meetingPromptTelemetryReadiness(),
                            signals: self.meetingPromptDetector.currentSignalSnapshot()
                        )
                    )
                }
                return presented
            }
            // Capture-funnel denominator: one event per detected call at its
            // end, recorded or not, so capture rate is measured against calls
            // that actually happened instead of prompts that fired.
            meetingPromptDetector.onDetectedCallEnded = { summary in
                AnalyticsReporter.track(
                    "meeting_detected_call_ended",
                    properties: MeetingPromptTelemetry.properties(for: summary)
                )
            }
            // Post-call awareness nudge: a long detected call ended with no
            // recording (and no explicit decline). Policy gates live in the
            // detector; the preference gate and opt-out live here.
            meetingPromptDetector.onUnrecordedCallEnded = { [weak self] call in
                guard let self else { return }
                guard MissedCallNudgePreferences.isEnabled() else { return }
                let presented = self.meetingOverlayController.presentMissedCallNudge(call)
                if presented {
                    AnalyticsReporter.track(
                        "meeting_missed_call_nudge",
                        properties: [
                            "action": "shown",
                            "duration_bucket": MissedCallNudgePolicy.durationBucket(for: call.duration),
                            "provider": call.provider.rawValue,
                        ]
                    )
                }
            }
            meetingOverlayController.onMissedCallNudgeResolved = { outcome in
                if outcome == .disabled {
                    MissedCallNudgePreferences.setEnabled(false)
                }
                AnalyticsReporter.track(
                    "meeting_missed_call_nudge",
                    properties: ["action": outcome.rawValue]
                )
            }
            // Ad-hoc call detection: never prompt while we already hold the mic
            // (meeting recording or dictation), and feed mic-activity into the
            // same prompt pipeline. See docs/auto-call-detection-spec.md.
            meetingPromptDetector.isOwnCaptureActive = { [weak self] in
                guard let self else { return false }
                return self.appState.meetingSession.isRecording || self.appState.sttRouter.isRecording
            }
            meetingPromptDetector.ownCaptureActivity = { [weak self] in
                guard let self else { return .none }
                if self.appState.meetingSession.isRecording {
                    return .meetingRecording
                }
                if self.appState.sttRouter.isRecording {
                    return .dictation
                }
                return .none
            }
            meetingPromptDetector.isMicInputPromptEnabled = {
                AutoCallDetectionPreferences.isEnabled()
            }
            micActivityMonitor.onChange = { [weak self] micUsers in
                self?.meetingPromptDetector.updateMicInputUsers(micUsers)
            }
            // Native-app audio output is the listen-only call signal (remote
            // people talking, nothing holding the mic here). Same prompt pipe;
            // the detector de-dupes it against the mic and camera signals.
            micActivityMonitor.onOutputChange = { [weak self] outputUsers in
                self?.meetingPromptDetector.updateAudioOutputUsers(outputUsers)
            }
            // Camera-on is a second, complementary call sensor (e.g. a camera-on,
            // mic-muted Meet join). It feeds the same prompt; the detector de-dupes
            // it against the mic signal so a normal video call prompts once.
            cameraActivityMonitor.onChange = { [weak self] cameraInUse in
                self?.meetingPromptDetector.updateCameraInUse(cameraInUse)
            }
            meetingPromptDetector.start()
            applyAutoCallDetectionPreference()
            observeAutoCallDetectionPreference()
            appState.contextCapture.onMeetingToggle = { [weak self] in
                self?.meetingOverlayController.toggleFromHotkey()
            }
            appState.contextCapture.onPasteLastDictation = { [weak self] in
                self?.pasteLastDictationFromSettings()
            }
            SpeakerNamingSheet.shared.observe(taskManager: meetingSession.taskManager)
        }

        // Set up menubar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            configureStatusItemButton(button)
        }
        bindStatusItemUpdateBadge()
        bindStatusItemRecordingIndicator()
        installSettingsMenuHandler()

        // Set up popover (pure AppKit — no NSHostingController, no AttributeGraph)
        let pop = NSPopover()
        pop.contentSize = NSSize(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        pop.behavior = .transient
        pop.delegate = self
        popover = pop

        writeLaunchUISmokeReportIfRequested()

        // Engine recovery on wake — hotkeys and overlay state
        let wakeRecoveryObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.appState.handleSystemWake()
                self.overlayController.handleSystemWake()
            }
        }
        workspaceObservers.append(wakeRecoveryObserver)

        presentInitialOnboardingIfNeeded()

        // Initialize engines
        Task { @MainActor in
            await appState.initialize()
            appState.contextCapture.registerHotkey()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            // Let AppKit do its default handling (bring an existing
            // window to the front).
            return true
        }

        if !PermissionsOnboardingPreferences.hasCompleted() {
            _ = resolvedSourceApp()
            onboardingWindowController.present(entrypoint: "dock_icon")
            return false
        }

        showSettingsWindow(page: .home, source: "dock_icon")
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        if duplicateInstanceShouldTerminateImmediately {
            return
        }

        if onboardingWindowController.isVisible {
            NotificationCenter.default.post(name: .transcriptedOnboardingWillTerminate, object: nil)
        }

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = singleInstanceReopenObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            singleInstanceReopenObserver = nil
        }
        if let observer = micPreferenceObserver {
            NotificationCenter.default.removeObserver(observer)
            micPreferenceObserver = nil
        }
        if #available(macOS 14.0, *) {
            meetingPromptDetector.stop()
            micActivityMonitor.stop()
            cameraActivityMonitor.stop()
        }
        appState.shutdown()
        singleInstanceGuard.release()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if duplicateInstanceShouldTerminateImmediately {
            return .terminateNow
        }

        if terminationCleanupFinished {
            return .terminateNow
        }
        guard !terminationCleanupStarted else {
            pendingTerminationReplyCount += 1
            return .terminateLater
        }
        switch activeMeetingTerminationDecision() {
        case .keepRecording:
            return .terminateCancel
        case .stopAndTranscribe:
            Task { @MainActor [weak self] in
                await self?.appState.meetingSession.stopRecording(reason: .quitConfirmation)
            }
            return .terminateCancel
        case .saveAudioAndQuit:
            break
        }

        terminationCleanupStarted = true
        pendingTerminationReplyCount = 1

        Task { @MainActor [weak self, sender] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            await self.sessionController.finishDictationForTermination()
            if #available(macOS 14.0, *) {
                await self.appState.meetingSession.prepareForTermination()
            }
            self.appState.shutdown()
            await EventReporter.shared.flushLocalEventsForShutdown()
            self.terminationCleanupFinished = true
            self.replyToPendingTerminationRequests(sender, shouldTerminate: true)
        }

        return .terminateLater
    }

    private func replyToPendingTerminationRequests(_ sender: NSApplication, shouldTerminate: Bool) {
        let replyCount = max(pendingTerminationReplyCount, 1)
        pendingTerminationReplyCount = 0

        for _ in 0..<replyCount {
            sender.reply(toApplicationShouldTerminate: shouldTerminate)
        }
    }

    private func activeMeetingTerminationDecision() -> ActiveMeetingQuitDecision {
        guard #available(macOS 14.0, *) else { return .saveAudioAndQuit }
        guard ActiveMeetingQuitConfirmationPolicy.shouldConfirmQuit(
            preferenceEnabled: QuitConfirmationPreferences.confirmQuitDuringActiveMeetingRecording(),
            activeMeetingCapture: appState.meetingSession.shouldConfirmQuitForActiveCapture
        ) else {
            return .saveAudioAndQuit
        }

        return confirmQuitDuringActiveMeeting()
    }

    private func confirmQuitDuringActiveMeeting() -> ActiveMeetingQuitDecision {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)

        let presentation = ActiveMeetingQuitConfirmationPolicy.presentation
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = presentation.title
        alert.informativeText = presentation.message
        alert.addButton(withTitle: presentation.keepRecordingTitle)
        alert.addButton(withTitle: presentation.stopAndTranscribeTitle)
        alert.addButton(withTitle: presentation.saveAudioAndQuitTitle)
        alert.buttons.first?.keyEquivalent = "\r"
        alert.buttons.last?.keyEquivalent = ""

        switch alert.runModal() {
        case .alertSecondButtonReturn:
            return .stopAndTranscribe
        case .alertThirdButtonReturn:
            return .saveAudioAndQuit
        default:
            return .keepRecording
        }
    }

    private func acquireSingleInstanceLock() -> Bool {
        switch singleInstanceGuard.acquire() {
        case .acquired:
            installSingleInstanceReopenHandler()
            return true
        case .alreadyRunning:
            duplicateInstanceShouldTerminateImmediately = true
            SingleInstanceGuard.requestExistingInstanceToPresent()
            SingleInstanceGuard.activateExistingInstance()
            NSApp.terminate(nil)
            return false
        }
    }

    private func installSingleInstanceReopenHandler() {
        guard singleInstanceReopenObserver == nil else { return }

        singleInstanceReopenObserver = DistributedNotificationCenter.default().addObserver(
            forName: SingleInstanceGuard.reopenNotificationName,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleSingleInstanceReopenRequest()
            }
        }
    }

    private func handleSingleInstanceReopenRequest() {
        closePopover()
        NSApp.activate(ignoringOtherApps: true)

        if !PermissionsOnboardingPreferences.hasCompleted() {
            // Mid-onboarding there's no menu-bar home to fall back to yet, so put
            // the user straight back where they left off.
            onboardingWindowController.present(entrypoint: "single_instance_reopen")
            return
        }

        // A second launch of a menu-bar app is easy to misread as "nothing
        // happened". Say plainly that it's already running and offer to open it
        // rather than silently surfacing a Settings window.
        presentAlreadyRunningNotice()
    }

    private func presentAlreadyRunningNotice() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = SingleInstanceGuard.HandoffNotice.alreadyRunningTitle
        alert.informativeText = SingleInstanceGuard.HandoffNotice.alreadyRunningMessage
        alert.addButton(withTitle: SingleInstanceGuard.HandoffNotice.openButtonTitle)
        alert.addButton(withTitle: SingleInstanceGuard.HandoffNotice.dismissButtonTitle)

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        NSApp.activate(ignoringOtherApps: true)
        if let button = statusItem?.button, let popover = popover {
            showMainPopover(relativeTo: button, popover: popover, entrypoint: "single_instance_reopen")
        } else {
            showSettingsWindow(page: .home, source: "single_instance_reopen")
        }
    }

    @objc func togglePopover() {
        if !PermissionsOnboardingPreferences.hasCompleted() {
            _ = resolvedSourceApp()
            onboardingWindowController.present(entrypoint: "status_item")
            return
        }

        if statusItemClickWantsQuickMenu(NSApp.currentEvent) {
            showStatusItemQuickMenu()
            return
        }

        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            showMainPopover(relativeTo: button, popover: popover)
        }
    }

    /// Right-click (or control-click) on the status item opens the lean quick
    /// menu; a plain left-click keeps opening the popover.
    private func statusItemClickWantsQuickMenu(_ event: NSEvent?) -> Bool {
        guard let event else { return false }
        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            return true
        case .leftMouseUp, .leftMouseDown:
            return event.modifierFlags.contains(.control)
        default:
            return false
        }
    }

    private func showStatusItemQuickMenu() {
        guard let statusItem else { return }

        let menu = NSMenu()

        let dictationItem = NSMenuItem(
            title: appState.sttRouter.isRecording ? "Stop Dictation" : "Start Dictation",
            action: #selector(quickMenuToggleDictation),
            keyEquivalent: ""
        )
        dictationItem.target = self
        menu.addItem(dictationItem)

        let meetingItem = NSMenuItem(
            title: appState.meetingSession.isRecording ? "Stop Meeting Recording" : "Start Meeting Recording",
            action: #selector(quickMenuToggleMeeting),
            keyEquivalent: ""
        )
        meetingItem.target = self
        menu.addItem(meetingItem)

        menu.addItem(.separator())

        let homeItem = NSMenuItem(
            title: "Open Home",
            action: #selector(quickMenuOpenHome),
            keyEquivalent: ""
        )
        homeItem.target = self
        menu.addItem(homeItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Transcripted",
            action: #selector(quickMenuQuit),
            keyEquivalent: ""
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Standard status-item trick: attach the menu only for this click so
        // the plain left-click action keeps opening the popover. Menu tracking
        // runs synchronously inside performClick.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func quickMenuToggleDictation() {
        let isRecording = appState.sttRouter.isRecording
        trackQuickMenuAction(isRecording ? "quick_menu_stop_dictation" : "quick_menu_start_dictation")
        if isRecording {
            sessionController.stopDictationAndPaste(trigger: .menu)
        } else {
            startDictationFromSettings()
        }
    }

    @objc private func quickMenuToggleMeeting() {
        trackQuickMenuAction(
            appState.meetingSession.isRecording ? "quick_menu_stop_meeting" : "quick_menu_start_meeting"
        )
        menuToggleMeetingRecording()
    }

    @objc private func quickMenuOpenHome() {
        trackQuickMenuAction("quick_menu_home")
        showSettingsWindow(page: .home, source: "quick_menu")
    }

    @objc private func quickMenuQuit() {
        trackQuickMenuAction("quick_menu_quit")
        NSApplication.shared.terminate(nil)
    }

    private func trackQuickMenuAction(_ actionID: String) {
        AnalyticsReporter.track(
            "menu_bar_action_clicked",
            properties: [
                "action_id": actionID,
                "dictation_ready": appState.sttRouter.isModelLoaded ? "true" : "false",
                "meeting_recording_ready": TranscriptedPermissionAccess.isGranted(.systemAudioRecording) ? "true" : "false",
                "paste_available": "unknown",
            ]
        )
    }

    @objc private func openSettingsFromAppMenu(_ sender: Any?) {
        closePopover()
        showSettingsWindow(source: "app_menu")
    }

    private func configureStatusItemButton(_ button: NSStatusBarButton) {
        let image = NSImage(systemSymbolName: "mic.and.signal.meter", accessibilityDescription: "Transcripted")
        image?.isTemplate = true
        button.image = image
        button.imagePosition = .imageOnly
        button.toolTip = "Transcripted"
        button.identifier = NSUserInterfaceItemIdentifier("transcripted.status-item.button")
        button.setAccessibilityIdentifier("transcripted.status-item.button")
        button.setAccessibilityLabel("Transcripted")
        button.action = #selector(togglePopover)
        button.target = self
        // Right clicks must reach the action so togglePopover can route them
        // to the quick menu; buttons only send left-ups by default.
        _ = button.sendAction(on: [.leftMouseUp, .rightMouseUp])

        installStatusItemUpdateBadge(on: button)
    }

    private func installStatusItemUpdateBadge(on button: NSStatusBarButton) {
        guard statusItemUpdateBadge.superview !== button else { return }

        statusItemUpdateBadge.translatesAutoresizingMaskIntoConstraints = false
        statusItemUpdateBadge.wantsLayer = true
        statusItemUpdateBadge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusItemUpdateBadge.layer?.cornerRadius = 3.5
        statusItemUpdateBadge.layer?.masksToBounds = true
        statusItemUpdateBadge.isHidden = true

        button.addSubview(statusItemUpdateBadge)
        NSLayoutConstraint.activate([
            statusItemUpdateBadge.widthAnchor.constraint(equalToConstant: 7),
            statusItemUpdateBadge.heightAnchor.constraint(equalToConstant: 7),
            statusItemUpdateBadge.trailingAnchor.constraint(equalTo: button.trailingAnchor, constant: -2),
            statusItemUpdateBadge.topAnchor.constraint(equalTo: button.topAnchor, constant: 3),
        ])
    }

    private func writeLaunchUISmokeReportIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let reportPath = environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_REPORT"],
              !reportPath.isEmpty else {
            return
        }
        defer {
            scheduleLaunchUISmokeTerminationIfRequested(environment: environment)
        }

        let smokeMenuVisibility = Dictionary(uniqueKeysWithValues: MenuBarOptionalItem.allCases.map { ($0, true) })
        let report = menuPanelController.launchUISmokeReport(
            statusItemExists: statusItem != nil,
            popoverConfigured: popover != nil,
            onboardingCompleted: true,
            menuVisibilityOverride: smokeMenuVisibility
        )
        let reportURL = URL(fileURLWithPath: reportPath, isDirectory: false)

        do {
            try FileManager.default.createDirectory(
                at: reportURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        } catch {
            NSLog("Failed to write launch UI smoke report: \(error.localizedDescription)")
        }
    }

    private func scheduleLaunchUISmokeTerminationIfRequested(environment: [String: String]) {
        guard environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_AFTER_REPORT"] == "1" else { return }

        let delay = environment["TRANSCRIPTED_LAUNCH_UI_SMOKE_TERMINATE_DELAY_SECONDS"]
            .flatMap(Double.init)
            .map { max(0, $0) } ?? 5

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            Darwin.exit(0)
        }
    }

    private func bindStatusItemUpdateBadge() {
        appState.sparkleUpdater.$updateStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateStatusItemBadge(for: status)
            }
            .store(in: &statusItemSubscriptions)
        updateStatusItemBadge(for: appState.sparkleUpdater.updateStatus)
    }

    /// Keeps the status-item glyph in sync with active capture so the menu bar
    /// itself answers "am I recording?" without opening the popover.
    private func bindStatusItemRecordingIndicator() {
        appState.sttRouter.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self, self.statusItemDictationRecording != isRecording else { return }
                self.statusItemDictationRecording = isRecording
                self.refreshStatusItemPresentation()
            }
            .store(in: &statusItemSubscriptions)

        if #available(macOS 14.0, *) {
            appState.meetingSession.$isRecording
                .receive(on: DispatchQueue.main)
                .sink { [weak self] isRecording in
                    guard let self, self.statusItemMeetingRecording != isRecording else { return }
                    self.statusItemMeetingRecording = isRecording
                    self.refreshStatusItemPresentation()
                }
                .store(in: &statusItemSubscriptions)
        }
    }

    private func updateStatusItemBadge(for status: SparkleUpdaterController.UpdateStatus) {
        let updateVersion = status.readyToInstallVersion
        statusItemUpdateBadge.isHidden = updateVersion == nil
        statusItemUpdateVersion = updateVersion
        refreshStatusItemPresentation()
    }

    /// Single writer for the status-item button's image, tint, tooltip, and
    /// accessibility label so the recording indicator and the update badge
    /// cannot fight over shared button state.
    private func refreshStatusItemPresentation() {
        guard let button = statusItem?.button else { return }

        let symbolName: String
        let tint: NSColor?
        let label: String
        if statusItemMeetingRecording {
            symbolName = "record.circle"
            tint = .systemRed
            label = "Transcripted — recording meeting"
        } else if statusItemDictationRecording {
            symbolName = "mic.fill"
            tint = .systemRed
            label = "Transcripted — dictating"
        } else {
            symbolName = "mic.and.signal.meter"
            tint = nil
            label = "Transcripted"
        }

        if let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: label) {
            image.isTemplate = true
            button.image = image
        }
        button.contentTintColor = tint
        button.setAccessibilityLabel(label)

        if let statusItemUpdateVersion {
            button.toolTip = "\(label) - restart to update to \(statusItemUpdateVersion)"
        } else {
            button.toolTip = label
        }
    }

    private func installSettingsMenuHandler() {
        guard let appMenu = NSApp.mainMenu?.item(withTitle: "Transcripted")?.submenu,
              let settingsItem = appMenu.items.first(where: { $0.title.hasPrefix("Settings") }) else {
            return
        }

        settingsItem.target = self
        settingsItem.action = #selector(openSettingsFromAppMenu(_:))
    }

    private func closePopover() {
        menuPanelController.prepareForClose()
        popover?.performClose(nil)
        if popover?.contentViewController !== menuPanelController {
            popover?.contentViewController = nil
        }
    }

    private func showSettingsWindow(
        page: TranscriptedSettingsPage = .home,
        source: String = "unknown"
    ) {
        settingsWindowController.present(page: page, source: source)
    }

    private func makeOnboardingView() -> PermissionsOnboardingView {
        PermissionsOnboardingView { [weak self] in
            self?.finishOnboarding()
        }
    }

    private func presentInitialOnboardingIfNeeded() {
        guard !PermissionsOnboardingPreferences.hasCompleted(), !hasPresentedInitialOnboarding else { return }
        hasPresentedInitialOnboarding = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.onboardingWindowController.isVisible, !PermissionsOnboardingPreferences.hasCompleted() else { return }
            self.onboardingWindowController.present(entrypoint: "initial_launch")
        }
    }

    private func finishOnboarding() {
        PermissionsOnboardingPreferences.markCompleted()
        // Meeting detection only works while the app runs; register the login
        // item by default now that onboarding gives the macOS notice context.
        // One-time, and an explicit Settings choice always wins.
        try? LaunchAtLoginController.applyDefaultEnableIfNeeded(onboardingCompleted: true)
        appState.recoverHotkeysAfterPermissionChange()
        onboardingWindowController.dismiss()
        closePopover()

        guard let button = statusItem?.button, let popover = popover else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.showMainPopover(relativeTo: button, popover: popover, entrypoint: "onboarding_completed")
        }
    }

    private func showMainPopover(
        relativeTo button: NSStatusBarButton,
        popover: NSPopover,
        entrypoint: String = "status_item"
    ) {
        _ = resolvedSourceApp()
        menuPanelController.refresh()
        trackMenuBarOpened(entrypoint: entrypoint)
        popover.contentViewController = menuPanelController
        popover.contentSize = menuPanelController.preferredContentSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func trackMenuBarOpened(entrypoint: String) {
        let modelState = appState.sttRouter.modelDownloadState.diagnosticName

        let updateState: String
        switch appState.sparkleUpdater.updateStatus.state {
        case .unknown:
            updateState = "unknown"
        case .readyToCheck:
            updateState = "ready"
        case .checking:
            updateState = "checking"
        case .noUpdateAvailable:
            updateState = "up_to_date"
        case .updateAvailable:
            updateState = "available"
        case .downloading:
            updateState = "downloading"
        case .readyToInstall:
            updateState = "ready_to_install"
        }

        AnalyticsReporter.track(
            "menu_bar_opened",
            properties: [
                "dictation_ready": appState.sttRouter.isModelLoaded ? "true" : "false",
                "entrypoint": entrypoint,
                "meeting_recording_ready": TranscriptedPermissionAccess.isGranted(.systemAudioRecording) ? "true" : "false",
                "model_state": modelState,
                "paste_available": "unknown",
                "recent_meetings_available": "unknown",
                "update_state": updateState,
            ]
        )
    }

    private func trackOnboardingShown(entrypoint: String) {
        AnalyticsReporter.track(
            "onboarding_shown",
            properties: [
                "analytics_available": AnalyticsReporter.isAvailable ? "true" : "false",
                "crash_reporting_available": CrashReporter.isAvailable ? "true" : "false",
                "entrypoint": entrypoint,
                "has_target": lastExternalApplication == nil ? "false" : "true",
                "meeting_recording_ready": TranscriptedPermissionAccess.isGranted(.systemAudioRecording) ? "true" : "false",
                "mic_status": TranscriptedPermissionAccess.microphoneAuthorizationStatus().diagnosticName,
                "model_state": appState.sttRouter.modelDownloadState.diagnosticName,
                "pasteback_status": TranscriptedPermissionAccess.isGranted(.accessibility) ? "granted" : "not_granted",
            ]
        )
    }

    private func meetingPromptTelemetryReadiness() -> MeetingPromptTelemetryReadiness {
        MeetingPromptTelemetryReadiness(
            microphoneGranted: TranscriptedPermissionAccess.isGranted(.microphone),
            systemAudioRecordingGranted: TranscriptedPermissionAccess.isGranted(.systemAudioRecording),
            meetingRecordingActive: appState.meetingSession.isRecording,
            dictationRecordingActive: appState.sttRouter.isRecording
        )
    }

    private func resolvedSourceApp() -> NSRunningApplication? {
        if let frontmost = NSWorkspace.shared.frontmostApplication,
           frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastExternalApplication = frontmost
            return frontmost
        }

        if let lastExternalApplication,
           lastExternalApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
            return lastExternalApplication
        }

        return nil
    }

    /// Subscribe to the Dock preference plus meeting and dictation
    /// recording flags so the activation-policy controller can keep the
    /// app visible when users want a Dock icon or when active capture
    /// needs force-quit visibility.
    private func wireActivationPolicy(controller: ActivationPolicyController) {
        NotificationCenter.default.publisher(for: .dockVisibilityPreferencesDidChange)
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] _ in
                controller?.setShowInDock(DockVisibilityPreferences.isVisible())
            }
            .store(in: &activationPolicySubscriptions)

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] _ in
                controller?.reapplyCurrentPolicy()
            }
            .store(in: &activationPolicySubscriptions)

        // Dictation: STTRouter publishes its own isRecording flag.
        appState.sttRouter.$isRecording
            .receive(on: DispatchQueue.main)
            .sink { [weak controller] isRecording in
                controller?.setDictationRecording(isRecording)
            }
            .store(in: &activationPolicySubscriptions)

        // Meeting: the @MainActor MeetingSessionController owns the flag.
        // Only available on macOS 14+, matching where MeetingSession lives.
        if #available(macOS 14.0, *) {
            appState.meetingSession.$isRecording
                .receive(on: DispatchQueue.main)
                .sink { [weak controller] isRecording in
                    controller?.setMeetingRecording(isRecording)
                }
                .store(in: &activationPolicySubscriptions)
        }
    }

    private func startDictationFromSettings() {
        guard let session = appState.contextCapture.sessionController else { return }
        let sourceApp = resolvedSourceApp()
        sourceApp?.activate(options: [])
        session.startDictation(sourceApp: sourceApp, trigger: .menu)
    }

    private func startMeetingFromSettings() {
        let sourceApp = resolvedSourceApp()
        sourceApp?.activate(options: [])
        Task {
            await appState.meetingSession.startRecording(trigger: .menu)
        }
    }

    private func importAudioFileFromSettings() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Transcribe"
        panel.message = "Choose a WAV, MP3, M4A, AAC, AIFF, or other macOS-readable audio file."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            _ = await appState.meetingSession.importAudioFile(from: url)
        }
    }

    private func pasteLastDictationFromSettings() {
        guard let latestText = DictationTranscriptStore.latestSavedText() else {
            PasteLastDictationFeedbackPresenter.shared.present(.noSavedDictation)
            return
        }

        let sourceApp = resolvedSourceApp()
        let pasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)
        sourceApp?.activate(options: [])
        let outcome = settingsTextPaster.paste(latestText, target: pasteTarget)
        PasteLastDictationFeedbackPresenter.shared.present(.presentation(for: outcome))
    }

    @available(macOS 14.0, *)
    private func applyAutoCallDetectionPreference() {
        if AutoCallDetectionPreferences.isEnabled() {
            micActivityMonitor.start()
            cameraActivityMonitor.start()
        } else {
            micActivityMonitor.stop()
            cameraActivityMonitor.stop()
            // Drop any in-flight mic/output/camera candidates so a stale call can't prompt.
            meetingPromptDetector.updateMicInputUsers([])
            meetingPromptDetector.updateAudioOutputUsers([])
            meetingPromptDetector.updateCameraInUse(false)
        }
    }

    @available(macOS 14.0, *)
    private func observeAutoCallDetectionPreference() {
        guard micPreferenceObserver == nil else { return }
        micPreferenceObserver = NotificationCenter.default.addObserver(
            forName: .autoCallDetectionPrefsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyAutoCallDetectionPreference()
            }
        }
    }

    // MARK: - Menu Bar Commands

    /// Thin entry points for `TranscriptedMenuCommands`. They live here (rather
    /// than in an extension) so they can reuse the existing private action
    /// helpers. Each one mirrors a path users already have via the popover, the
    /// sidebar, or a recordable trigger — nothing here remaps those triggers.

    func menuStartDictation() {
        startDictationFromSettings()
    }

    func menuToggleMeetingRecording() {
        guard #available(macOS 14.0, *) else {
            NSSound.beep()
            return
        }
        // Same start/stop toggle the meeting trigger uses, so ⌘R behaves like
        // the recordable meeting shortcut.
        meetingOverlayController.toggleFromHotkey()
    }

    func menuImportAudio() {
        importAudioFileFromSettings()
    }

    func menuOpenPage(_ page: TranscriptedSettingsPage) {
        showSettingsWindow(page: page, source: "menu_command")
    }

    func menuFindSpeaker() {
        settingsWindowController.focusSpeakerSearch(source: "menu_command")
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        menuPanelController.prepareForClose()
        if popover?.contentViewController !== menuPanelController {
            popover?.contentViewController = nil
        }
    }
}
