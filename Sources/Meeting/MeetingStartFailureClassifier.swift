import Foundation

/// Telemetry-sensitive classifier for meeting-recording start failures.
///
/// Maps a raw start-failure message into one of five stable analytics
/// rawValues. These strings are emitted as the `failure_kind` analytics
/// property, so the distinct values must not be collapsed or renamed.
/// This is intentionally separate from `MeetingFailureKind.classify`, which
/// has its own (broader) taxonomy for the transcription pipeline.
enum MeetingStartFailureClassifier {
    static func kind(from message: String) -> String {
        let normalized = message.lowercased()
        if normalized.contains("permission") { return "permission_missing" }
        if normalized.contains("timeout") || normalized.contains("timed out") { return "start_timeout" }
        if normalized.contains("system audio") { return "system_stream_unavailable" }
        if normalized.contains("microphone") || normalized.contains("mic") { return "mic_unavailable" }
        return "unexpected"
    }
}
