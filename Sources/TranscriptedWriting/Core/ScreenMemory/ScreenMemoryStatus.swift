import Foundation

/// What Tilde's Screen Memory state means for the menu's status line AND,
/// since the 2026-08-16 owner directive, for whether Tilde is allowed to
/// answer a completion request at all. Pure and deterministic so both call
/// sites — `AppDelegate`'s live suggestion gate and `StatusMenuHost`'s
/// status line — read the exact same decision and can never disagree about
/// why suggestions did or didn't fire; before this type existed, that
/// decision was two separately hand-written `guard` chains with no test
/// covering either.
///
/// Owner directive, in full: Screen Recording permission is required for
/// Tilde to suggest at all, not merely to enrich a suggestion with screen
/// context. If the toggle is off, or the permission is missing, Tilde
/// withholds every suggestion — `allowsSuggestions` is `false`. Screen lock
/// and Secure Event Input, by contrast, only ever paused CAPTURE
/// momentarily; they have never blocked suggestions and still don't here
/// (Secure Event Input independently suspends the whole IME anyway,
/// input-method-side, whenever it is active, ahead of anything in this
/// type) — `allowsSuggestions` stays `true` for both capture-paused cases.
public enum ScreenMemoryStatus: Equatable, Sendable {
    /// The user's own master toggle is off. Suggestions are off by the
    /// user's deliberate choice, not by any permission problem.
    case disabled
    /// The toggle is on, but macOS has not granted Screen Recording access.
    /// Suggestions are off because the OS is withholding the permission the
    /// product now requires.
    case noPermission
    /// Enabled and permitted; capture itself is paused because the screen
    /// is locked. Suggestions still flow — there is no active typing
    /// session to suggest into while locked in any case.
    case capturePausedScreenLocked
    /// Enabled and permitted; capture itself is paused because macOS
    /// Secure Event Input is active. Suggestions still flow for ordinary
    /// fields; the IME's own, independent Secure Event Input check already
    /// suspends everything for the field that triggered it.
    case capturePausedSecureInput
    /// Enabled, permitted, and capturing normally.
    case on

    /// Whether Tilde may answer a completion request at all. `false` only
    /// for the two states that mean "the user or the OS withheld the
    /// permission this now requires" — never for a merely momentary capture
    /// pause.
    public var allowsSuggestions: Bool {
        switch self {
        case .disabled, .noPermission: return false
        case .capturePausedScreenLocked, .capturePausedSecureInput, .on: return true
        }
    }

    /// `screenLocked`/`secureInputActive` default to `false`: a caller that
    /// only needs `allowsSuggestions` (e.g. the live suggestion gate) can
    /// omit them, since every combination of those two flags yields the
    /// same `allowsSuggestions` answer once `enabled` and `permissionGranted`
    /// are both true — they only change WHICH true-suggestions case comes
    /// back, never whether suggestions are allowed.
    public static func evaluate(
        enabled: Bool,
        permissionGranted: Bool,
        screenLocked: Bool = false,
        secureInputActive: Bool = false
    ) -> Self {
        guard enabled else { return .disabled }
        guard permissionGranted else { return .noPermission }
        if screenLocked { return .capturePausedScreenLocked }
        if secureInputActive { return .capturePausedSecureInput }
        return .on
    }
}
