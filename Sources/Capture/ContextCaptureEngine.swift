// ContextCaptureEngine.swift
// Orchestrates: hotkey → screenshot → Haiku Vision → structured context

import AppKit
import Carbon

// MARK: - Carbon Hotkey Handler (C-level callback)

// Global reference so the C callback can reach the engine
private weak var _sharedEngine: ContextCaptureEngine?

private func hotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    // CRITICAL: Capture screenshot SYNCHRONOUSLY before any async work.
    // At this instant, the user's app (Slack, etc.) is still frontmost.
    // If we defer to Task/@MainActor, focus may shift to Draft before capture.
    let frontApp = NSWorkspace.shared.frontmostApplication
    let imageData: Data? = frontApp.flatMap { ScreenCapture.captureFrontmostWindow(of: $0) }

    Task { @MainActor in
        await _sharedEngine?.processCapture(imageData: imageData, sourceApp: frontApp)
    }
    return noErr
}

// MARK: - Context Capture Engine

@MainActor
class ContextCaptureEngine: ObservableObject {
    @Published var isCapturing = false
    @Published var capturedContext: CapturedContext?
    @Published var captureError: String?

    /// The app that was frontmost when the hotkey was pressed — the source of the screenshot.
    /// Used for "Paste to [App]" so we paste back to the right app, not just the last focused one.
    @Published var sourceApp: NSRunningApplication?

    private var hotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Called when structured context is ready — set by ContentView
    var onContextCaptured: ((CapturedContext) -> Void)?

    /// Fires immediately on hotkey press — before vision processing starts.
    /// ContentView uses this to start voice recording in parallel.
    var onHotkeyFired: (() -> Void)?

    func registerHotkey() {
        _sharedEngine = self

        // Register for kEventHotKeyPressed
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        // Ctrl+Option+D
        let hotkeyID = EventHotKeyID(signature: OSType(0x44524654), id: 1)  // 'DRFT'
        let modifiers: UInt32 = UInt32(controlKey | optionKey)

        RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            modifiers,
            hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
    }

    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        _sharedEngine = nil
    }

    /// Called from the hotkey callback with pre-captured screenshot data
    func processCapture(imageData: Data?, sourceApp: NSRunningApplication? = nil) async {
        guard !isCapturing else { return }

        isCapturing = true
        captureError = nil

        // Store the source app so "Paste to [App]" knows where to send the reply
        if let app = sourceApp {
            self.sourceApp = app
        }

        // Activate Draft and notify UI IMMEDIATELY — before vision processing.
        // This lets ContentView start voice recording in parallel with vision.
        NSApplication.shared.activate(ignoringOtherApps: true)
        onHotkeyFired?()

        guard let apiKey = KeychainHelper.load(key: "anthropic-api-key") else {
            captureError = "No API key — add your Anthropic key in settings"
            isCapturing = false
            return
        }

        guard let imageData = imageData else {
            captureError = "Screenshot failed — grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording"
            isCapturing = false
            return
        }

        // Load user's name from UserDefaults for identity-aware extraction
        let userName = UserDefaults.standard.string(forKey: "user-display-name")
        let appName = sourceApp?.localizedName

        do {
            let context = try await AnthropicAPI.extractStructuredContext(
                imageData: imageData,
                apiKey: apiKey,
                userName: userName,
                appName: appName
            )
            capturedContext = context
            onContextCaptured?(context)
        } catch {
            captureError = error.localizedDescription
        }

        isCapturing = false
    }

    /// Manual capture from the UI button (uses PreviousAppTracker)
    func manualCapture(app: NSRunningApplication?) async {
        guard let app = app else {
            captureError = "No previous app detected"
            return
        }
        let imageData = ScreenCapture.captureFrontmostWindow(of: app)
        await processCapture(imageData: imageData, sourceApp: app)
    }
}
