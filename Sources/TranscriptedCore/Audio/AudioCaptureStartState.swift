import Foundation

/// Start-state policy for meeting capture.
///
/// Meeting recordings are only valid once the mic is running AND the system-audio
/// file has been created. Returning success earlier can leave a long mic-only
/// recording that later fails in the multichannel pipeline.
public enum AudioCaptureStartState {
    public enum Outcome: Equatable {
        case waiting
        case ready
        case failed(String)
    }

    public static func meetingCaptureOutcome(
        isRecording: Bool,
        systemAudioFileURL: URL?,
        errorMessage: String?
    ) -> Outcome {
        if let errorMessage, !errorMessage.isEmpty {
            return .failed(errorMessage)
        }

        if isRecording, systemAudioFileURL != nil {
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
