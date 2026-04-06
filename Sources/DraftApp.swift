// DraftApp.swift
// Menubar-only app — no Dock icon, floating overlay for drafting

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

    let appState = DraftAppState()
    let overlayController = FloatingOverlayController()
    let sessionController = DraftSessionController()
    /// Second non-activating panel for meeting mode (Lane C). Distinct from
    /// the draft overlay so regressions to one can't break the other.
    @available(macOS 14.0, *)
    lazy var meetingOverlayController = MeetingOverlayController()
    var onboardingController: OnboardingWindowController?
    private var workspaceObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Crash reporting
        CrashReporter.setup()

        // Dock icon + menubar
        NSApp.setActivationPolicy(.regular)

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
            button.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "Draft")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Set up popover (pure AppKit — no NSHostingController, no AttributeGraph)
        let pop = NSPopover()
        pop.contentSize = NSSize(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        pop.behavior = .transient
        pop.delegate = self
        popover = pop

        // Engine recovery on wake — hotkeys, file watchers, MLX model health check
        let wakeRecoveryObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.appState.handleSystemWake()
                self?.overlayController.handleSystemWake()
            }
        }
        workspaceObservers.append(wakeRecoveryObserver)

        // Initialize engines
        Task { @MainActor in
            await appState.initialize()
            appState.contextCapture.registerHotkey()

            // Show onboarding if first launch
            if !UserDefaults.standard.bool(forKey: "onboarding-completed") {
                showOnboardingWindow()
            }
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

    func showOnboardingWindow() {
        let controller = OnboardingWindowController()
        controller.sessionController = sessionController
        controller.overlayController = overlayController
        controller.appState = appState
        controller.show()
        onboardingController = controller
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            popover.contentViewController = nil
        } else {
            // Pure AppKit controller — no NSHostingController, no AttributeGraph corruption risk
            popover.contentViewController = nil
            // Check if onboarding is needed — use SwiftUI bridge temporarily (Phase 3 converts)
            if !appState.styleEngine.hasCompletedOnboarding {
                #if BETA_BUILD
                if !PermissionsOnboardingView.hasCompleted {
                    popover.contentViewController = NSHostingController(
                        rootView: PermissionsOnboardingView(onComplete: {
                            PermissionsOnboardingView.markCompleted()
                        })
                    )
                } else {
                    popover.contentViewController = NSHostingController(
                        rootView: StyleOnboardingView(styleEngine: appState.styleEngine)
                    )
                }
                #else
                popover.contentViewController = NSHostingController(
                    rootView: StyleOnboardingView(styleEngine: appState.styleEngine, localInference: appState.localInference)
                )
                #endif
            } else {
                popover.contentViewController = MenuBarPanelController(appState: appState)
            }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil  // Release controller + Combine subscriptions
    }
}
