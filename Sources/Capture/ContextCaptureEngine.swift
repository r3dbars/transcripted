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

private enum PhysicalShortcutAction {
    case dictationPushToTalk
    case dictationHandsFree
    case meeting
}

private enum PhysicalShortcutPhase {
    case press
    case release
}

private struct PhysicalShortcutBinding {
    let action: PhysicalShortcutAction
    let binding: PhysicalDictationTriggerBinding
}

private final class PhysicalShortcutDetector {
    var bindingProvider: (() -> [PhysicalShortcutBinding])?
    var onShortcut: ((PhysicalShortcutAction, PhysicalShortcutPhase) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var activePushToTalkKeyCode: UInt32?
    private var consumedKeyCodes: Set<UInt32> = []
    private var pendingModifierShortcut: PendingModifierShortcut?

    private struct PendingModifierShortcut {
        let keyCode: UInt32
        let action: PhysicalShortcutAction
        let workItem: DispatchWorkItem?
    }

    private static let modifierChordDelay: TimeInterval = 0.14

    private static let callback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passUnretained(event) }
        let detector = Unmanaged<PhysicalShortcutDetector>
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
            resetState()
            return TranscriptedPermissionAccess.isGranted(.accessibility)
                ? "Shortcut trigger failed to start"
                : "Shortcut trigger needs Accessibility permission"
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            resetState()
            return "Shortcut trigger failed to start"
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
        resetState()
    }

    private func resetState() {
        pendingModifierShortcut?.workItem?.cancel()
        pendingModifierShortcut = nil
        activePushToTalkKeyCode = nil
        consumedKeyCodes.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let shortcutBindings = bindingProvider?(), !shortcutBindings.isEmpty else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt32(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = PhysicalDictationTriggerPreferences.modifiers(from: event.flags)

        switch type {
        case .keyDown:
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if isRepeat, consumedKeyCodes.contains(keyCode) {
                return nil
            }

            guard !isRepeat else {
                return Unmanaged.passUnretained(event)
            }

            guard let shortcut = matchingKeyDownShortcut(shortcutBindings, keyCode: keyCode, modifiers: modifiers) else {
                cancelPendingModifierShortcut()
                return Unmanaged.passUnretained(event)
            }

            cancelPendingModifierShortcut()
            consumedKeyCodes.insert(keyCode)

            switch shortcut.action {
            case .dictationPushToTalk:
                guard activePushToTalkKeyCode == nil else { return nil }
                activePushToTalkKeyCode = keyCode
                onShortcut?(.dictationPushToTalk, .press)
            case .dictationHandsFree:
                onShortcut?(.dictationHandsFree, .press)
            case .meeting:
                onShortcut?(.meeting, .press)
            }
            return nil

        case .keyUp:
            if activePushToTalkKeyCode == keyCode {
                activePushToTalkKeyCode = nil
                consumedKeyCodes.remove(keyCode)
                onShortcut?(.dictationPushToTalk, .release)
                return nil
            }

            if consumedKeyCodes.remove(keyCode) != nil {
                return nil
            }

            return Unmanaged.passUnretained(event)

        case .flagsChanged:
            if pendingModifierShortcut?.keyCode == keyCode,
               let pending = pendingModifierShortcut,
               matchesRelease(for: pending.action, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers) {
                cancelPendingModifierShortcut()
                if pending.action != .dictationPushToTalk {
                    onShortcut?(pending.action, .press)
                }
                return nil
            }

            if activePushToTalkKeyCode == keyCode,
               matchesRelease(for: .dictationPushToTalk, in: shortcutBindings, keyCode: keyCode, modifiers: modifiers) {
                activePushToTalkKeyCode = nil
                onShortcut?(.dictationPushToTalk, .release)
                return nil
            }

            guard let shortcut = matchingFlagsChangedPressShortcut(shortcutBindings, keyCode: keyCode, modifiers: modifiers) else {
                return Unmanaged.passUnretained(event)
            }

            switch shortcut.action {
            case .dictationPushToTalk:
                guard activePushToTalkKeyCode == nil else { return nil }
                if hasChordUsingModifier(keyCode, in: shortcutBindings, excluding: shortcut.action) {
                    schedulePendingModifierShortcut(keyCode: keyCode, action: .dictationPushToTalk)
                } else {
                    activePushToTalkKeyCode = keyCode
                    onShortcut?(.dictationPushToTalk, .press)
                }
            case .dictationHandsFree:
                if hasChordUsingModifier(keyCode, in: shortcutBindings, excluding: shortcut.action) {
                    schedulePendingModifierShortcut(keyCode: keyCode, action: .dictationHandsFree)
                } else {
                    cancelPendingModifierShortcut()
                    onShortcut?(.dictationHandsFree, .press)
                }
            case .meeting:
                if hasChordUsingModifier(keyCode, in: shortcutBindings, excluding: shortcut.action) {
                    schedulePendingModifierShortcut(keyCode: keyCode, action: .meeting)
                } else {
                    cancelPendingModifierShortcut()
                    onShortcut?(.meeting, .press)
                }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func matchingKeyDownShortcut(
        _ shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> PhysicalShortcutBinding? {
        shortcuts.first {
            PhysicalDictationTriggerPreferences.matchesKeyDown($0.binding, keyCode: keyCode, modifiers: modifiers)
        }
    }

    private func matchingFlagsChangedPressShortcut(
        _ shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> PhysicalShortcutBinding? {
        if let exact = shortcuts.first(where: {
            $0.binding.keyCode == keyCode
                && PhysicalDictationTriggerPreferences.matchesFlagsChangedPress($0.binding, keyCode: keyCode, modifiers: modifiers)
        }) {
            return exact
        }

        return shortcuts.first {
            PhysicalDictationTriggerPreferences.matchesFlagsChangedPress($0.binding, keyCode: keyCode, modifiers: modifiers)
        }
    }

    private func matchesRelease(
        for action: PhysicalShortcutAction,
        in shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        guard let shortcut = shortcuts.first(where: { $0.action == action }) else { return false }
        return PhysicalDictationTriggerPreferences.matchesFlagsChangedRelease(
            shortcut.binding,
            keyCode: keyCode,
            modifiers: modifiers
        )
    }

    private func hasChordUsingModifier(
        _ keyCode: UInt32,
        in shortcuts: [PhysicalShortcutBinding],
        excluding action: PhysicalShortcutAction
    ) -> Bool {
        guard let modifier = PhysicalDictationTriggerPreferences.primaryModifierMask(for: keyCode) else {
            return false
        }

        return shortcuts.contains {
            $0.action != action
                && !PhysicalDictationTriggerPreferences.isModifierKey($0.binding.keyCode)
                && ($0.binding.modifiers & modifier) != 0
        }
    }

    private func schedulePendingModifierShortcut(keyCode: UInt32, action: PhysicalShortcutAction) {
        cancelPendingModifierShortcut()

        let workItem: DispatchWorkItem?
        if action == .dictationPushToTalk {
            let delayedWorkItem = DispatchWorkItem { [weak self] in
                guard let self,
                      self.pendingModifierShortcut?.keyCode == keyCode,
                      self.pendingModifierShortcut?.action == action else {
                    return
                }

                self.pendingModifierShortcut = nil
                self.activePushToTalkKeyCode = keyCode
                self.onShortcut?(action, .press)
            }
            workItem = delayedWorkItem
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.modifierChordDelay, execute: delayedWorkItem)
        } else {
            workItem = nil
        }

        pendingModifierShortcut = PendingModifierShortcut(
            keyCode: keyCode,
            action: action,
            workItem: workItem
        )
    }

    private func cancelPendingModifierShortcut() {
        pendingModifierShortcut?.workItem?.cancel()
        pendingModifierShortcut = nil
    }
}

// MARK: - Context Capture Engine

@MainActor
class ContextCaptureEngine: ObservableObject {
    private var meetingHotkeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var hotkeyChangeObserver: NSObjectProtocol?
    private let physicalShortcutDetector = PhysicalShortcutDetector()
    private var carbonHotkeyError: String?
    private var physicalTriggerError: String?

    /// Human-readable display strings for current shortcuts (drives MenuBarPanel pills + overlay hints)
    @Published var dictationShortcutDisplay: String = ContextCaptureEngine.currentDictationShortcutDisplay()
    @Published var meetingShortcutDisplay: String = PhysicalDictationTriggerPreferences.displayString(
        for: PhysicalDictationTriggerPreferences.meetingBinding()
    )

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
        guard hotkeyChangeObserver == nil else {
            EventReporter.shared.capture(level: .warning, engine: "capture", event: "hotkey_already_registered",
                message: "registerHotkey() called but hotkey already registered — ignoring")
            return
        }

        // Restore C-callback routing after temporary unregister/re-register cycles
        // such as wake recovery.
        _sharedSessionController = sessionController
        _sharedMeetingToggle = onMeetingToggle

        refreshShortcutDisplays()
        configurePhysicalShortcutDetector()

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
        refreshShortcutDisplays()
        physicalShortcutDetector.remove()
        configurePhysicalShortcutDetector()
    }

    private func refreshShortcutDisplays() {
        carbonHotkeyError = nil
        dictationShortcutDisplay = Self.currentDictationShortcutDisplay()
        meetingShortcutDisplay = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.meetingBinding()
        )
        updateHotkeyError()
    }

    private static func currentDictationShortcutDisplay() -> String {
        let pushToTalk = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
        )
        let handsFree = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.handsFreeBinding()
        )
        return "\(pushToTalk) / \(handsFree)"
    }

    func refreshShortcutStatus() {
        let nextDictationDisplay = Self.currentDictationShortcutDisplay()
        if dictationShortcutDisplay != nextDictationDisplay {
            dictationShortcutDisplay = nextDictationDisplay
        }

        let nextMeetingDisplay = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.meetingBinding()
        )
        if meetingShortcutDisplay != nextMeetingDisplay {
            meetingShortcutDisplay = nextMeetingDisplay
        }

        updateHotkeyError()
    }

    private func configurePhysicalShortcutDetector() {
        physicalShortcutDetector.bindingProvider = {
            [
                PhysicalShortcutBinding(
                    action: .dictationPushToTalk,
                    binding: PhysicalDictationTriggerPreferences.pushToTalkBinding()
                ),
                PhysicalShortcutBinding(
                    action: .dictationHandsFree,
                    binding: PhysicalDictationTriggerPreferences.handsFreeBinding()
                ),
                PhysicalShortcutBinding(
                    action: .meeting,
                    binding: PhysicalDictationTriggerPreferences.meetingBinding()
                )
            ]
        }
        physicalShortcutDetector.onShortcut = { [weak self] action, phase in
            Task { @MainActor [weak self] in
                self?.handlePhysicalShortcut(action, phase: phase)
            }
        }

        physicalTriggerError = physicalShortcutDetector.install()
        if let physicalTriggerError {
            EventReporter.shared.capture(
                level: .warning,
                engine: "capture",
                event: "physical_shortcut_trigger_failed",
                message: physicalTriggerError,
                context: [
                    "push_to_talk": PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.pushToTalkBinding()),
                    "hands_free": PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.handsFreeBinding()),
                    "meeting": PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.meetingBinding())
                ]
            )
        }
        updateHotkeyError()
    }

    private func updateHotkeyError() {
        let errors = [
            carbonHotkeyError,
            physicalTriggerError,
            PhysicalDictationTriggerPreferences.duplicateBindingWarning(),
            PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
            )
        ].compactMap { $0 }
        let nextError = errors.isEmpty ? nil : errors.joined(separator: " and ")
        if hotkeyError != nextError {
            hotkeyError = nextError
        }
    }

    private func handlePhysicalShortcut(_ action: PhysicalShortcutAction, phase: PhysicalShortcutPhase) {
        switch (action, phase) {
        case (.dictationPushToTalk, .press):
            handlePhysicalDictationPushToTalkPress()
        case (.dictationPushToTalk, .release):
            handlePhysicalDictationPushToTalkRelease()
        case (.dictationHandsFree, .press):
            handlePhysicalDictationHandsFreePress()
        case (.meeting, .press):
            handlePhysicalMeetingPress()
        case (.dictationHandsFree, .release), (.meeting, .release):
            break
        }
    }

    private func handlePhysicalDictationHandsFreePress() {
        guard shouldAcceptHotkeyAction() else {
            DiagnosticsTrail.record(
                logger: sessionController?.appState?.logger,
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat hands-free dictation trigger",
                context: [
                    "hotkey_id": "dictation_hands_free",
                    "session_state": sessionController?.isDictating == true ? "dictating" : (sessionController?.isInSession == true ? "drafting" : "idle"),
                    "overlay_state": overlayStateName(sessionController?.overlayController?.state)
                ]
            )
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        routeDictationToggle(sourceApp: frontApp, trigger: .physicalKey)
    }

    private func handlePhysicalDictationPushToTalkPress() {
        guard shouldAcceptHotkeyAction() else {
            DiagnosticsTrail.record(
                logger: sessionController?.appState?.logger,
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat push-to-talk dictation trigger",
                context: [
                    "hotkey_id": "dictation_push_to_talk",
                    "session_state": sessionController?.isDictating == true ? "dictating" : (sessionController?.isInSession == true ? "drafting" : "idle"),
                    "overlay_state": overlayStateName(sessionController?.overlayController?.state)
                ]
            )
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        guard let session = sessionController else { return }
        DiagnosticsTrail.record(
            logger: session.appState?.logger,
            engine: "capture",
            event: "dictation_push_to_talk_pressed",
            message: "Dictation push-to-talk trigger pressed",
            context: [
                "trigger": "physical_key",
                "source_app_name": frontApp?.localizedName ?? "",
                "source_app_bundle_id": frontApp?.bundleIdentifier ?? "",
                "session_state": session.isDictating ? "dictating" : (session.isInSession ? "drafting" : "idle"),
                "overlay_state": overlayStateName(session.overlayController?.state)
            ]
        )

        guard !session.isDictating else { return }
        if session.isInSession {
            session.cancelSession()
        }
        session.startDictation(sourceApp: frontApp, trigger: .physicalKey)
    }

    private func handlePhysicalDictationPushToTalkRelease() {
        guard let session = sessionController else { return }

        DiagnosticsTrail.record(
            logger: session.appState?.logger,
            engine: "capture",
            event: "dictation_push_to_talk_released",
            message: "Dictation push-to-talk trigger released",
            context: [
                "trigger": "physical_key",
                "session_state": session.isDictating ? "dictating" : (session.isInSession ? "drafting" : "idle"),
                "overlay_state": overlayStateName(session.overlayController?.state)
            ]
        )

        guard session.isDictating else { return }
        session.stopDictationAndPaste(trigger: .physicalKey)
    }

    private func handlePhysicalMeetingPress() {
        guard shouldAcceptHotkeyAction() else {
            EventReporter.shared.capture(
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat meeting trigger",
                context: ["hotkey_id": "meeting_physical_trigger"]
            )
            return
        }

        onMeetingToggle?()
    }

    deinit {
        if let ref = meetingHotkeyRef { UnregisterEventHotKey(ref) }
        if let ref = eventHandlerRef { RemoveEventHandler(ref) }
        if let observer = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        physicalShortcutDetector.remove()
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
        physicalShortcutDetector.remove()
        _sharedSessionController = nil
        _sharedMeetingToggle = nil
    }
}
