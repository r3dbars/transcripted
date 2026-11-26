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
        // The actual denied-access messages do not all contain "permission".
        // Keep these explicit production phrases ahead of the device/stream
        // branches; a generic capture failure remains a service failure.
        if normalized.contains("permission")
            || normalized.contains("microphone access denied")
            || normalized.contains("system audio recording is off") {
            return "permission_missing"
        }
        // Checked before the microphone branch: the core start path names
        // voice processing explicitly when the requested-but-inactive VPIO
        // fallback also failed, and that state must not report as a bare
        // microphone (permission-looking) dead end.
        if normalized.contains("voice processing") { return "voice_processing_unavailable" }
        if normalized.contains("timeout") || normalized.contains("timed out") { return "start_timeout" }
        switch stage {
        case "system_audio":
            return "system_stream_unavailable"
        case "microphone_graph", "microphone_file", "microphone_tap_raised":
            return "mic_unavailable"
        default:
            break
        }
        if normalized.contains("system audio") { return "system_stream_unavailable" }
        if normalized.contains("microphone") || normalized.contains("mic") { return "mic_unavailable" }
        return "unexpected"
    }
}

/// Decides when a meeting start that failed at the microphone graph/tap stage
/// deserves one bounded retry after a brief CoreAudio settle pause.
///
/// Auto-detected calls often start right as Zoom/Meet/Teams claims the mic and
/// shifts the Bluetooth/CoreAudio route, which can fail a first mic-graph start
/// even when the device is healthy moments later. Permission denials, missing
/// hardware, disk/journal errors, timeouts, and system-audio failures never retry.
enum MeetingStartRetryPolicy {
    static let retrySettleDelayNanoseconds: UInt64 = 400_000_000

    static func shouldRetryTransientMicStartFailure(
        failureKind: String,
        startFailureStage: String,
        message: String,
        explicitSystemAudioPermissionDenialObserved: Bool,
        recordingStartAllowed: Bool
    ) -> Bool {
        guard recordingStartAllowed,
              !explicitSystemAudioPermissionDenialObserved,
              failureKind == "mic_unavailable" else {
            return false
        }
        guard startFailureStage == "microphone_graph" || startFailureStage == "microphone_tap_raised" else {
            return false
        }
        let normalized = message.lowercased()
        let nonRetryablePhrases = [
            "permission",
            "denied",
            "no microphone found",
            "file name",
            "recovery record",
            "disk space",
            "save folder",
            "timed out",
            "timeout",
        ]
        return !nonRetryablePhrases.contains(where: { normalized.contains($0) })
    }
}
