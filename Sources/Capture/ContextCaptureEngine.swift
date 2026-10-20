// ContextCaptureEngine.swift
// Orchestrates the active capture flows: meeting hotkey + dictation tap handling.

import AppKit
import Combine
import CoreGraphics

// MARK: - Shared Hotkey Routing

// Global shortcut events can fire back-to-back before Transcripted finishes
// updating its session state. Ignore rapid repeats so start/stop/cancel
// transitions stay single-shot and predictable.
// Use systemUptime (monotonic) instead of CFAbsoluteTimeGetCurrent (wall clock)
// so NTP adjustments, manual time changes, or DST transitions can't make a
// backward clock jump silently drop all subsequent hotkey presses.
// Each toggle action has its own bucket; push-to-talk is never debounced
// (see HotkeyActionDebouncer and PhysicalShortcutAction.hotkeyDebounceID).
@MainActor private var hotkeyActionDebouncer = HotkeyActionDebouncer()

@MainActor func shouldAcceptHotkeyAction(
    _ action: PhysicalShortcutAction,
    now: TimeInterval = ProcessInfo.processInfo.systemUptime
) -> Bool {
    hotkeyActionDebouncer.shouldAccept(action, now: now)
}

@MainActor
func dictationSessionStateName(_ session: DictationSessionController?) -> String {
    guard let session else { return "idle" }
    if session.isDictating { return "dictating" }
    return "idle"
}

@MainActor
func overlayStateName(_ state: FloatingOverlayController.OverlayState?) -> String {
    state?.diagnosticName ?? "unknown"
}

// PhysicalShortcutAction and PhysicalShortcutBinding live in
// PhysicalShortcutMatcher.swift. The CGEvent tap is PhysicalShortcutDetector;
// Fn/media-key diagnostics are PhysicalShortcutTapPolicy.

// MARK: - Context Capture Engine

@MainActor
class ContextCaptureEngine: ObservableObject {
    private var hotkeyChangeObserver: NSObjectProtocol?
    private var accessibilityRetryTask: Task<Void, Never>?
    /// The dictation the last hands-free or shared-modifier Push to Talk
    /// press started, so a combo that follows while the key is held can drop it.
    var handsFreePressStartedSessionID: UUID?
    var pushToTalkPressStartedSessionID: UUID?
    /// The held Push to Talk press stopped a hands-free take, so its release
    /// has nothing left to do.
    var pushToTalkPressStoppedTake = false
    private let physicalShortcutDetector = PhysicalShortcutDetector()
    private var physicalTriggerError: String?

    /// Human-readable display strings for current shortcuts (drives MenuBarPanel pills + overlay hints)
    @Published var dictationShortcutDisplay: String = ContextCaptureEngine.currentDictationShortcutDisplay()
    @Published var meetingShortcutDisplay: String = PhysicalDictationTriggerPreferences.displayString(
        for: PhysicalDictationTriggerPreferences.meetingBinding()
    )

    /// Non-nil when hotkey registration failed — shown as a dismissible banner in MenuBarPanel
    @Published var hotkeyError: String?

    /// The exact `hotkeyError` text when the shortcut event tap needs
    /// Accessibility, so the menu bar can offer to open that pane.
    static let accessibilityPermissionErrorMessage = PhysicalShortcutDetector.accessibilityPermissionErrorMessage

    var hotkeyRegistrationError: String? {
        physicalTriggerError
    }

    /// Set by TranscriptedAppDelegate to wire the hotkey to the session controller
    var sessionController: DictationSessionController? {
        didSet { observeDictationActive() }
    }
    private var dictationActiveObservation: AnyCancellable?

    /// Gates shortcut presses to the registered-hotkey window. Physical
    /// shortcut callbacks hop from the CGEventTap thread through a queued
    /// MainActor Task, so a stray press can land after `unregisterHotkey()`
    /// (e.g. during wake recovery) — this flag makes that late arrival a no-op.
    var isHotkeyRoutingActive = false

    /// Closure invoked when the meeting physical trigger fires. Wired by TranscriptedAppDelegate
    /// to `MeetingSessionController.toggleMeeting()` (or equivalent). Nil when
    /// the meeting subsystem is unavailable — the hotkey simply does nothing.
    var onMeetingToggle: (() -> Void)?

    func registerHotkey() {
        guard hotkeyChangeObserver == nil else {
            EventReporter.shared.capture(level: .warning, engine: "capture", event: "hotkey_already_registered",
                message: "registerHotkey() called but hotkey already registered — ignoring")
            return
        }

        // Restore dictation routing after temporary unregister/re-register cycles
        // such as wake recovery.
        isHotkeyRoutingActive = true

        PhysicalDictationTriggerPreferences.migrateToOneDictationKeyIfNeeded()
        refreshShortcutDisplays()
        configurePhysicalShortcutDetector()

        // Listen for preference changes (from the Settings shortcut rows)
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
        // Empty, not "Off": next to "Start Dictation", "Off" read as if
        // dictation itself were turned off.
        guard HotkeyPreferences.dictationShortcutsEnabled() else {
            return ""
        }

        return PhysicalDictationTriggerPreferences.displayString(for: PhysicalDictationTriggerPreferences.pushToTalkBinding())
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
        let bindings = Self.currentShortcutBindings()
        physicalShortcutDetector.updateShortcutBindings(bindings)
        physicalShortcutDetector.onShortcut = { [weak self] action, phase in
            Task { @MainActor [weak self] in
                self?.handlePhysicalShortcut(action, phase: phase)
            }
        }
        // The tap thread hops here: EventReporter is main-actor-only.
        physicalShortcutDetector.onLog = { event, message, context in
            Task { @MainActor in
                EventReporter.shared.capture(
                    level: event == PhysicalShortcutDiagnosticEvent.tapDisabled ? .warning : .info,
                    engine: "capture",
                    event: event,
                    message: message,
                    context: context
                )
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
        } else {
            EventReporter.shared.capture(
                level: .info,
                engine: "capture",
                event: PhysicalShortcutDiagnosticEvent.installed,
                message: "Physical shortcut tap installed",
                context: PhysicalShortcutTapPolicy.installedBindingsContext(bindings)
            )
        }
        updateHotkeyError()
        updateAccessibilityRetryMonitor()
    }

    private static func currentShortcutBindings() -> [PhysicalShortcutBinding] {
        PhysicalShortcutMatcher.configuredBindings()
    }

    private func updateHotkeyError() {
        // One warning at a time: two joined sentences got clipped in the
        // menu bar header. The tap failure comes first; the Fn conflict
        // only matters once shortcuts work at all.
        let dictationShortcutsEnabled = HotkeyPreferences.dictationShortcutsEnabled()
        let nextError = PhysicalShortcutTriggerStatus.bannerMessage(
            registrationError: physicalTriggerError,
            dictationShortcutsEnabled: dictationShortcutsEnabled,
            functionKeyConflictWarning: dictationShortcutsEnabled
                ? PhysicalDictationTriggerPreferences.functionKeyConflictWarning(
                    for: PhysicalDictationTriggerPreferences.pushToTalkBinding()
                )
                : nil
        )
        if hotkeyError != nextError {
            hotkeyError = nextError
        }
    }

    private func updateAccessibilityRetryMonitor() {
        guard PhysicalShortcutTriggerStatus.retriesAfterAccessibilityGrant(registrationError: physicalTriggerError) else {
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
        // Releases and combo drops still run, so a take already started can end.
        if phase == .press, !isHotkeyRoutingActive { return }
        switch (action, phase) {
        case (.dictationPushToTalk, .press):
            handlePhysicalDictationPushToTalkPress()
        case (.dictationPushToTalk, .release):
            handlePhysicalDictationPushToTalkRelease(wasTap: false)
        case (.dictationPushToTalk, .tapRelease):
            handlePhysicalDictationPushToTalkRelease(wasTap: true)
        case (.dictationHandsFree, .press):
            handlePhysicalDictationHandsFreePress()
        case (.dictationHandsFree, .comboInterrupted):
            handlePhysicalDictationHandsFreeComboInterrupted()
        case (.meeting, .press):
            handlePhysicalMeetingPress()
        case (.dictationPushToTalk, .comboInterrupted):
            handlePhysicalDictationPushToTalkComboInterrupted()
        case (.dictationHandsFree, .release), (.meeting, .release), (.meeting, .comboInterrupted),
             (.dictationHandsFree, .tapRelease), (.meeting, .tapRelease):
            break
        }
    }

    /// Keeps the detector's copy of "is a dictation running" current, so a
    /// hands-free press that would stop one waits for release.
    private func observeDictationActive() {
        dictationActiveObservation = sessionController?.$isDictating
            .sink { [weak self] isDictating in
                self?.physicalShortcutDetector.updateDictationActive(isDictating)
            }
        if sessionController == nil {
            physicalShortcutDetector.updateDictationActive(false)
        }
    }

    private func handlePhysicalMeetingPress() {
        guard shouldAcceptHotkeyAction(.meeting) else {
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
        isHotkeyRoutingActive = false
    }
}
