import Foundation

struct MeetingFailureCopy: Equatable {
    let title: String
    let detail: String

    static func make(
        forMessage errorMessage: String,
        shortErrorMessage: String,
        isRetryable: Bool
    ) -> MeetingFailureCopy {
        let message = errorMessage.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        switch MeetingFailureKind.classify(message: message) {
        case .systemAudioPermission:
            return MeetingFailureCopy(
                title: "Turn on System Audio Recording",
                detail: "Turn on System Audio Recording in System Settings, then retry the meeting."
            )
        case .microphonePermission:
            return MeetingFailureCopy(
                title: "Turn on Microphone",
                detail: "Turn on Microphone access in System Settings, then retry the meeting."
            )
        case .recordingTooShort:
            return MeetingFailureCopy(
                title: "Recording ended too soon",
                detail: "Nothing broke - there just was not enough audio to transcribe. Record at least two seconds before stopping."
            )
        case .emptyAudio:
            return MeetingFailureCopy(
                title: "No audio was captured",
                detail: "Transcripted kept the recording, but there was not enough audio signal to transcribe."
            )
        case .saveFailed:
            return MeetingFailureCopy(
                title: "Couldn't save the transcript",
                detail: shortErrorMessage
            )
        case .stopTimeout:
            return MeetingFailureCopy(
                title: "Recording didn't close cleanly",
                detail: "The audio files may be incomplete. Retry to transcribe what was captured, or delete to discard."
            )
        default:
            return MeetingFailureCopy(
                title: isRetryable ? "Transcript needs another pass" : "Recording needs attention",
                detail: shortErrorMessage
            )
        }
    }
}
