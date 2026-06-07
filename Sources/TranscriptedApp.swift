// TranscriptedApp.swift
// Menubar app for local dictation + meeting transcription

import SwiftUI
import AppKit
import AVFoundation
import Carbon
import Combine
import TranscriptedCore
import UniformTypeIdentifiers

@main
struct TranscriptedApp: App {
    @NSApplicationDelegateAdaptor(TranscriptedAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
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
    private var statusItemUpdateSubscription: AnyCancellable?
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
    lazy var meetingPromptDetector = MeetingPromptDetector()
    private var workspaceObservers: [NSObjectProtocol] = []
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
            meetingOverlayController.setup(meetingSession: meetingSession)
            meetingOverlayController.onPromptRecord = { [weak self] candidate in
                guard let self else { return }
                AnalyticsReporter.track(
                    "meeting_prompt_record_selected",
                    properties: self.analyticsProperties(for: candidate)
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
            meetingOverlayController.onPromptDismiss = { [weak self] candidate in
                guard let self else { return }
                let backoffDecision = self.meetingPromptDetector.dismiss(candidate: candidate)
                AnalyticsReporter.track(
                    "meeting_prompt_dismissed",
                    properties: self.analyticsProperties(
                        for: candidate,
                        backoffKind: backoffDecision.kind
                    )
                )
            }
            meetingOverlayController.onPromptRemindSoon = { [weak self] candidate in
                guard let self else { return }
                let backoffDecision = self.meetingPromptDetector.remindSoon(candidate: candidate)
                AnalyticsReporter.track(
                    "meeting_prompt_dismissed",
                    properties: self.analyticsProperties(
                        for: candidate,
                        backoffKind: backoffDecision.kind
                    )
                )
            }
            meetingPromptDetector.onPromptRequest = { [weak self] candidate in
                guard PermissionsOnboardingPreferences.hasCompleted() else { return false }
                guard let self else { return false }
                let presented = self.meetingOverlayController.presentDetectedMeetingPrompt(candidate)
                if presented {
                    AnalyticsReporter.track(
                        "meeting_prompt_shown",
                        properties: self.analyticsProperties(for: candidate)
                    )
                }
                return presented
            }
            meetingPromptDetector.start()
            appState.contextCapture.onMeetingToggle = { [weak self] in
                self?.meetingOverlayController.toggleFromHotkey()
            }
            SpeakerNamingSheet.shared.observe(taskManager: meetingSession.taskManager)
        }

        // Set up menubar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            configureStatusItemButton(button)
        }
        bindStatusItemUpdateBadge()
        installSettingsMenuHandler()

        // Set up popover (pure AppKit — no NSHostingController, no AttributeGraph)
        let pop = NSPopover()
        pop.contentSize = NSSize(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        pop.behavior = .transient
        pop.delegate = self
        pop.appearance = NSAppearance(named: .darkAqua)
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

        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = singleInstanceReopenObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            singleInstanceReopenObserver = nil
        }
        if #available(macOS 14.0, *) {
            meetingPromptDetector.stop()
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

        if !PermissionsOnboardingPreferences.hasCompleted() {
            onboardingWindowController.present(entrypoint: "single_instance_reopen")
        } else {
            showSettingsWindow(page: .home, source: "single_instance_reopen")
        }

        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func togglePopover() {
        if !PermissionsOnboardingPreferences.hasCompleted() {
            _ = resolvedSourceApp()
            onboardingWindowController.present(entrypoint: "status_item")
            return
        }

        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            showMainPopover(relativeTo: button, popover: popover)
        }
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

        installStatusItemUpdateBadge(on: button)
    }

    private func installStatusItemUpdateBadge(on button: NSStatusBarButton) {
        guard statusItemUpdateBadge.superview !== button else { return }

        statusItemUpdateBadge.translatesAutoresizingMaskIntoConstraints = false
        statusItemUpdateBadge.wantsLayer = true
        statusItemUpdateBadge.layer?.backgroundColor = NSColor.systemOrange.cgColor
        statusItemUpdateBadge.layer?.borderColor = NSColor.black.withAlphaComponent(0.45).cgColor
        statusItemUpdateBadge.layer?.borderWidth = 1
        statusItemUpdateBadge.layer?.cornerRadius = 4
        statusItemUpdateBadge.layer?.masksToBounds = true
        statusItemUpdateBadge.isHidden = true

        button.addSubview(statusItemUpdateBadge)
        NSLayoutConstraint.activate([
            statusItemUpdateBadge.widthAnchor.constraint(equalToConstant: 8),
            statusItemUpdateBadge.heightAnchor.constraint(equalToConstant: 8),
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

    private func bindStatusItemUpdateBadge() {
        statusItemUpdateSubscription = appState.sparkleUpdater.$updateStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateStatusItemBadge(for: status)
            }
        updateStatusItemBadge(for: appState.sparkleUpdater.updateStatus)
    }

    private func updateStatusItemBadge(for status: SparkleUpdaterController.UpdateStatus) {
        let updateVersion = status.readyToInstallVersion
        statusItemUpdateBadge.isHidden = updateVersion == nil

        if let updateVersion {
            statusItem?.button?.toolTip = "Transcripted - restart to update to \(updateVersion)"
        } else {
            statusItem?.button?.toolTip = "Transcripted"
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
        let modelState = modelStateAnalyticsName(appState.sttRouter.modelDownloadState)

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
                "mic_status": microphoneStatusAnalyticsName(TranscriptedPermissionAccess.microphoneAuthorizationStatus()),
                "model_state": modelStateAnalyticsName(appState.sttRouter.modelDownloadState),
                "pasteback_status": TranscriptedPermissionAccess.isGranted(.accessibility) ? "granted" : "not_granted",
            ]
        )
    }

    private func modelStateAnalyticsName(_ state: ParakeetModelState) -> String {
        switch state {
        case .notLoaded:
            return "not_loaded"
        case .downloading:
            return "downloading"
        case .cached:
            return "cached"
        case .loading:
            return "loading"
        case .ready:
            return "ready"
        case .failed:
            return "failed"
        }
    }

    private func microphoneStatusAnalyticsName(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return "not_determined"
        case .restricted:
            return "restricted"
        case .denied:
            return "denied"
        case .authorized:
            return "authorized"
        @unknown default:
            return "unknown"
        }
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
            NSSound.beep()
            return
        }

        let sourceApp = resolvedSourceApp()
        let pasteTarget = DictationPasteTarget.capture(sourceApp: sourceApp)
        sourceApp?.activate(options: [])
        _ = settingsTextPaster.paste(latestText, target: pasteTarget)
    }

    @available(macOS 14.0, *)
    private func analyticsProperties(
        for candidate: MeetingPromptDetector.Candidate,
        backoffKind: MeetingPromptBackoffKind? = nil
    ) -> [String: String] {
        var properties = [
            "prompt_reason": candidate.reason.rawValue,
            "provider": candidate.provider.rawValue,
            "source": candidate.source.analyticsValue,
        ]
        if let backoffKind {
            properties["backoff_kind"] = backoffKind.rawValue
        }
        return properties
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        menuPanelController.prepareForClose()
        if popover?.contentViewController !== menuPanelController {
            popover?.contentViewController = nil
        }
    }
}

@available(macOS 14.0, *)
private extension MeetingPromptSource {
    var analyticsValue: String {
        switch self {
        case .calendarEvent:
            return "calendar_event"
        case .runtimeApp:
            return "runtime_app"
        }
    }
}
