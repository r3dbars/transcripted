import SwiftUI
import AppKit
import EventKit

@available(macOS 26.0, *)
@main
struct TranscriptedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@available(macOS 26.0, *)
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var floatingPanel: FloatingPanelController?
    var failedTranscriptionManager: FailedTranscriptionManager?
    var taskManager: TranscriptionTaskManager?
    var audio: Audio?
    var settingsWindow: NSWindow?
    var failedTranscriptionsWindow: NSWindow?

    // Onboarding
    var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Configure tooltip delay to 1 second
        UserDefaults.standard.set(1000, forKey: "NSInitialToolTipDelay")

        NSApp.setActivationPolicy(.accessory)

        // Check if onboarding is needed
        if !OnboardingState.hasCompletedOnboarding() {
            showOnboarding()
            return  // Don't set up the rest until onboarding is complete
        }

        // Normal app launch
        setupApp()
    }

    /// Show the onboarding window for first-time users
    private func showOnboarding() {
        onboardingWindowController = OnboardingWindowController(onComplete: { [weak self] in
            // Onboarding complete - now set up the app
            self?.onboardingWindowController = nil
            self?.setupApp()
        })
        onboardingWindowController?.showWithAnimation()
    }

    /// Set up the main app after onboarding or on subsequent launches
    private func setupApp() {
        // Setup menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Transcripted")
            button.action = #selector(statusBarClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show/Hide Window", action: #selector(toggleWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Failed Transcriptions...", action: #selector(openFailedTranscriptions), keyEquivalent: "f"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        // Add "Reset Onboarding" for testing (can be removed in production)
        #if DEBUG
        menu.addItem(NSMenuItem(title: "Reset Onboarding (Debug)", action: #selector(resetOnboarding), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        #endif
        menu.addItem(NSMenuItem(title: "Quit Transcripted", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Initialize managers
        failedTranscriptionManager = FailedTranscriptionManager()
        taskManager = TranscriptionTaskManager(failedTranscriptionManager: failedTranscriptionManager!)
        audio = Audio()

        // Wire up recording completion callback
        audio?.onRecordingComplete = { [weak self] micURL, systemURL in
            self?.handleRecordingComplete(micURL: micURL, systemURL: systemURL)
        }

        // Create floating panel
        floatingPanel = FloatingPanelController(
            taskManager: taskManager!,
            audio: audio!,
            failedTranscriptionManager: failedTranscriptionManager!
        )
        floatingPanel?.showWindow(nil)
    }

    #if DEBUG
    @objc func resetOnboarding() {
        OnboardingState.resetOnboarding()
        print("✓ Onboarding reset. Restart the app to see onboarding again.")
    }
    #endif

    @objc func statusBarClicked() {
        // Menu shows automatically
    }

    @objc func toggleWindow() {
        if let window = floatingPanel?.window {
            window.isVisible ? window.orderOut(nil) : window.makeKeyAndOrderFront(nil)
        }
    }

    @objc func openFailedTranscriptions() {
        if failedTranscriptionsWindow == nil {
            let view = FailedTranscriptionsView(
                failedManager: failedTranscriptionManager!,
                taskManager: taskManager!
            )
            let controller = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 650, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Failed Transcriptions"
            window.center()
            window.isReleasedWhenClosed = false
            window.minSize = NSSize(width: 600, height: 400)

            failedTranscriptionsWindow = window
        }

        failedTranscriptionsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView()
            let controller = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 400),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Transcripted Settings"
            window.center()
            window.isReleasedWhenClosed = false

            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Handle recording completion - trigger transcription
    func handleRecordingComplete(micURL: URL?, systemURL: URL?) {
        guard let micURL = micURL else {
            print("❌ No mic audio file available")
            return
        }

        print("📝 Recording complete - starting transcription")

        // Get output folder from settings
        let outputFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            outputFolder = URL(fileURLWithPath: customPath)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            outputFolder = documentsPath.appendingPathComponent("Transcripted")
        }

        // Create output folder if it doesn't exist
        try? FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        // Start transcription in background using task manager
        taskManager?.startTranscription(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder
        )
    }
}
