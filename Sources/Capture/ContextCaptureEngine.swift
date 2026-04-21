// ContextCaptureEngine.swift
// Orchestrates the active capture flows: meeting hotkey + dictation tap handling.

import AppKit
import Carbon
import CoreGraphics

// MARK: - Carbon Hotkey Handler (C-level callback)

// Global reference so the C callback can reach the dictation controller
private weak var _sharedSessionController: DictationSessionController?

// Global callback for meeting hotkey (id 3). Separate from the session
// controller so meeting UI can be wired independently of draft/dictation.
// Stored on the MainActor and invoked from the Carbon callback via Task.
private var _sharedMeetingToggle: (() -> Void)?

// Carbon hotkeys can fire back-to-back before Transcripted finishes updating its
// session state. Ignore rapid repeats so start/stop/cancel transitions stay
// single-shot and predictable.
private var _lastAcceptedHotkeyTime: CFAbsoluteTime = 0

private func shouldAcceptHotkeyAction(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
    let elapsed = now - _lastAcceptedHotkeyTime
    guard elapsed >= TranscriptedConstants.hotkeyActionDebounceInterval else { return false }
    _lastAcceptedHotkeyTime = now
    return true
}

@MainActor
private func routeDictationToggle(sourceApp: NSRunningApplication?, trigger: DictationSessionController.DictationTrigger) {
    guard let session = _sharedSessionController else { return }
    DiagnosticsTrail.record(
        logger: session.appState?.logger,
        engine: "capture",
        event: "dictation_toggle_requested",
        message: "Dictation toggle requested",
        context: [
            "trigger": trigger.rawValue,
            "source_app_name": sourceApp?.localizedName ?? "",
            "source_app_bundle_id": sourceApp?.bundleIdentifier ?? "",
            "session_state": session.isDictating ? "dictating" : (session.isInSession ? "drafting" : "idle"),
            "overlay_state": overlayStateName(session.overlayController?.state)
        ]
    )
    if session.isDictating {
        session.stopDictationAndPaste(trigger: trigger)
    } else if session.isInSession {
        session.cancelSession()
        session.startDictation(sourceApp: sourceApp, trigger: trigger)
    } else {
        session.startDictation(sourceApp: sourceApp, trigger: trigger)
    }
}

@MainActor
private func overlayStateName(_ state: FloatingOverlayController.OverlayState?) -> String {
    guard let state else { return "unknown" }
    switch state {
    case .idle: return "idle"
    case .loading: return "loading"
    case .listening: return "listening"
    case .drafting: return "drafting"
    case .success: return "success"
    }
}

private func hotkeyHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
)-> OSStatus {
    // Extract which hotkey fired.
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
    guard shouldAcceptHotkeyAction() else {
        Task { @MainActor in
            EventReporter.shared.capture(
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat hotkey press",
                context: ["hotkey_id": "\(hotkeyID.id)"]
            )
        }
        return noErr
    }

    if hotkeyID.id == 3 {
        // ⌥M — Meeting mode: toggle meeting recording.
        // No screenshot, no cross-mode switching with draft/dictation.
        Task { @MainActor in
            _sharedMeetingToggle?()
        }
    }
    return noErr
}

private final class PhysicalDictationTriggerDetector {
    var bindingProvider: (() -> PhysicalDictationTriggerBinding)?
    var onTrigger: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var triggerDown = false
    private var consumedKeyCode: UInt32?

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let detector = Unmanaged<PhysicalDictationTriggerDetector>
            .fromOpaque(userInfo)
            .takeUnretainedValue()
        return detector.handle(type: type, event: event)
    }

    func install() -> String? {
        remove()

        let eventMask =
            (CGEventMask(1) << CGEventType.keyDown.rawValue) |
            (CGEventMask(1) << CGEventType.keyUp.rawValue) |
            (CGEventMask(1) << CGEventType.flagsChanged.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: Self.callback,
            userInfo: userInfo
        ) else {
            triggerDown = false
            consumedKeyCode = nil
            return TranscriptedPermissionAccess.isGranted(.accessibility)
                ? "Dictation trigger failed to start"
                : "Dictation trigger needs Accessibility permission"
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            triggerDown = false
            consumedKeyCode = nil
            return "Dictation trigger failed to start"
        }

        eventTap = tap
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return nil
    }

    func remove() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        runLoopSource = nil
        eventTap = nil
        triggerDown = false
        consumedKeyCode = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let binding = bindingProvider?() else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = PhysicalDictationTriggerPreferences.modifiers(from: event.flags)

        switch type {
        case .keyDown:
            guard PhysicalDictationTriggerPreferences.matchesKeyDown(binding, keyCode: keyCode, modifiers: modifiers) else {
                return Unmanaged.passUnretained(event)
            }

            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !triggerDown && !isRepeat {
                triggerDown = true
                consumedKeyCode = keyCode
                onTrigger?()
            }
            return nil

        case .keyUp:
            if consumedKeyCode == keyCode {
                triggerDown = false
                consumedKeyCode = nil
                return nil
            }
            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            if binding.keyCode == UInt32(kVK_CapsLock),
               PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(binding, keyCode: keyCode, modifiers: modifiers) {
                onTrigger?()
                return nil
            }

            if PhysicalDictationTriggerPreferences.matchesFlagsChangedPress(binding, keyCode: keyCode, modifiers: modifiers) {
                if !triggerDown {
                    triggerDown = true
                    onTrigger?()
                }
                return nil
            }

            if triggerDown,
               PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(binding, keyCode: keyCode, modifiers: modifiers) {
                triggerDown = false
                return nil
            }

            return Unmanaged.passUnretained(event)

        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

// MARK: - Context Capture Engine

@MainActor
class ContextCaptureEngine: ObservableObject {
    private var meetingHotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotkeyChangeObserver: NSObjectProtocol?
    private let physicalDictationTriggerDetector = PhysicalDictationTriggerDetector()
    private var carbonHotkeyError: String?
    private var physicalTriggerError: String?

    /// Human-readable display strings for current shortcuts (drives MenuBarPanel pills + overlay hints)
    @Published var dictationShortcutDisplay: String = PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.binding())
    @Published var meetingShortcutDisplay: String = HotkeyPreferences.displayString(for: HotkeyPreferences.meetingBinding())

    /// Non-nil when hotkey registration failed — shown as a dismissible banner in MenuBarPanel
    @Published var hotkeyError: String?

    /// Set by TranscriptedAppDelegate to wire the hotkey to the session controller
    var sessionController: DictationSessionController? {
        didSet {
            _sharedSessionController = sessionController
        }
    }

    /// Closure invoked when ⌥M (hotkey id 3) fires. Wired by TranscriptedAppDelegate
    /// to `MeetingSessionController.toggleMeeting()` (or equivalent). Nil when
    /// the meeting subsystem is unavailable — the hotkey simply does nothing.
    var onMeetingToggle: (() -> Void)? {
        didSet {
            _sharedMeetingToggle = onMeetingToggle
        }
    }

    func registerHotkey() {
        guard eventHandlerRef == nil else {
            EventReporter.shared.capture(level: .warning, engine: "capture", event: "hotkey_already_registered",
                message: "registerHotkey() called but hotkey already registered — ignoring")
            return
        }

        // Restore C-callback routing after temporary unregister/re-register cycles
        // such as wake recovery.
        _sharedSessionController = sessionController
        _sharedMeetingToggle = onMeetingToggle

        // Register for kEventHotKeyPressed (meeting mode)
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            hotkeyHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        // Register meeting hotkey from saved preferences (or defaults)
        registerHotkeysFromPreferences()

        configurePhysicalDictationTriggerDetector()

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

    /// Unregisters the current meeting hotkey and re-registers with latest preferences.
    /// Preserves the event handler — only the key+modifier binding changes.
    private func reRegisterHotkeys() {
        if let ref = meetingHotkeyRef {
            UnregisterEventHotKey(ref)
            meetingHotkeyRef = nil
        }
        registerHotkeysFromPreferences()

        // Re-evaluate physical dictation trigger detector.
        physicalDictationTriggerDetector.remove()
        configurePhysicalDictationTriggerDetector()
    }

    private func registerHotkeysFromPreferences() {
        let meetingBinding = HotkeyPreferences.meetingBinding()
        var errors: [String] = []

        // Meeting mode — hotkey ID 3 (Carbon hotkey: modifier + key)
        let meetingHotkeyID = EventHotKeyID(signature: OSType(0x44524654), id: 3)  // 'DRFT'
        let meetingStatus = RegisterEventHotKey(
            meetingBinding.keyCode,
            meetingBinding.modifiers,
            meetingHotkeyID,
            GetApplicationEventTarget(),
            0,
            &meetingHotkeyRef
        )
        if meetingStatus != noErr {
            meetingHotkeyRef = nil
            errors.append("Meeting shortcut")
            EventReporter.shared.capture(level: .error, engine: "capture", event: "hotkey_register_failed",
                message: "Meeting hotkey registration failed", context: ["os_status": "\(meetingStatus)"])
        }

        carbonHotkeyError = errors.isEmpty ? nil : "\(errors.joined(separator: " and ")) failed to register"
        updateHotkeyError()

        // Update display strings
        dictationShortcutDisplay = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.binding()
        )
        meetingShortcutDisplay = HotkeyPreferences.displayString(for: meetingBinding)
    }

    private func configurePhysicalDictationTriggerDetector() {
        physicalDictationTriggerDetector.bindingProvider = {
            PhysicalDictationTriggerPreferences.binding()
        }
        physicalDictationTriggerDetector.onTrigger = { [weak self] in
            Task { @MainActor [weak self] in
                self?.handlePhysicalDictationTrigger()
            }
        }

        physicalTriggerError = physicalDictationTriggerDetector.install()
        if let physicalTriggerError {
            EventReporter.shared.capture(
                level: .warning,
                engine: "capture",
                event: "physical_dictation_trigger_failed",
                message: physicalTriggerError,
                context: [
                    "trigger": PhysicalDictationTriggerPreferences.displayString(
                        for: PhysicalDictationTriggerPreferences.binding()
                    )
                ]
            )
        }
        updateHotkeyError()
    }

    private func updateHotkeyError() {
        let errors = [carbonHotkeyError, physicalTriggerError].compactMap { $0 }
        hotkeyError = errors.isEmpty ? nil : errors.joined(separator: " and ")
    }

    private func handlePhysicalDictationTrigger() {
        guard shouldAcceptHotkeyAction() else {
            DiagnosticsTrail.record(
                logger: sessionController?.appState?.logger,
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat dictation trigger",
                context: [
                    "hotkey_id": "physical_dictation_trigger",
                    "session_state": sessionController?.isDictating == true ? "dictating" : (sessionController?.isInSession == true ? "drafting" : "idle"),
                    "overlay_state": overlayStateName(sessionController?.overlayController?.state)
                ]
            )
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        routeDictationToggle(sourceApp: frontApp, trigger: .physicalKey)
    }

    deinit {
        if let ref = meetingHotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
        if let observer = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        physicalDictationTriggerDetector.remove()
    }

    func unregisterHotkey() {
        if let ref = meetingHotkeyRef {
            UnregisterEventHotKey(ref)
            meetingHotkeyRef = nil
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
        if let observer = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            hotkeyChangeObserver = nil
        }
        physicalDictationTriggerDetector.remove()
        _sharedSessionController = nil
        _sharedMeetingToggle = nil
    }
}
