// ContextCaptureEngine.swift
// Orchestrates: hotkey toggle → screenshot → session start/stop

import AppKit
import Carbon

// MARK: - Carbon Hotkey Handler (C-level callback)

// Global references so the C callback can reach the engines
private weak var _sharedEngine: ContextCaptureEngine?
private weak var _sharedSessionController: DraftSessionController?

private func hotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
)-> OSStatus {
    // Extract which hotkey fired (id: 1 = ⌥D draft, id: 2 = ⌥Space dictation)
    guard let event = event else { return noErr }
    var hotkeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotkeyID
    )
    guard status == noErr else { return noErr }

    if hotkeyID.id == 1 {
        // ⌥Space — Draft mode: capture screenshot SYNCHRONOUSLY before focus shifts
        let frontApp = NSWorkspace.shared.frontmostApplication
        let imageData: Data? = frontApp.flatMap { ScreenCapture.captureFrontmostWindow(of: $0) }

        Task { @MainActor in
            guard let session = _sharedSessionController else { return }
            if session.isDictating {
                // Cross-mode switch: cancel dictation, start draft
                session.cancelDictation()
                session.startSession(imageData: imageData, sourceApp: frontApp)
            } else if session.isInSession {
                if session.overlayController?.state == .review {
                    session.cancelSession()
                } else {
                    session.stopSessionAndDraft()
                }
            } else {
                session.startSession(imageData: imageData, sourceApp: frontApp)
            }
        }
    } else if hotkeyID.id == 2 {
        // ⌥D — Dictation mode: NO screenshot needed (pure voice-to-text)
        let frontApp = NSWorkspace.shared.frontmostApplication

        Task { @MainActor in
            guard let session = _sharedSessionController else { return }
            if session.isDictating {
                session.stopDictationAndPaste()
            } else if session.isInSession {
                // Cross-mode switch: cancel draft, start dictation
                session.cancelSession()
                session.startDictation(sourceApp: frontApp)
            } else {
                session.startDictation(sourceApp: frontApp)
            }
        }
    }
    return noErr
}

// MARK: - Context Capture Engine

@MainActor
class ContextCaptureEngine: ObservableObject {
    @Published var isCapturing = false
    @Published var capturedContext: CapturedContext?
    @Published var captureError: String?

    /// The app that was frontmost when the hotkey was pressed
    @Published var sourceApp: NSRunningApplication?

    private var hotkeyRef: EventHotKeyRef?
    private var dictationHotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    /// Called when structured context is ready — set by ContentView (legacy, unused in v2)
    var onContextCaptured: ((CapturedContext) -> Void)?

    /// Fires immediately on hotkey press (legacy, unused in v2)
    var onHotkeyFired: (() -> Void)?

    /// Reference to PromptStore — set by DraftAppState after init
    var promptStore: PromptStore?

    /// Set by DraftAppDelegate to wire the hotkey to the session controller
    var sessionController: DraftSessionController? {
        didSet {
            _sharedSessionController = sessionController
        }
    }

    func registerHotkey() {
        guard eventHandlerRef == nil else {
            print("⚠️ CAPTURE | hotkey already registered")
            return
        }
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

        // Option+D — Draft mode (screenshot + voice → AI draft)
        let draftHotkeyID = EventHotKeyID(signature: OSType(0x44524654), id: 1)  // 'DRFT'
        let modifiers: UInt32 = UInt32(optionKey)

        RegisterEventHotKey(
            UInt32(kVK_ANSI_D),
            modifiers,
            draftHotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )

        // Option+Space — Dictation mode (voice → text → paste)
        let dictationHotkeyID = EventHotKeyID(signature: OSType(0x44524654), id: 2)  // 'DRFT'
        RegisterEventHotKey(
            UInt32(kVK_Space),
            modifiers,
            dictationHotkeyID,
            GetApplicationEventTarget(),
            0,
            &dictationHotkeyRef
        )
    }

    deinit {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = dictationHotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
    }

    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let ref = dictationHotkeyRef {
            UnregisterEventHotKey(ref)
            dictationHotkeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        _sharedEngine = nil
        _sharedSessionController = nil
    }

    /// Process capture from the hotkey (legacy interface, preserved for compatibility)
    func processCapture(imageData: Data?, sourceApp: NSRunningApplication? = nil) async {
        guard !isCapturing else { return }

        isCapturing = true
        captureError = nil

        if let app = sourceApp {
            self.sourceApp = app
        }

        // NOTE: In v2, we do NOT call NSApplication.shared.activate() here.
        // The floating overlay is non-activating, so the target app stays frontmost.
        onHotkeyFired?()

        guard let auth = AuthCredential.load() else {
            captureError = "No credentials — add your API key or Claude subscription token in settings"
            isCapturing = false
            return
        }

        guard let imageData = imageData else {
            captureError = "Screenshot failed — grant Screen Recording permission in System Settings → Privacy & Security → Screen Recording"
            isCapturing = false
            return
        }

        let userName = UserDefaults.standard.string(forKey: "user-display-name")
        let appName = sourceApp?.localizedName
        let model = promptStore?.config.model ?? DefaultPrompts.model
        let extractionPrompt = promptStore?.contextExtractionPrompt(userName: userName, appName: appName)
            ?? DefaultPrompts.contextExtraction
                .replacingOccurrences(of: "{USER_NAME}", with: userName.map { "The user's name is \($0). They are one of the participants in this conversation." } ?? "Identify the user based on which side of the conversation they appear on.")
                .replacingOccurrences(of: "{APP_NAME}", with: appName.map { "This screenshot is from the app \"\($0)\"." } ?? "Identify which messaging app this is from the UI.")

        do {
            let context = try await AnthropicAPI.extractStructuredContext(
                imageData: imageData,
                auth: auth,
                model: model,
                systemPrompt: extractionPrompt
            )
            capturedContext = context
            onContextCaptured?(context)
        } catch AnthropicAPIError.subscriptionTokenExpired {
            captureError = "Subscription token expired — run `claude setup-token` and update in Settings"
        } catch {
            captureError = error.localizedDescription
        }

        isCapturing = false
    }

    /// Manual capture from the UI button
    func manualCapture(app: NSRunningApplication?) async {
        guard let app = app else {
            captureError = "No previous app detected"
            return
        }
        let imageData = ScreenCapture.captureFrontmostWindow(of: app)
        await processCapture(imageData: imageData, sourceApp: app)
    }
}
