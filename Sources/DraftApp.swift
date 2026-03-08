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
class DraftAppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var popover: NSPopover?

    let appState = DraftAppState()
    let overlayController = FloatingOverlayController()
    let sessionController = DraftSessionController()
    var onboardingController: OnboardingWindowController?

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
        let pop = NSPopover()
        pop.contentSize = NSSize(width: MenuTokens.panelWidth, height: MenuTokens.panelHeight)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: MenuBarPanelView(appState: appState)
        )
        popover = pop

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
        } else {
            // Recreate the hosting controller each time to guarantee a fresh SwiftUI
            // view tree. A long-lived NSHostingController accumulates stale observation
            // state across show/hide cycles, eventually crashing in body evaluation.
            popover.contentViewController = NSHostingController(
                rootView: MenuBarPanelView(appState: appState)
            )
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
