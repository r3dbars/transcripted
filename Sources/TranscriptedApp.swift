// TranscriptedApp.swift
// Menubar app for local dictation + meeting transcription

import SwiftUI
import AppKit
import Carbon
import TranscriptedCore

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
    private lazy var settingsWindowController = TranscriptedSettingsWindowController(appState: appState)
    private lazy var onboardingWindowController = TranscriptedOnboardingWindowController(
        makeView: { [unowned self] in self.makeOnboardingView() }
    )
    private lazy var menuPanelController = MenuBarPanelController(
        appState: appState,
        preferredSourceAppProvider: { [weak self] in self?.lastExternalApplication },
        openSettingsWindow: { [weak self] in self?.showSettingsWindow() },
        openAgentConnectWindow: { [weak self] in self?.showAgentConnectWindow() },
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Crash reporting
        CrashReporter.setup()

        // Dock icon + menubar
        NSApp.setActivationPolicy(.accessory)

        // Wire session controller
        sessionController.appState = appState
        sessionController.overlayController = overlayController
        appState.contextCapture.sessionController = sessionController

        // Set up the floating overlay panel (pure AppKit — no NSHostingView)
        overlayController.setup(sttRouter: appState.sttRouter)

        // Meeting overlay + hotkey + speaker naming — Lane C wiring.
        if #available(macOS 14.0, *) {
            let meetingSession = appState.meetingSession
            meetingOverlayController.setup(meetingSession: meetingSession)
            meetingOverlayController.onPromptRecord = { [weak self] candidate in
                guard let self else { return }
                AnalyticsReporter.track(
                    "meeting_prompt_record_selected",
                    properties: self.analyticsProperties(for: candidate)
                )
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let started = await self.appState.meetingSession.startRecording(trigger: .detectedPrompt)
                    if started {
                        self.meetingPromptDetector.markAccepted(candidate: candidate)
                    }
                }
            }
            meetingOverlayController.onPromptDismiss = { [weak self] candidate in
                guard let self else { return }
                let backoffDecision = self.meetingPromptDetector.snooze(candidate: candidate)
                AnalyticsReporter.track(
                    "meeting_prompt_dismissed",
                    properties: self.analyticsProperties(
                        for: candidate,
                        backoffKind: backoffDecision.kind
                    )
                )
            }
            meetingPromptDetector.onPromptRequest = { [weak self] candidate in
                guard PermissionsOnboardingView.hasCompleted else { return false }
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
            let image = NSImage(systemSymbolName: "mic.and.signal.meter", accessibilityDescription: "Transcripted")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Transcripted"
            button.action = #selector(togglePopover)
            button.target = self
        }

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
            appState.contextCapture.registerHotkey()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        togglePopover()
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

    @objc func togglePopover() {
        if !PermissionsOnboardingView.hasCompleted {
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

    private func closePopover() {
        menuPanelController.prepareForClose()
        popover?.performClose(nil)
        if popover?.contentViewController !== menuPanelController {
            popover?.contentViewController = nil
        }
    }

    private func showSettingsWindow() {
        settingsWindowController.present()
    }

    private func showAgentConnectWindow() {
        AgentConnectionWindowCoordinator.shared.show()
    }

    private func makeOnboardingView() -> PermissionsOnboardingView {
        let hasPasteTarget = resolvedSourceApp() != nil
        return PermissionsOnboardingView(
            parakeetEngine: appState.sttRouter.parakeetEngine,
            canStartDictation: hasPasteTarget,
            onStartDictation: { [weak self] in
                self?.finishOnboardingAndStartDictation()
            },
            onComplete: { [weak self] in
                self?.finishOnboarding()
            }
        )
    }

    private func presentInitialOnboardingIfNeeded() {
        guard !PermissionsOnboardingView.hasCompleted, !hasPresentedInitialOnboarding else { return }
        hasPresentedInitialOnboarding = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, !self.onboardingWindowController.isVisible, !PermissionsOnboardingView.hasCompleted else { return }
            self.onboardingWindowController.present()
        }
    }

    private func finishOnboarding() {
        PermissionsOnboardingView.markCompleted()
        onboardingWindowController.dismiss()
        closePopover()

        guard let button = statusItem?.button, let popover = popover else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.showMainPopover(relativeTo: button, popover: popover)
        }
    }

    private func finishOnboardingAndStartDictation() {
        let sourceApp = resolvedSourceApp()
        PermissionsOnboardingView.markCompleted()
        onboardingWindowController.dismiss()
        closePopover()
        sourceApp?.activate(options: [])
        sessionController.startDictation(sourceApp: sourceApp, trigger: .onboarding)
    }

    private func showMainPopover(relativeTo button: NSStatusBarButton, popover: NSPopover) {
        _ = resolvedSourceApp()
        menuPanelController.refresh()
        popover.contentViewController = menuPanelController
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
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
