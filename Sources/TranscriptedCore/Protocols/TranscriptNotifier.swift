import Foundation

/// Receives user-facing notifications from TranscriptedCore.
///
/// Core used to call `UNUserNotificationCenter` directly, but that tightly couples the
/// library to AppKit/UserNotifications and assumes a single host app with a single
/// notification category. Instead, Core emits events through this protocol and the
/// embedder decides how to present them (system notification, in-app toast, nothing).
///
/// Passing `nil` at init sites makes all calls no-ops, which is the right behavior for
/// tests and headless embedders. The current in-repository app and CLI hosts do not
/// supply a notifier. This remains a public optional seam for embedders; removing
/// it requires a library-compatibility decision.
@MainActor
public protocol TranscriptNotifier: AnyObject {
    /// Notify the user that a transcript has been written to disk.
    /// - Parameter fileURL: Absolute URL of the saved `.md` file.
    func notifyTranscriptSaved(fileURL: URL)

    /// Notify the user that a transcription attempt failed and has been queued for retry.
    /// - Parameter errorMessage: Human-readable explanation of the failure.
    func notifyTranscriptionFailed(errorMessage: String)

    /// Embedders may request notification permission during setup;
    /// implementations should no-op on subsequent calls.
    func requestNotificationPermission()
}
