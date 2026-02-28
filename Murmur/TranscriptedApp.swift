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
    var failedTranscriptionsWindow: NSWindow?

    // New settings window controller (redesigned dashboard)
    var settingsWindowController: SettingsWindowController?

    // Onboarding
    var onboardingWindowController: OnboardingWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize logger (creates log directory, opens file handle)
        _ = AppLogger.shared

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
        audio = Audio()

        guard let ftm = failedTranscriptionManager else {
            AppLogger.app.error("Failed to create FailedTranscriptionManager — aborting setup")
            return
        }
        taskManager = TranscriptionTaskManager(failedTranscriptionManager: ftm)

        guard let tm = taskManager, let aud = audio else {
            AppLogger.app.error("Failed to create TaskManager or Audio — aborting setup")
            return
        }

        // Initialize local transcription models (Parakeet + Sortformer) in background
        AppLogger.app.info("Creating model init task")
        Task { @MainActor in
            AppLogger.app.info("Starting model initialization")
            await tm.transcription.initializeModels()
            AppLogger.app.info("Model initialization complete")
        }

        // Wire up recording completion callback
        aud.onRecordingComplete = { [weak self] micURL, systemURL in
            self?.handleRecordingComplete(micURL: micURL, systemURL: systemURL)
        }

        // Create floating panel
        floatingPanel = FloatingPanelController(
            taskManager: tm,
            audio: aud,
            failedTranscriptionManager: ftm
        )
        floatingPanel?.showWindow(nil)
    }

    #if DEBUG
    @objc func resetOnboarding() {
        OnboardingState.resetOnboarding()
        AppLogger.app.info("Onboarding reset — restart app to see onboarding")
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
        guard let ftm = failedTranscriptionManager, let tm = taskManager else {
            AppLogger.app.error("Cannot open failed transcriptions — managers not initialized")
            return
        }

        if failedTranscriptionsWindow == nil {
            let view = FailedTranscriptionsView(
                failedManager: ftm,
                taskManager: tm
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
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                failedTranscriptionManager: failedTranscriptionManager,
                taskManager: taskManager
            )
        }

        settingsWindowController?.showWindow()
    }

    /// Handle recording completion - trigger transcription
    func handleRecordingComplete(micURL: URL?, systemURL: URL?) {
        guard let micURL = micURL else {
            AppLogger.app.error("No mic audio file available")
            return
        }

        AppLogger.app.info("Recording complete — starting transcription")

        // Capture recording health info before it gets reset (Phase 3: Post-hoc transparency)
        let healthInfo = audio?.createHealthInfo()
        if let health = healthInfo {
            AppLogger.app.info("Recording health", ["quality": health.captureQuality.rawValue, "gaps": "\(health.audioGaps)", "switches": "\(health.deviceSwitches)"])
        }

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
            outputFolder: outputFolder,
            healthInfo: healthInfo
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppLogger.shared.flush()
    }
}
