import Foundation

/// Where the Transcripted keyboard stands in Input Sources, in the terms the
/// Writing tab's guidance needs. Transcripted-only; Tilde has no equivalent.
///
/// macOS 26 ignores an app's `TISEnableInputSource`: it returns `noErr` and
/// the source stays off. So the user adds the keyboard by hand in Keyboard
/// settings, and a keyboard copied into `~/Library/Input Methods` during this
/// login session isn't listed there until they log out and back in
/// (docs/writing-plan.md, "Permissions").
///
/// Pure and Foundation-only: the app reads Text Input Sources and passes the
/// answers in, so the root fast tests and the Swift Testing suite both use it
/// without touching the real Input Sources.
public enum WritingKeyboardSetupState: Equatable, Sendable {
    /// The keyboard is the current input source. Nothing to do.
    case selected
    /// Added in Input Sources, but another input source is current.
    case enabledNotSelected
    /// Registered but not enabled. The user adds it in Keyboard settings.
    case needsUserToAdd
    /// First copied into `~/Library/Input Methods` during this login
    /// session and not enabled yet. Keyboard settings won't list it until
    /// the user logs out and back in.
    case needsRelogin

    /// Resolves the state from what Text Input Sources reports. `enabled`
    /// and `selected` come from the trusted source only (signed by this
    /// app's team), so an untrusted or unregistered keyboard reads as not
    /// enabled.
    public static func resolve(
        enabled: Bool,
        selected: Bool,
        firstInstalledThisLoginSession: Bool
    ) -> WritingKeyboardSetupState {
        if enabled { return selected ? .selected : .enabledNotSelected }
        return firstInstalledThisLoginSession ? .needsRelogin : .needsUserToAdd
    }

    /// Whether to select the keyboard once, now. Only on the way in: when it
    /// just became enabled after the user added it (the last read said it
    /// still needed adding or a relogin), or on the first read before it was
    /// ever selected. Never after the user picked another input source, so
    /// Transcripted doesn't fight their choice.
    public static func shouldSelect(
        previous: WritingKeyboardSetupState?,
        current: WritingKeyboardSetupState,
        selectedOnce: Bool
    ) -> Bool {
        guard current == .enabledNotSelected else { return false }
        switch previous {
        case .needsUserToAdd?, .needsRelogin?:
            return true
        case nil:
            return !selectedOnce
        case .selected?, .enabledNotSelected?:
            return false
        }
    }

    /// Whether the keyboard was first installed during the current login
    /// session. `recordedSession` is the session saved when the app first
    /// copied the keyboard in; `currentSession` identifies this login. An
    /// unknown current session never claims a relogin is needed.
    public static func firstInstalledThisLoginSession(
        recordedSession: String?,
        currentSession: String?
    ) -> Bool {
        guard let recordedSession, let currentSession, !currentSession.isEmpty else { return false }
        return recordedSession == currentSession
    }
}
