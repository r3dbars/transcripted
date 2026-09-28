import Foundation

/// Keeps the Mac from napping or idle-sleeping while a transcription job
/// runs. Capture holds its own activity while recording, but nothing did
/// after Stop, so App Nap could throttle a menu bar app with no window open
/// and idle sleep could pause a long job. Closing the lid still sleeps.
enum TranscriptionJobActivity {
    static func keepingMacAwake<T>(
        reason: String = "Transcribing a meeting",
        _ body: () async throws -> T
    ) async rethrows -> T {
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated], reason: reason)
        defer { ProcessInfo.processInfo.endActivity(activity) }
        return try await body()
    }
}
