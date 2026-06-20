import Foundation

/// Start-state policy for meeting capture.
///
/// Meeting recordings are only valid once the mic is running, the system-audio
/// file has been created, AND the system-audio tap has actually delivered its
/// first buffer. Returning success on "I/O proc started + file URL assigned"
/// alone can leave a long mic-only recording that later fails in the
/// multichannel pipeline — or, worse, mark a tap that silently never streams as
/// "recording," losing the entire remote side of a call with no recovery (the
/// device-change watchdog is gated on the first buffer and never fires). Gating
/// readiness on `systemAudioStreaming` makes a never-streaming tap stay
/// `.waiting` so it misses the start deadline and fails (the existing
/// start-timeout teardown then stops it) instead of masquerading as recording.
public enum AudioCaptureStartState {
    public enum Outcome: Equatable {
        case waiting
        case ready
        case failed(String)
    }

    public static func meetingCaptureOutcome(
        isRecording: Bool,
        systemAudioFileURL: URL?,
        systemAudioStreaming: Bool,
        errorMessage: String?
    ) -> Outcome {
        if let errorMessage, !errorMessage.isEmpty {
            return .failed(errorMessage)
        }

        if isRecording, systemAudioFileURL != nil, systemAudioStreaming {
            return .ready
        }

        return .waiting
    }

    public static func timeoutFailureMessage(existingErrorMessage: String?) -> String {
        if let existingErrorMessage, !existingErrorMessage.isEmpty {
            return existingErrorMessage
        }

        return "System audio capture did not become ready in time."
    }
}
