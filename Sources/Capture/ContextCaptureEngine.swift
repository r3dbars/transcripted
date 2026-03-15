// ContextCaptureEngine.swift
// Orchestrates: hotkey toggle → screenshot → session start/stop

import AppKit
import Carbon

// MARK: - Carbon Hotkey Handler (C-level callback)

// Global reference so the C callback can reach the session controller
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
        // ⌥D — Draft mode: capture screenshot SYNCHRONOUSLY before focus shifts
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
        // ⌥Space — Dictation mode: NO screenshot needed (pure voice-to-text)
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
    private var hotkeyRef: EventHotKeyRef?
    private var dictationHotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotkeyChangeObserver: NSObjectProtocol?

    /// Human-readable display strings for current shortcuts (drives MenuBarPanel pills + overlay hints)
    @Published var draftShortcutDisplay: String = HotkeyPreferences.displayString(for: HotkeyPreferences.draftBinding())
    @Published var dictationShortcutDisplay: String = HotkeyPreferences.displayString(for: HotkeyPreferences.dictationBinding())

    /// Non-nil when hotkey registration failed — shown as a dismissible banner in MenuBarPanel
    @Published var hotkeyError: String?

    /// Set by DraftAppDelegate to wire the hotkey to the session controller
    var sessionController: DraftSessionController? {
        didSet {
            _sharedSessionController = sessionController
        }
    }

    func registerHotkey() {
        guard eventHandlerRef == nil else {
            EventReporter.shared.capture(level: .warning, engine: "capture", event: "hotkey_already_registered",
                message: "registerHotkey() called but hotkey already registered — ignoring")
            return
        }

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

        // Register hotkeys from saved preferences (or defaults)
        registerHotkeysFromPreferences()

        // Listen for preference changes (from HotkeyRecorderView)
        hotkeyChangeObserver = NotificationCenter.default.addObserver(
            forName: .hotkeysDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.reRegisterHotkeys()
            }
        }
    }

    /// Unregisters current hotkeys and re-registers with latest preferences.
    /// Preserves the event handler — only the key+modifier bindings change.
    private func reRegisterHotkeys() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let ref = dictationHotkeyRef {
            UnregisterEventHotKey(ref)
            dictationHotkeyRef = nil
        }
        registerHotkeysFromPreferences()
    }

    private func registerHotkeysFromPreferences() {
        let draftBinding = HotkeyPreferences.draftBinding()
        let dictationBinding = HotkeyPreferences.dictationBinding()
        var errors: [String] = []

        // Draft mode — hotkey ID 1
        let draftHotkeyID = EventHotKeyID(signature: OSType(0x44524654), id: 1)  // 'DRFT'
        let draftStatus = RegisterEventHotKey(
            draftBinding.keyCode,
            draftBinding.modifiers,
            draftHotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if draftStatus != noErr {
            errors.append("Draft shortcut")
            EventReporter.shared.capture(level: .error, engine: "capture", event: "hotkey_register_failed",
                message: "Draft hotkey registration failed", context: ["os_status": "\(draftStatus)"])
        }

        // Dictation mode — hotkey ID 2
        let dictationHotkeyID = EventHotKeyID(signature: OSType(0x44524654), id: 2)  // 'DRFT'
        let dictationStatus = RegisterEventHotKey(
            dictationBinding.keyCode,
            dictationBinding.modifiers,
            dictationHotkeyID,
            GetApplicationEventTarget(),
            0,
            &dictationHotkeyRef
        )
        if dictationStatus != noErr {
            errors.append("Dictation shortcut")
            EventReporter.shared.capture(level: .error, engine: "capture", event: "hotkey_register_failed",
                message: "Dictation hotkey registration failed", context: ["os_status": "\(dictationStatus)"])
        }

        // Surface registration failures to the user via MenuBarPanel
        hotkeyError = errors.isEmpty ? nil : "\(errors.joined(separator: " and ")) failed to register"

        // Update display strings
        draftShortcutDisplay = HotkeyPreferences.displayString(for: draftBinding)
        dictationShortcutDisplay = HotkeyPreferences.displayString(for: dictationBinding)
    }

    deinit {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = dictationHotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
        if let observer = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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
        if let observer = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            hotkeyChangeObserver = nil
        }
        _sharedSessionController = nil
    }
}
