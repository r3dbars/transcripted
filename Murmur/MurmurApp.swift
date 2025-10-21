import SwiftUI
import AppKit
import Speech

@available(macOS 26.0, *)
@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@available(macOS 26.0, *)
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var floatingPanel: FloatingPanelController?
    var transcription: Transcription?
    var audio: Audio?
    var settingsWindow: NSWindow?
    var debugWindow: NSWindow?
    var modelPromptWindow: NSWindow?
    var modelManager: SpeechModelManager?
    var microphoneMonitor: MicrophoneMonitor?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Murmur")
            button.action = #selector(statusBarClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show/Hide Window", action: #selector(toggleWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Debug Console...", action: #selector(openDebugConsole), keyEquivalent: "d"))
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Initialize model manager
        modelManager = SpeechModelManager()

        transcription = Transcription()
        transcription?.modelManager = modelManager  // Link model manager

        audio = Audio(transcription: transcription!)

        floatingPanel = FloatingPanelController(
            transcription: transcription!,
            audio: audio!
        )
        floatingPanel?.showWindow(nil)

        // Initialize microphone monitor with floating panel
        microphoneMonitor = MicrophoneMonitor(
            audio: audio!,
            floatingPanel: floatingPanel
        )

        requestPermissions()

        // Check speech model availability after a short delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkSpeechModel()
        }
    }

    @objc func statusBarClicked() {
        // Menu shows automatically
    }

    @objc func toggleWindow() {
        if let window = floatingPanel?.window {
            window.isVisible ? window.orderOut(nil) : window.makeKeyAndOrderFront(nil)
        }
    }

    func toggleRecording() {
        if audio?.isRecording == true {
            audio?.stop()
        } else {
            audio?.start()
        }
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            guard let modelManager = modelManager else { return }
            let view = SettingsView(modelManager: modelManager)
            let controller = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 450, height: 500),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Murmur Settings"
            window.center()
            window.isReleasedWhenClosed = false

            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDebugConsole() {
        if debugWindow == nil {
            let view = DebugWindow()
            let controller = NSHostingController(rootView: view)

            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Murmur Debug Console"
            window.center()
            window.isReleasedWhenClosed = false

            debugWindow = window
        }

        debugWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestPermissions() {
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                print("❌ Speech recognition permission denied")
            } else {
                print("✓ Speech recognition permission granted")
            }
        }

        // Note: System audio capture permission is requested automatically
        // when attempting to create the audio tap (via NSAudioCaptureUsageDescription)
        print("ℹ️ System audio permission will be requested on first capture attempt")
    }

    func checkSpeechModel() {
        guard let modelManager = modelManager else { return }

        Task {
            await modelManager.checkModelAvailability()

            // Show prompt if needed
            await MainActor.run {
                if modelManager.shouldShowModelPrompt {
                    self.showModelPrompt()
                }
            }
        }
    }

    func showModelPrompt() {
        guard let modelManager = modelManager else { return }

        let view = SpeechModelPromptView(modelManager: modelManager)
        let controller = NSHostingController(rootView: view)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 550),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentViewController = controller
        window.title = "Enhanced Privacy"
        window.center()
        window.isReleasedWhenClosed = true

        modelPromptWindow = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
