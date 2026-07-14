import Foundation

/// Start-state policy for meeting capture.
///
/// Meeting recordings are only valid once both source files exist and both the
/// microphone and system-audio taps have actually delivered their first frame.
/// Returning success on "I/O proc started + file URL assigned" alone can leave
/// a header-only mic WAV or a never-streaming system tap while the UI claims to
/// be recording. Both latches keep capture in `.waiting` until the start
/// deadline fails it and tears it down honestly.
public enum AudioCaptureStartState {
    public enum Outcome: Equatable {
        case waiting
        case ready
        case failed(String)
    }

    public static func meetingCaptureOutcome(
        isRecording: Bool,
        micAudioFileURL: URL?,
        micAudioStreaming: Bool,
        systemAudioFileURL: URL?,
        systemAudioStreaming: Bool,
        errorMessage: String?
    ) -> Outcome {
        if let errorMessage, !errorMessage.isEmpty {
            return .failed(errorMessage)
        }

        if isRecording,
           micAudioFileURL != nil,
           micAudioStreaming,
           systemAudioFileURL != nil,
           systemAudioStreaming {
            return .ready
        }

        return .waiting
    }

    public static func timeoutFailureMessage(
        existingErrorMessage: String?,
        micAudioStreaming: Bool,
        systemAudioStreaming: Bool
    ) -> String {
        if let existingErrorMessage, !existingErrorMessage.isEmpty {
            return existingErrorMessage
        }

        if !micAudioStreaming, systemAudioStreaming {
            return "Microphone capture did not become ready in time. Check your input device, then try again."
        }
        if micAudioStreaming, !systemAudioStreaming {
            return "System audio capture did not become ready in time."
        }
        if !micAudioStreaming, !systemAudioStreaming {
            return "Microphone and system audio capture did not become ready in time."
        }

        return "System audio capture did not become ready in time."
    }
}
