import Foundation

/// Receives user-facing notifications from TranscriptedCore.
///
/// Core used to call `UNUserNotificationCenter` directly, but that tightly couples the
/// library to AppKit/UserNotifications and assumes a single host app with a single
/// notification category. Instead, Core emits events through this protocol and the
/// embedder decides how to present them (system notification, in-app toast, nothing).
///
/// Passing `nil` at init sites makes all calls no-ops, which is the right behavior for
/// tests and headless embedders. The standalone Transcripted app supplies a concrete
/// `UserNotificationsNotifier` that wraps `UNUserNotificationCenter`.
@MainActor
public protocol TranscriptNotifier: AnyObject {
    /// Notify the user that a transcript has been written to disk.
    /// - Parameter fileURL: Absolute URL of the saved `.md` file.
    func notifyTranscriptSaved(fileURL: URL)

    /// Notify the user that a transcription attempt failed and has been queued for retry.
    /// - Parameter errorMessage: Human-readable explanation of the failure.
    func notifyTranscriptionFailed(errorMessage: String)

    /// Request permission to show notifications. Called once during first-run setup.
    /// Implementations should no-op on subsequent calls.
    func requestNotificationPermission()
}
