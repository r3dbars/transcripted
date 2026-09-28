import CoreGraphics
import Foundation

/// The one TCC gate Screen Memory needs: macOS Screen Recording permission.
/// Every check here is graceful — nothing in this file blocks or crashes if
/// the user has never been asked, has denied, or revokes access later. The
/// service that calls this is expected to treat "not granted" exactly like
/// "feature off": no capture attempted, status line says why.
enum ScreenRecordingPermission {
    /// Non-prompting check. Safe to call on every trigger — this is how the
    /// service decides whether it's even worth trying to capture.
    static func isGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Prompts the system TCC dialog the first time it's called for this
    /// app; a no-op (returns the current state, no dialog) once the user has
    /// already answered. Does not block for the answer — macOS grants access
    /// asynchronously and `isGranted()` reflects it on a later check.
    @discardableResult
    static func request() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Deep link into System Settings' Screen Recording pane, for the case
    /// where the user previously denied and the system prompt will not
    /// reappear — mirrors the same
    /// `x-apple.systempreferences:` pattern GhostKeyboardInstallerHost uses
    /// for the Keyboard pane.
    static let systemSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
    )!
}
