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
