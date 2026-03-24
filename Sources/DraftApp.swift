// DraftApp.swift
// Menubar-only app — no Dock icon, floating overlay for drafting

import SwiftUI
import AppKit
import Carbon

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
    var onboardingController: OnboardingWindowController?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var appObservers: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Crash reporting — captures ObjC/SwiftUI exceptions + manual Swift error reports
        CrashReporter.setup()

        // Dock icon + menubar
        NSApp.setActivationPolicy(.regular)

        // Wire session controller
        sessionController.appState = appState
        sessionController.overlayController = overlayController
        appState.contextCapture.sessionController = sessionController

        // Set up the floating overlay panel
        overlayController.setup(sttRouter: appState.sttRouter)

        // Set up menubar status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "pencil.and.outline", accessibilityDescription: "Draft")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Set up popover for Style + Agent panel
        // NOTE: No contentViewController created here — it's created on-demand in
        // togglePopover(). A long-lived NSHostingController that's never displayed
        // still subscribes to @ObservedObject properties via SwiftUI observation.
        // After minutes of state changes, the stale AttributeGraph can corrupt
        // pointers that crash when a new hosting controller evaluates its body.
        let pop = NSPopover()
        pop.contentSize = NSSize(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        pop.behavior = .transient
        pop.delegate = self
        popover = pop

        // RELIABILITY: Aggressively tear down the SwiftUI view tree whenever the
        // system state changes. NSHostingController's internal AttributeGraph accumulates
        // stale pointers over sleep/wake, screen lock, and prolonged background time.
        // A _ButtonGesture callback on a stale view dereferences a null pointer → SIGSEGV.
        //
        // Three categories of events that corrupt the graph:
        // 1. System sleep/wake (hardware state change)
        // 2. Screen sleep/wake (display off, lid close, screen lock)
        // 3. App deactivation (user switched away for extended time)
        //
        // Cost of tearing down too often: zero — togglePopover() recreates the VC each
        // time anyway. Cost of not tearing down: hard crash with no recovery.

        // System sleep/wake (NSWorkspace notifications)
        // All of these tear down the popover. didWake also runs engine recovery.
        let popoverTeardownEvents: [NSNotification.Name] = [
            NSWorkspace.willSleepNotification,
            NSWorkspace.didWakeNotification,
            NSWorkspace.screensDidSleepNotification,
            NSWorkspace.screensDidWakeNotification,
            NSWorkspace.sessionDidResignActiveNotification,  // fast user switch
        ]
        for name in popoverTeardownEvents {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.tearDownPopoverViewTree()
                }
            }
            workspaceObservers.append(observer)
        }

        // Engine recovery on wake — hotkeys, file watchers, MLX model health check,
        // and overlay hosting view recreation to clear AG corruption from sleep/wake.
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

        // App deactivation (NSApplication notification — separate center from NSWorkspace)
        let appObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tearDownPopoverViewTree()
            }
        }
        appObservers.append(appObserver)

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
        // Clicking the Dock icon opens the menubar popover
        togglePopover()
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        for observer in appObservers {
            NotificationCenter.default.removeObserver(observer)
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

    /// Nil the popover's contentViewController to destroy the SwiftUI view tree.
    /// Safe to call at any time — the VC is recreated on next togglePopover() open.
    private func tearDownPopoverViewTree() {
        guard let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        }
        popover.contentViewController = nil
    }

    @objc func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }
        if popover.isShown {
            popover.performClose(nil)
            popover.contentViewController = nil  // Force SwiftUI view tree teardown
        } else {
            // Recreate the hosting controller each time to guarantee a fresh SwiftUI
            // view tree. A long-lived NSHostingController accumulates stale observation
            // state across show/hide cycles, eventually crashing in body evaluation.
            // Explicit nil-first ensures the old view tree is fully torn down before
            // the new one is created — prevents AttributeGraph races where two view
            // trees observing the same @ObservedObject overlap during teardown/layout.
            popover.contentViewController = nil
            popover.contentViewController = NSHostingController(
                rootView: MenuBarPanelView(appState: appState)
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - NSPopoverDelegate

    /// Catches transient (click-outside) dismissals that bypass togglePopover().
    /// Without this, the stale NSHostingController retains a SwiftUI view tree with
    /// button gesture handlers that crash after prolonged idle (EXC_BAD_ACCESS in
    /// _ButtonGesture.internalBody.getter via MainActor.assumeIsolated).
    func popoverDidClose(_ notification: Notification) {
        popover?.contentViewController = nil
    }
}
