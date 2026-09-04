import Foundation

/// Telemetry-sensitive classifier for meeting-recording start failures.
///
/// Maps a raw start-failure message into one of six stable analytics
/// rawValues. These strings are emitted as the `failure_kind` analytics
/// property, so the distinct values must not be collapsed or renamed.
/// This is intentionally separate from `MeetingFailureKind.classify`, which
/// has its own (broader) taxonomy for the transcription pipeline.
enum MeetingStartFailureClassifier {
    static func kind(from message: String, stage: String? = nil) -> String {
        let normalized = message.lowercased()
        if normalized.contains("permission") { return "permission_missing" }
        // Checked before the microphone branch: the core start path names
        // voice processing explicitly when the requested-but-inactive VPIO
        // fallback also failed, and that state must not report as a bare
        // microphone (permission-looking) dead end.
        if normalized.contains("voice processing") { return "voice_processing_unavailable" }
        if normalized.contains("timeout") || normalized.contains("timed out") { return "start_timeout" }
        switch stage {
        case "system_audio":
            return "system_stream_unavailable"
        case "microphone_graph", "microphone_file":
            return "mic_unavailable"
        default:
            break
        }
        if normalized.contains("system audio") { return "system_stream_unavailable" }
        if normalized.contains("microphone") || normalized.contains("mic") { return "mic_unavailable" }
        return "unexpected"
    }
}
