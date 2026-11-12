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

/// When a Push to Talk press counts as a tap rather than a hold. With the
/// dictation key set to Hold or tap, a tap keeps the take going hands-free,
/// so the one key does both. Under the threshold is well
/// above a real tap (tens of milliseconds, see #1743) and below a deliberate
/// hold. A key typed while it was held makes it a chord (Fn+arrow), never a
/// tap.
enum DictationHoldKeyTapPolicy {
    static let tapThresholdSeconds: TimeInterval = 0.3

    static func isTap(heldSeconds: TimeInterval, otherKeyPressed: Bool) -> Bool {
        release(heldSeconds: heldSeconds, otherKeyPressed: otherKeyPressed) == .tap
    }

    /// Tap, hold, or chord. A chord (another key or modifier went down while
    /// it was held) is still stopped like a hold; it is named apart only so
    /// a too-short take can say which it was.
    static func release(heldSeconds: TimeInterval, otherKeyPressed: Bool) -> DictationKeyRelease {
        if otherKeyPressed { return .chord }
        return heldSeconds >= 0 && heldSeconds < tapThresholdSeconds ? .tap : .hold
    }
}

/// How the dictation key's last release went. The raw values are analytics
/// values (`key_release` on `dictation_recording_too_short`).
enum DictationKeyRelease: String, Equatable {
    case tap
    case hold
    /// Another key or modifier went down while the key was held (Fn+arrow,
    /// Right Option+letter after the chord window).
    case chord
}

/// Coarse, telemetry-safe detail for `dictation_recording_too_short`, so the
/// field can tell a slow tap, a short hold, a chord on the dictation key and
/// a double tap apart. Every value is a fixed enum; nothing is user content.
enum DictationTooShortDiagnostics {
    /// Start request to stop request. The edges sit on the tap threshold
    /// (0.3 s), the minimum audio Parakeet takes (1 s) and the mis-tap limit
    /// (`DictationEmptyTranscriptionReason.accidentalStartMaximumPress`).
    static func pressBucket(seconds: TimeInterval) -> String {
        switch seconds {
        case ..<0.3: return "lt_0_3s"
        case ..<0.6: return "0_3_0_6s"
        case ..<1.0: return "0_6_1s"
        case ..<1.5: return "1_1_5s"
        default: return "1_5s_plus"
        }
    }

    /// `keyRelease` is the dictation key's release during this take, or nil
    /// when no key release reached the take (menu, overlay button, the
    /// hands-free key).
    static func properties(keyRelease: DictationKeyRelease?, pressSeconds: TimeInterval) -> [String: String] {
        [
            "key_release": keyRelease?.rawValue ?? "none",
            "press_bucket": pressBucket(seconds: pressSeconds),
        ]
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
    /// The dictation key's behavior is Hold or tap.
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
