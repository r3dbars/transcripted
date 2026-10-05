import Foundation

/// What started (or stopped) a dictation. The raw values are telemetry and
/// diagnostics values, so renaming one silently breaks dashboards and
/// `DictationStartReadinessPolicy.hotkeyTriggerRawValues`.
///
/// Top-level (it used to be nested in `DictationSessionController`) so the
/// fast tests can check those raw values against the real enum.
enum DictationTrigger: String {
    case rightOptionTap = "right_option_tap"
    case physicalKey = "physical_key"
    case keyboardShortcut = "keyboard_shortcut"
    case overlayButton = "overlay_button"
    case menu = "menu"
    case onboarding = "onboarding"
    case sessionCap = "session_cap"
    case unknown = "unknown"
}

/// When a Push to Talk press counts as a tap rather than a hold. With
/// "Tap to keep listening" on, a tap keeps the take going hands-free, so the
/// one key does both (Handy calls this Auto). Under the threshold is well
/// above a real tap (tens of milliseconds, see #1743) and below a deliberate
/// hold. A key typed while it was held makes it a chord (Fn+arrow), never a
/// tap.
enum DictationHoldKeyTapPolicy {
    static let tapThresholdSeconds: TimeInterval = 0.3

    static func isTap(heldSeconds: TimeInterval, otherKeyPressed: Bool) -> Bool {
        !otherKeyPressed && heldSeconds >= 0 && heldSeconds < tapThresholdSeconds
    }
}

/// Turns the physical dictation keys into dictation session commands.
///
/// Every command carries the key action that caused it, so start and stop
/// diagnostics name the real shortcut (Push to Talk or Hands-Free) instead
/// of guessing from the shortcut preference. A press while the last take is
/// still finishing is remembered rather than dropped, and a Push to Talk
/// release before that press could start takes it back.
@MainActor
struct DictationHotkeyRouter {
    var isDictating: @MainActor () -> Bool
    var rememberStartPressIfFinishing: @MainActor (DictationTrigger, DictationShortcutMode) -> Bool
    var dropQueuedPushToTalkStart: @MainActor () -> Bool
    var start: @MainActor (DictationTrigger, DictationShortcutMode) -> Void
    var stop: @MainActor (DictationTrigger, DictationShortcutMode) -> Void
    /// "Tap to keep listening" is on for the Push to Talk key.
    var tapKeepsListening: @MainActor () -> Bool = { false }
    /// A hands-free take is recording (not finishing), so a Push to Talk
    /// press can stop it.
    var isHandsFreeTakeListening: @MainActor () -> Bool = { false }
    var stopHandsFreeTake: @MainActor () -> Void = {}
    /// Takes back a start a tap kept waiting on the last take. False when
    /// there's none.
    var dropQueuedTapKeptStart: @MainActor () -> Bool = { false }
    /// Turns the Push to Talk take (running, or waiting on the last one) into
    /// a hands-free one. False when there's none to keep.
    var keepPushToTalkTakeListening: @MainActor () -> Bool = { false }

    /// What a Push to Talk press did, so its release can follow suit.
    enum PushToTalkPress: Equatable {
        case startedOrIgnored
        /// The press stopped a hands-free take (or took back its waiting
        /// start); its release does nothing.
        case stoppedHandsFreeTake
    }

    @discardableResult
    func pushToTalkPressed() -> PushToTalkPress {
        // A tap kept the last take going: this press ends it, like the
        // hands-free key would. Same for a kept start still waiting.
        if tapKeepsListening() {
            if isHandsFreeTakeListening() {
                stopHandsFreeTake()
                return .stoppedHandsFreeTake
            }
            if dropQueuedTapKeptStart() { return .stoppedHandsFreeTake }
        }
        if rememberStartPressIfFinishing(.physicalKey, .pushToTalk) { return .startedOrIgnored }
        guard !isDictating() else { return .startedOrIgnored }
        start(.physicalKey, .pushToTalk)
        return .startedOrIgnored
    }

    /// `wasTap`: let go quickly with no other key in between
    /// (`DictationHoldKeyTapPolicy`).
    func pushToTalkReleased(wasTap: Bool = false) {
        if wasTap, tapKeepsListening(), keepPushToTalkTakeListening() { return }
        if dropQueuedPushToTalkStart() { return }
        guard isDictating() else { return }
        stop(.physicalKey, .pushToTalk)
    }

    /// The hands-free key: the same key starts and stops. A press after the
    /// take already stopped is handled by the stop path, which asks for the
    /// next take instead.
    func handsFreePressed() {
        if isDictating() {
            stop(.physicalKey, .handsFree)
        } else {
            start(.physicalKey, .handsFree)
        }
    }
}
