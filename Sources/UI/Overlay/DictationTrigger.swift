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

    func pushToTalkPressed() {
        if rememberStartPressIfFinishing(.physicalKey, .pushToTalk) { return }
        guard !isDictating() else { return }
        start(.physicalKey, .pushToTalk)
    }

    func pushToTalkReleased() {
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
