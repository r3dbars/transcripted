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
    var taskManager: TranscriptionTaskManager?
    var audio: Audio?
    var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Setup menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: "Murmur")
            button.action = #selector(statusBarClicked)
            button.target = self
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Show/Hide Window", action: #selector(toggleWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Murmur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu

        // Initialize task manager and audio
        taskManager = TranscriptionTaskManager()
        audio = Audio()

        // Wire up recording completion callback
        audio?.onRecordingComplete = { [weak self] micURL, systemURL in
            self?.handleRecordingComplete(micURL: micURL, systemURL: systemURL)
        }

        // Create floating panel
        floatingPanel = FloatingPanelController(
            taskManager: taskManager!,
            audio: audio!
        )
        floatingPanel?.showWindow(nil)

        // Request permissions
        requestPermissions()
    }

    @objc func statusBarClicked() {
        // Menu shows automatically
    }

    @objc func toggleWindow() {
        if let window = floatingPanel?.window {
            window.isVisible ? window.orderOut(nil) : window.makeKeyAndOrderFront(nil)
        }
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
            window.title = "Murmur Settings"
            window.center()
            window.isReleasedWhenClosed = false

            settingsWindow = window
        }

        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func requestPermissions() {
        // Request speech recognition permission
        SFSpeechRecognizer.requestAuthorization { status in
            if status != .authorized {
                print("❌ Speech recognition permission denied")
            } else {
                print("✓ Speech recognition permission granted")
            }
        }

        print("ℹ️ System audio permission will be requested on first capture attempt")
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
            outputFolder = documentsPath.appendingPathComponent("Murmur Transcripts")
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
