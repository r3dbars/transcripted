// DraftApp.swift
// Menubar app for local dictation + meeting transcription

import SwiftUI
import AppKit
import Carbon
import TranscriptedCore

@main
struct DraftApp: App {
    @NSApplicationDelegateAdaptor(DraftAppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

// MARK: - App Delegate

@MainActor
class DraftAppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?
    private var lastExternalApplication: NSRunningApplication?
    private lazy var settingsWindowController = TranscriptedSettingsWindowController(appState: appState)
    private lazy var menuPanelController = MenuBarPanelController(
        appState: appState,
        preferredSourceAppProvider: { [weak self] in self?.lastExternalApplication },
        openSettingsWindow: { [weak self] in self?.showSettingsWindow() },
        openAgentConnectWindow: { [weak self] in self?.showAgentConnectWindow() },
        dismissPopover: { [weak self] in self?.closePopover() }
    )

    let appState = DraftAppState()
    let overlayController = FloatingOverlayController()
    let sessionController = DraftSessionController()
    /// Second non-activating panel for meeting mode (Lane C). Distinct from
    /// the dictation overlay so regressions to one can't break the other.
    @available(macOS 14.0, *)
    lazy var meetingOverlayController = MeetingOverlayController()
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
            appState.contextCapture.onMeetingToggle = { [weak self] in
                self?.meetingOverlayController.toggleFromHotkey()
            }
            SpeakerNamingSheet.shared.observe(taskManager: meetingSession.taskManager)
        }

        // Set up menubar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.and.signal.meter", accessibilityDescription: "Transcripted")
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
        #if BETA_BUILD
        BetaTelemetry.shared.shipLogs()
        #endif
        appState.shutdown()
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            closePopover()
        } else {
            if let frontmost = NSWorkspace.shared.frontmostApplication,
               frontmost.bundleIdentifier != Bundle.main.bundleIdentifier {
                lastExternalApplication = frontmost
            }
            if !PermissionsOnboardingView.hasCompleted {
                popover.contentViewController = NSHostingController(
                    rootView: PermissionsOnboardingView(onComplete: { [weak self] in
                        PermissionsOnboardingView.markCompleted()
                        guard let self else { return }
                        self.menuPanelController.refresh()
                        self.popover?.contentViewController = self.menuPanelController
                    })
                )
            } else {
                menuPanelController.refresh()
                popover.contentViewController = menuPanelController
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
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

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        menuPanelController.prepareForClose()
        if popover?.contentViewController !== menuPanelController {
            popover?.contentViewController = nil
        }
    }
}
