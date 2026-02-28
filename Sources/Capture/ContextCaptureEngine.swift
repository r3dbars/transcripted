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
        _sharedSessionController = nil
    }
}
