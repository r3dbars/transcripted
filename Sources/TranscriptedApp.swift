// TranscriptedApp.swift
// Menubar app for local dictation + meeting transcription

import SwiftUI
import AppKit
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
        openOnboarding: { [weak self] in self?.showOnboardingFromSettings() },
        openConnectAgent: { [weak self] in self?.showSettingsWindow(page: .connectAgent, source: "settings_action") },
        checkForUpdates: { [weak self] in self?.appState.sparkleUpdater.checkForUpdates() },
        sendFeedback: { [weak self] in
            guard let self else { return .unavailable }
            return TranscriptedSupportActions.sendFeedback(appState: self.appState)
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
        makeView: { [unowned self] in self.makeOnboardingView() }
    )
    private lazy var menuPanelController = MenuBarPanelController(
        appState: appState,
        preferredSourceAppProvider: { [weak self] in self?.lastExternalApplication },
        openSettingsWindow: { [weak self] page in self?.showSettingsWindow(page: page, source: "menu_bar") },
        dismissPopover: { [weak self] in self?.closePopover() }
    )

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
    private var meetingSubsystemBootstrapped = false

    /// Keeps NSApp in sync with the Dock visibility setting and promotes
    /// the app to `.regular` during active recording for force-quit
    /// recovery. Initialized in `applicationDidFinishLaunching` after
    /// AppKit is ready.
    private var activationPolicyController: ActivationPolicyController?
    private var activationPolicySubscriptions: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        appState.contextCapture.registerHotkey()

        // Meeting prompt detection starts after onboarding; the heavier
        // controller/overlay stack is bootstrapped on first real meeting use.
        if #available(macOS 14.0, *) {
            meetingPromptDetector.onPromptRequest = { [weak self] candidate in
                guard PermissionsOnboardingPreferences.hasCompleted() else { return false }
                guard let self else { return false }
                self.bootstrapMeetingSubsystemIfNeeded()
                let presented = self.meetingOverlayController.presentDetectedMeetingPrompt(candidate)
                if presented {
                    AnalyticsReporter.track(
                        "meeting_prompt_shown",
                        properties: self.analyticsProperties(for: candidate)
                    )
                }
                return presented
            }
            startMeetingPromptDetectionIfAllowed()
            appState.contextCapture.onMeetingToggle = { [weak self] in
                guard let self else { return }
                self.bootstrapMeetingSubsystemIfNeeded()
                self.meetingOverlayController.toggleFromHotkey()
            }
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
            onboardingWindowController.present()
            return false
        }

        showSettingsWindow(page: .home, source: "dock_icon")
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if #available(macOS 14.0, *) {
            meetingPromptDetector.stop()
        }
        appState.shutdown()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminationCleanupStarted else { return .terminateNow }
        terminationCleanupStarted = true

        Task { @MainActor [weak self, sender] in
            guard let self else {
                sender.reply(toApplicationShouldTerminate: true)
                return
            }

            await self.sessionController.finishDictationForTermination()
            if #available(macOS 14.0, *), let meetingSession = self.appState.loadedMeetingSession {
                await meetingSession.prepareForTermination()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }

        return .terminateLater
    }

    @objc func togglePopover() {
        if !PermissionsOnboardingPreferences.hasCompleted() {
            _ = resolvedSourceApp()
            onboardingWindowController.present()
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
        if #available(macOS 14.0, *) {
            bootstrapMeetingSubsystemIfNeeded()
        }
        settingsWindowController.present(page: page, source: source)
    }

    private func showOnboardingFromSettings() {
        PermissionsOnboardingPreferences.requestRerun()
        onboardingWindowController.present()
    }

    private func makeOnboardingView() -> PermissionsOnboardingView {
        PermissionsOnboardingView { [weak self] in
            self?.finishOnboarding()
        }
    }

    private func presentInitialOnboardingIfNeeded() {
        guard !PermissionsOnboardingPreferences.hasCompleted(), !hasPresentedInitialOnboarding else { return }
        hasPresentedInitialOnboarding = true

        DispatchQueue.main.async { [weak self] in
            guard let self, !self.onboardingWindowController.isVisible, !PermissionsOnboardingPreferences.hasCompleted() else { return }
            self.onboardingWindowController.present()
        }
    }

    private func finishOnboarding() {
        PermissionsOnboardingPreferences.markCompleted()
        if #available(macOS 14.0, *) {
            startMeetingPromptDetectionIfAllowed()
        }
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
        if #available(macOS 14.0, *) {
            bootstrapMeetingSubsystemIfNeeded()
        }
        menuPanelController.refresh()
        trackMenuBarOpened(entrypoint: entrypoint)
        popover.contentViewController = menuPanelController
        popover.contentSize = menuPanelController.preferredContentSize
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
    }

    @available(macOS 14.0, *)
    private func startMeetingPromptDetectionIfAllowed() {
        guard PermissionsOnboardingPreferences.hasCompleted() else { return }
        meetingPromptDetector.start()
    }

    @available(macOS 14.0, *)
    @discardableResult
    private func bootstrapMeetingSubsystemIfNeeded() -> MeetingSessionController {
        let meetingSession = appState.meetingSession
        guard !meetingSubsystemBootstrapped else { return meetingSession }

        meetingSubsystemBootstrapped = true
        meetingOverlayController.setup(meetingSession: meetingSession)
        meetingOverlayController.onPromptRecord = { [weak self] candidate in
            guard let self else { return }
            AnalyticsReporter.track(
                "meeting_prompt_record_selected",
                properties: self.analyticsProperties(for: candidate)
            )
            Task { @MainActor [weak self] in
                guard let self else { return }
                let meetingSession = self.bootstrapMeetingSubsystemIfNeeded()
                let started = await meetingSession.startRecording(trigger: .detectedPrompt)
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
        meetingOverlayController.onShowErrorDetails = { [weak self] in
            self?.showSettingsWindow(page: .meetings, source: "meeting_overlay_error")
        }
        if let activationPolicyController {
            activationPolicyController.setMeetingRecording(meetingSession.isRecording)
            meetingSession.$isRecording
                .receive(on: DispatchQueue.main)
                .sink { [weak activationPolicyController] isRecording in
                    activationPolicyController?.setMeetingRecording(isRecording)
                }
                .store(in: &activationPolicySubscriptions)
        }
        SpeakerNamingSheet.shared.observe(taskManager: meetingSession.taskManager)
        return meetingSession
    }

    private func trackMenuBarOpened(entrypoint: String) {
        let modelState: String
        switch appState.sttRouter.modelDownloadState {
        case .notLoaded:
            modelState = "not_loaded"
        case .downloading:
            modelState = "downloading"
        case .loading:
            modelState = "loading"
        case .ready:
            modelState = "ready"
        case .failed:
            modelState = "failed"
        }

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

        // Meeting recording is wired when the meeting subsystem is first used,
        // so launch does not force-create the SQLite/audio meeting stack.
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
        if #available(macOS 14.0, *) {
            let meetingSession = bootstrapMeetingSubsystemIfNeeded()
            Task {
                await meetingSession.startRecording(trigger: .menu)
            }
        }
    }

    private func importAudioFileFromSettings() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Transcribe"
        panel.message = "Choose an audio file Transcripted should transcribe."

        guard panel.runModal() == .OK, let url = panel.url else { return }

        if #available(macOS 14.0, *) {
            let meetingSession = bootstrapMeetingSubsystemIfNeeded()
            Task {
                _ = await meetingSession.importAudioFile(from: url)
            }
        }
    }

    private func pasteLastDictationFromSettings() {
        guard let latestText = DictationTranscriptStore.latestSavedText() else {
            NSSound.beep()
            return
        }

        let sourceApp = resolvedSourceApp()
        sourceApp?.activate(options: [])
        _ = settingsTextPaster.paste(latestText)
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
