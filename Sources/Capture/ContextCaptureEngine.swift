// ContextCaptureEngine.swift
// Orchestrates the active capture flows: meeting hotkey + dictation tap handling.

import AppKit
import CoreGraphics

// MARK: - Shared Hotkey Routing

// Global reference so physical shortcut callbacks can reach the dictation controller.
private weak var _sharedSessionController: DictationSessionController?

// Global shortcut events can fire back-to-back before Transcripted finishes
// updating its session state. Ignore rapid repeats so start/stop/cancel
// transitions stay single-shot and predictable.
// Use systemUptime (monotonic) instead of CFAbsoluteTimeGetCurrent (wall clock)
// so NTP adjustments, manual time changes, or DST transitions can't make a
// backward clock jump silently drop all subsequent hotkey presses.
private var _lastAcceptedHotkeyTimesByAction: [String: TimeInterval] = [:]

private func shouldAcceptHotkeyAction(
    _ actionKey: String,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
) -> Bool {
    let elapsed = now - (_lastAcceptedHotkeyTimesByAction[actionKey] ?? 0)
    guard elapsed >= TranscriptedConstants.hotkeyActionDebounceInterval else { return false }
    _lastAcceptedHotkeyTimesByAction[actionKey] = now
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
            "session_state": dictationSessionStateName(session),
            "overlay_state": overlayStateName(session.overlayController?.state)
        ]
    )
    if session.isDictating {
        session.stopDictationAndPaste(trigger: trigger)
    } else {
        session.startDictation(sourceApp: sourceApp, trigger: trigger)
    }
}

@MainActor
private func dictationSessionStateName(_ session: DictationSessionController?) -> String {
    guard let session else { return "idle" }
    if session.isDictating { return "dictating" }
    return "idle"
}

@MainActor
private func overlayStateName(_ state: FloatingOverlayController.OverlayState?) -> String {
    guard let state else { return "unknown" }
    switch state {
    case .idle: return "idle"
    case .starting: return "starting"
    case .loading: return "loading"
    case .listening: return "listening"
    case .drafting: return "drafting"
    case .success: return "success"
    }
}

// PhysicalShortcutAction and PhysicalShortcutBinding live in
// PhysicalShortcutMatcher.swift so the pure chord-resolution precedence can be
// fast-tested independently of this CGEventTap engine.

private enum PhysicalShortcutPhase {
    case press
    case release
}

private final class PhysicalShortcutDetector {
    /// Cached binding snapshot, rebuilt by ContextCaptureEngine on
    /// .hotkeysDidChange. The event tap runs on a dedicated run loop so
    /// Transcripted main-thread work cannot delay global keyboard delivery.
    private var shortcutBindings: [PhysicalShortcutBinding] = []
    var onShortcut: ((PhysicalShortcutAction, PhysicalShortcutPhase) -> Void)?

    private let stateLock = NSRecursiveLock()
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var tapRunLoop: CFRunLoop?
    private var tapThread: Thread?
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

    func updateShortcutBindings(_ bindings: [PhysicalShortcutBinding]) {
        stateLock.lock()
        shortcutBindings = bindings
        stateLock.unlock()
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
        startTapThread(tap: tap, source: source)
        return nil
    }

    func remove() {
        stateLock.lock()
        let source = runLoopSource
        let eventTap = eventTap
        let tapRunLoop = tapRunLoop
        runLoopSource = nil
        self.eventTap = nil
        self.tapRunLoop = nil
        self.tapThread = nil
        stateLock.unlock()

        if let source {
            CFRunLoopRemoveSource(tapRunLoop ?? CFRunLoopGetMain(), source, .commonModes)
        }
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }
        if let tapRunLoop {
            CFRunLoopStop(tapRunLoop)
        }

        stateLock.lock()
        resetState()
        stateLock.unlock()
    }

    private func startTapThread(tap: CFMachPort, source: CFRunLoopSource) {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            autoreleasepool {
                guard let self else {
                    ready.signal()
                    return
                }

                let runLoop = CFRunLoopGetCurrent()
                self.stateLock.lock()
                self.tapRunLoop = runLoop
                self.stateLock.unlock()

                CFRunLoopAddSource(runLoop, source, .commonModes)
                CGEvent.tapEnable(tap: tap, enable: true)
                ready.signal()
                CFRunLoopRun()
            }
        }
        thread.name = "TranscriptedPhysicalShortcutTap"
        thread.qualityOfService = .userInteractive

        stateLock.lock()
        tapThread = thread
        stateLock.unlock()

        thread.start()
        ready.wait()
    }

    private func resetState() {
        pendingModifierShortcut?.workItem?.cancel()
        pendingModifierShortcut = nil
        activePushToTalkKeyCode = nil
        consumedKeyCodes.removeAll()
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        stateLock.lock()
        defer { stateLock.unlock() }

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reconcileActivePushToTalkAfterTapDisabled()
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let shortcutBindings = self.shortcutBindings
        guard !shortcutBindings.isEmpty else {
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
            case .pasteLastDictation:
                onShortcut?(.pasteLastDictation, .press)
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
            case .pasteLastDictation:
                if hasChordUsingModifier(keyCode, in: shortcutBindings, excluding: shortcut.action) {
                    schedulePendingModifierShortcut(keyCode: keyCode, action: .pasteLastDictation)
                } else {
                    cancelPendingModifierShortcut()
                    onShortcut?(.pasteLastDictation, .press)
                }
            }
            return nil

        default:
            return Unmanaged.passUnretained(event)
        }
    }

    // Chord-resolution matchers live in PhysicalShortcutMatcher so their
    // exact-then-fallback precedence stays Foundation-pure and fast-testable.
    // These thin wrappers keep the detector's call sites unchanged.
    private func matchingKeyDownShortcut(
        _ shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> PhysicalShortcutBinding? {
        PhysicalShortcutMatcher.matchingKeyDownShortcut(shortcuts, keyCode: keyCode, modifiers: modifiers)
    }

    private func matchingFlagsChangedPressShortcut(
        _ shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> PhysicalShortcutBinding? {
        PhysicalShortcutMatcher.matchingFlagsChangedPressShortcut(shortcuts, keyCode: keyCode, modifiers: modifiers)
    }

    private func matchesRelease(
        for action: PhysicalShortcutAction,
        in shortcuts: [PhysicalShortcutBinding],
        keyCode: UInt32,
        modifiers: UInt32
    ) -> Bool {
        PhysicalShortcutMatcher.matchesRelease(for: action, in: shortcuts, keyCode: keyCode, modifiers: modifiers)
    }

    private func hasChordUsingModifier(
        _ keyCode: UInt32,
        in shortcuts: [PhysicalShortcutBinding],
        excluding action: PhysicalShortcutAction
    ) -> Bool {
        PhysicalShortcutMatcher.hasChordUsingModifier(keyCode, in: shortcuts, excluding: action)
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

                self.stateLock.lock()
                self.pendingModifierShortcut = nil
                self.activePushToTalkKeyCode = keyCode
                self.stateLock.unlock()
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

    private func reconcileActivePushToTalkAfterTapDisabled() {
        cancelPendingModifierShortcut()

        if PhysicalShortcutMatcher.shouldSynthesizePushToTalkRelease(
            activeKeyCode: activePushToTalkKeyCode,
            isPhysicallyDown: Self.isPhysicalKeyDown
        ), let releasedKeyCode = activePushToTalkKeyCode {
            activePushToTalkKeyCode = nil
            consumedKeyCodes.remove(releasedKeyCode)
            onShortcut?(.dictationPushToTalk, .release)
        }

        consumedKeyCodes = consumedKeyCodes.filter { Self.isPhysicalKeyDown($0) }
    }

    private static func isPhysicalKeyDown(_ keyCode: UInt32) -> Bool {
        if PhysicalDictationTriggerPreferences.isModifierKey(keyCode),
           let modifier = PhysicalDictationTriggerPreferences.primaryModifierMask(for: keyCode) {
            let modifiers = PhysicalDictationTriggerPreferences.modifiers(
                from: CGEventSource.flagsState(.combinedSessionState)
            )
            return (modifiers & modifier) != 0
        }

        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(keyCode))
    }
}

// MARK: - Context Capture Engine

@MainActor
class ContextCaptureEngine: ObservableObject {
    private var hotkeyChangeObserver: NSObjectProtocol?
    private var accessibilityRetryTask: Task<Void, Never>?
    private let physicalShortcutDetector = PhysicalShortcutDetector()
    private var physicalTriggerError: String?

    /// Human-readable display strings for current shortcuts (drives MenuBarPanel pills + overlay hints)
    @Published var dictationShortcutDisplay: String = ContextCaptureEngine.currentDictationShortcutDisplay()
    @Published var meetingShortcutDisplay: String = PhysicalDictationTriggerPreferences.displayString(
        for: PhysicalDictationTriggerPreferences.meetingBinding()
    )

    /// Non-nil when hotkey registration failed — shown as a dismissible banner in MenuBarPanel
    @Published var hotkeyError: String?

    var hotkeyRegistrationError: String? {
        physicalTriggerError
    }

    /// Set by TranscriptedAppDelegate to wire the hotkey to the session controller
    var sessionController: DictationSessionController? {
        didSet {
            _sharedSessionController = sessionController
        }
    }

    /// Closure invoked when the meeting physical trigger fires. Wired by TranscriptedAppDelegate
    /// to `MeetingSessionController.toggleMeeting()` (or equivalent). Nil when
    /// the meeting subsystem is unavailable — the hotkey simply does nothing.
    var onMeetingToggle: (() -> Void)?

    var onPasteLastDictation: (() -> Void)?

    func registerHotkey() {
        guard hotkeyChangeObserver == nil else {
            EventReporter.shared.capture(level: .warning, engine: "capture", event: "hotkey_already_registered",
                message: "registerHotkey() called but hotkey already registered — ignoring")
            return
        }

        // Restore dictation routing after temporary unregister/re-register cycles
        // such as wake recovery.
        _sharedSessionController = sessionController

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
        dictationShortcutDisplay = Self.currentDictationShortcutDisplay()
        meetingShortcutDisplay = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.meetingBinding()
        )
        updateHotkeyError()
    }

    private static func currentDictationShortcutDisplay() -> String {
        guard HotkeyPreferences.dictationShortcutsEnabled() else {
            return "Off"
        }

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
        // Snapshot the bindings once per (re)configure. Every preference write
        // that changes a binding posts .hotkeysDidChange, which routes back
        // here through reRegisterHotkeys(), so the detector's cache never goes
        // stale — and the per-keystroke tap callback stays free of
        // UserDefaults reads and migration-fallback work.
        physicalShortcutDetector.updateShortcutBindings(Self.currentShortcutBindings())
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
                    "dictation_shortcuts_enabled": HotkeyPreferences.dictationShortcutsEnabled() ? "true" : "false",
                    "meeting": PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.meetingBinding())
                ]
            )
        }
        updateHotkeyError()
        updateAccessibilityRetryMonitor()
    }

    private static func currentShortcutBindings() -> [PhysicalShortcutBinding] {
        var bindings = [
            PhysicalShortcutBinding(
                action: .meeting,
                binding: PhysicalDictationTriggerPreferences.meetingBinding()
            ),
            PhysicalShortcutBinding(
                action: .pasteLastDictation,
                binding: PhysicalDictationTriggerPreferences.pasteLastDictationBinding()
            )
        ]

        guard HotkeyPreferences.dictationShortcutsEnabled() else {
            return bindings
        }

        bindings.insert(
            PhysicalShortcutBinding(
                action: .dictationPushToTalk,
                binding: PhysicalDictationTriggerPreferences.pushToTalkBinding()
            ),
            at: 0
        )
        bindings.insert(
            PhysicalShortcutBinding(
                action: .dictationHandsFree,
                binding: PhysicalDictationTriggerPreferences.handsFreeBinding()
            ),
            at: 1
        )
        return bindings
    }

    private func updateHotkeyError() {
        let errors = [
            physicalTriggerError,
            HotkeyPreferences.dictationShortcutsEnabled()
                ? PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                    for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
                )
                : nil
        ].compactMap { $0 }
        let nextError = errors.isEmpty ? nil : errors.joined(separator: " and ")
        if hotkeyError != nextError {
            hotkeyError = nextError
        }
    }

    private func updateAccessibilityRetryMonitor() {
        guard physicalTriggerError == "Shortcut trigger needs Accessibility permission" else {
            accessibilityRetryTask?.cancel()
            accessibilityRetryTask = nil
            return
        }

        guard accessibilityRetryTask == nil else { return }
        accessibilityRetryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard TranscriptedPermissionAccess.isGranted(.accessibility) else { continue }
                self.accessibilityRetryTask?.cancel()
                self.accessibilityRetryTask = nil
                self.reRegisterHotkeys()
                return
            }
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
        case (.pasteLastDictation, .press):
            handlePhysicalPasteLastDictationPress()
        case (.dictationHandsFree, .release), (.meeting, .release), (.pasteLastDictation, .release):
            break
        }
    }

    private func handlePhysicalDictationHandsFreePress() {
        guard shouldAcceptHotkeyAction("dictation_hands_free") else {
            DiagnosticsTrail.record(
                logger: sessionController?.appState?.logger,
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat hands-free dictation trigger",
                context: [
                    "hotkey_id": "dictation_hands_free",
                    "session_state": dictationSessionStateName(sessionController),
                    "overlay_state": overlayStateName(sessionController?.overlayController?.state)
                ]
            )
            return
        }

        let frontApp = NSWorkspace.shared.frontmostApplication
        routeDictationToggle(sourceApp: frontApp, trigger: .physicalKey)
    }

    private func handlePhysicalDictationPushToTalkPress() {
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
                "session_state": dictationSessionStateName(session),
                "overlay_state": overlayStateName(session.overlayController?.state)
            ]
        )

        guard !session.isDictating else { return }
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
                "session_state": dictationSessionStateName(session),
                "overlay_state": overlayStateName(session.overlayController?.state)
            ]
        )

        guard session.isDictating else { return }
        session.stopDictationAndPaste(trigger: .physicalKey)
    }

    private func handlePhysicalMeetingPress() {
        guard shouldAcceptHotkeyAction("meeting_physical_trigger") else {
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

    private func handlePhysicalPasteLastDictationPress() {
        guard shouldAcceptHotkeyAction("paste_last_dictation_physical_trigger") else {
            EventReporter.shared.capture(
                level: .info,
                engine: "capture",
                event: "hotkey_repeat_ignored",
                message: "Ignored rapid repeat paste-last-dictation trigger",
                context: ["hotkey_id": "paste_last_dictation_physical_trigger"]
            )
            return
        }

        onPasteLastDictation?()
    }

    deinit {
        if let observer = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        physicalShortcutDetector.remove()
    }

    func unregisterHotkey() {
        accessibilityRetryTask?.cancel()
        accessibilityRetryTask = nil
        if let observer = hotkeyChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            hotkeyChangeObserver = nil
        }
        physicalShortcutDetector.remove()
        _sharedSessionController = nil
    }
}
