// ContextCaptureEngine.swift
// Orchestrates the active capture flows: meeting hotkey + dictation tap handling.

import AppKit
import Carbon

// MARK: - Carbon Hotkey Handler (C-level callback)

// Global reference so the C callback can reach the dictation controller
private weak var _sharedSessionController: DraftSessionController?

// Global callback for meeting hotkey (id 3). Separate from the session
// controller so meeting UI can be wired independently of draft/dictation.
// Stored on the MainActor and invoked from the Carbon callback via Task.
private var _sharedMeetingToggle: (() -> Void)?

// Carbon hotkeys can fire back-to-back before Draft finishes updating its
// session state. Ignore rapid repeats so start/stop/cancel transitions stay
// single-shot and predictable.
private var _lastAcceptedHotkeyTime: CFAbsoluteTime = 0

private func shouldAcceptHotkeyAction(now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> Bool {
    let elapsed = now - _lastAcceptedHotkeyTime
    guard elapsed >= DraftConstants.hotkeyActionDebounceInterval else { return false }
    _lastAcceptedHotkeyTime = now
    return true
}

@MainActor
private func routeDictationToggle(sourceApp: NSRunningApplication?, trigger: DraftSessionController.DictationTrigger) {
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
    case .streaming: return "streaming"
    case .review: return "review"
    case .diffFlash: return "diff_flash"
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

    if hotkeyID.id == 2 {
        let frontApp = NSWorkspace.shared.frontmostApplication
        Task { @MainActor in
            routeDictationToggle(sourceApp: frontApp, trigger: .keyboardShortcut)
        }
    } else if hotkeyID.id == 3 {
        // ⌥M — Meeting mode: toggle meeting recording.
        // No screenshot, no cross-mode switching with draft/dictation.
        Task { @MainActor in
            _sharedMeetingToggle?()
        }
    }
    return noErr
}

// MARK: - Right Option Tap Detection

/// Detects taps (press + release < 300ms, no other key pressed) on the right Option key.
/// Uses flagsChanged monitors (global + local) to track right Option state, and a keyDown
/// monitor to detect if the user is using right Option as a modifier (hold + press another key).
/// Thread-safe: all state accessed only on MainActor via the ContextCaptureEngine owner.
private final class RightOptionTapDetector {
    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?

    private var rightOptionDownTime: Date?
    private var otherKeyPressed = false

    /// Right Option keyCode (kVK_RightOption = 0x3D = 61)
    private let kRightOptionKeyCode: UInt16 = 61

    /// Maximum hold duration to count as a "tap" for starting dictation.
    private let startTapDuration: TimeInterval = 0.35

    /// While dictation is already active, be more forgiving about how long the
    /// user holds Right Option before releasing to stop.
    var maxTapDurationProvider: (() -> TimeInterval)?

    /// Called on MainActor when a valid right Option tap is detected
    var onTap: (() -> Void)?
    var onInteraction: ((String, [String: String]) -> Void)?

    func install() {
        // --- flagsChanged monitors (detect right Option press/release) ---
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event)
            return event
        }

        // --- keyDown monitors (detect other keys pressed while right Option held) ---
        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            if self?.rightOptionDownTime != nil {
                if self?.otherKeyPressed == false {
                    self?.onInteraction?("right_option_chord_detected", [:])
                }
                self?.otherKeyPressed = true
            }
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if self?.rightOptionDownTime != nil {
                if self?.otherKeyPressed == false {
                    self?.onInteraction?("right_option_chord_detected", [:])
                }
                self?.otherKeyPressed = true
            }
            return event
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == kRightOptionKeyCode else { return }

        let optionDown = event.modifierFlags.contains(.option)

        if optionDown && rightOptionDownTime == nil {
            // Right Option just pressed
            rightOptionDownTime = Date()
            otherKeyPressed = false
            onInteraction?("right_option_pressed", [:])
        } else if !optionDown, let downTime = rightOptionDownTime {
            // Right Option just released — check if it was a tap
            let elapsed = Date().timeIntervalSince(downTime)
            rightOptionDownTime = nil

            let maxTapDuration = maxTapDurationProvider?() ?? startTapDuration
            let accepted = elapsed <= maxTapDuration && !otherKeyPressed
            onInteraction?("right_option_released", [
                "elapsed_ms": "\(Int(elapsed * 1000))",
                "max_tap_ms": "\(Int(maxTapDuration * 1000))",
                "other_key_pressed": "\(otherKeyPressed)",
                "accepted": "\(accepted)"
            ])
            if accepted {
                onTap?()
            }
        }
    }

    func remove() {
        if let m = globalFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = localFlagsMonitor { NSEvent.removeMonitor(m) }
        if let m = globalKeyDownMonitor { NSEvent.removeMonitor(m) }
        if let m = localKeyDownMonitor { NSEvent.removeMonitor(m) }
        globalFlagsMonitor = nil
        localFlagsMonitor = nil
        globalKeyDownMonitor = nil
        localKeyDownMonitor = nil
        rightOptionDownTime = nil
    }
}

// MARK: - Context Capture Engine

@MainActor
class ContextCaptureEngine: ObservableObject {
    private var hotkeyRef: EventHotKeyRef?
    private var meetingHotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotkeyChangeObserver: NSObjectProtocol?
    private let rightOptionDetector = RightOptionTapDetector()

    /// Human-readable display strings for current shortcuts (drives MenuBarPanel pills + overlay hints)
    @Published var dictationShortcutDisplay: String = HotkeyPreferences.rightOptionDictationEnabled() ? "Right ⌥" : HotkeyPreferences.displayString(for: HotkeyPreferences.dictationBinding())
    @Published var meetingShortcutDisplay: String = HotkeyPreferences.displayString(for: HotkeyPreferences.meetingBinding())

    /// Non-nil when hotkey registration failed — shown as a dismissible banner in MenuBarPanel
    @Published var hotkeyError: String?

    /// Set by DraftAppDelegate to wire the hotkey to the session controller
    var sessionController: DraftSessionController? {
        didSet {
            _sharedSessionController = sessionController
        }
    }

    /// Closure invoked when ⌥M (hotkey id 3) fires. Wired by DraftAppDelegate
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

        // Register for kEventHotKeyPressed (dictation fallback + meeting mode)
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

        // Install right Option tap detector for dictation toggle
        rightOptionDetector.maxTapDurationProvider = { [weak self] in
            self?.sessionController?.isDictating == true ? 1.0 : 0.35
        }
        rightOptionDetector.onInteraction = { [weak self] event, context in
            self?.recordRightOptionInteraction(event: event, context: context)
        }
        if HotkeyPreferences.rightOptionDictationEnabled() {
            rightOptionDetector.onTap = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleRightOptionTap()
                }
            }
            rightOptionDetector.install()
        }

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

    /// Unregisters current dictation/meeting hotkeys and re-registers with latest preferences.
    /// Preserves the event handler — only the key+modifier bindings change.
    private func reRegisterHotkeys() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        if let ref = meetingHotkeyRef {
            UnregisterEventHotKey(ref)
            meetingHotkeyRef = nil
        }
        registerHotkeysFromPreferences()

        // Re-evaluate right Option tap detector
        rightOptionDetector.remove()
        rightOptionDetector.maxTapDurationProvider = { [weak self] in
            self?.sessionController?.isDictating == true ? 1.0 : 0.35
        }
        rightOptionDetector.onInteraction = { [weak self] event, context in
            self?.recordRightOptionInteraction(event: event, context: context)
        }
        if HotkeyPreferences.rightOptionDictationEnabled() {
            rightOptionDetector.onTap = { [weak self] in
                Task { @MainActor [weak self] in
                    self?.handleRightOptionTap()
                }
            }
            rightOptionDetector.install()
        }
    }

    private func registerHotkeysFromPreferences() {
        let dictationBinding = HotkeyPreferences.dictationBinding()
        let meetingBinding = HotkeyPreferences.meetingBinding()
        var errors: [String] = []

        // Dictation fallback shortcut — hotkey ID 2
        let dictationHotkeyID = EventHotKeyID(signature: OSType(0x44524654), id: 2)  // 'DRFT'
        let dictationStatus = RegisterEventHotKey(
            dictationBinding.keyCode,
            dictationBinding.modifiers,
            dictationHotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotkeyRef
        )
        if dictationStatus != noErr {
            errors.append("Dictation shortcut")
            EventReporter.shared.capture(level: .error, engine: "capture", event: "hotkey_register_failed",
                message: "Dictation hotkey registration failed", context: ["os_status": "\(dictationStatus)"])
        }

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
            errors.append("Meeting shortcut")
            EventReporter.shared.capture(level: .error, engine: "capture", event: "hotkey_register_failed",
                message: "Meeting hotkey registration failed", context: ["os_status": "\(meetingStatus)"])
        }

        // Surface registration failures to the user via MenuBarPanel
        hotkeyError = errors.isEmpty ? nil : "\(errors.joined(separator: " and ")) failed to register"

        // Update display strings
        dictationShortcutDisplay = HotkeyPreferences.rightOptionDictationEnabled()
            ? "Right ⌥"
            : HotkeyPreferences.displayString(for: HotkeyPreferences.dictationBinding())
        meetingShortcutDisplay = HotkeyPreferences.displayString(for: meetingBinding)
    }

    /// Handles a right Option key tap — same routing as ⌥Space (dictation toggle)
    private func handleRightOptionTap() {
        guard shouldAcceptHotkeyAction() else {
            DiagnosticsTrail.record(
                logger: sessionController?.appState?.logger,
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat dictation tap",
                context: [
                    "hotkey_id": "right_option",
                    "session_state": sessionController?.isDictating == true ? "dictating" : (sessionController?.isInSession == true ? "drafting" : "idle"),
                    "overlay_state": overlayStateName(sessionController?.overlayController?.state)
                ]
            )
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication

        guard let session = sessionController else { return }
        if session.isDictating {
            session.stopDictationAndPaste(trigger: .rightOptionTap)
        } else if session.isInSession {
            session.cancelSession()
            session.startDictation(sourceApp: frontApp, trigger: .rightOptionTap)
        } else {
            session.startDictation(sourceApp: frontApp, trigger: .rightOptionTap)
        }
    }

    private func recordRightOptionInteraction(event: String, context: [String: String]) {
        DiagnosticsTrail.record(
            logger: sessionController?.appState?.logger,
            engine: "capture",
            event: event,
            message: "Right Option dictation interaction",
            context: context.merging([
                "session_state": sessionController?.isDictating == true ? "dictating" : (sessionController?.isInSession == true ? "drafting" : "idle"),
                "overlay_state": overlayStateName(sessionController?.overlayController?.state)
            ]) { current, _ in current }
        )
    }

    deinit {
        if let ref = hotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = meetingHotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
        if let observer = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        rightOptionDetector.remove()
    }

    func unregisterHotkey() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
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
        rightOptionDetector.remove()
        _sharedSessionController = nil
        _sharedMeetingToggle = nil
    }
}
