import Foundation

struct MeetingFailureCopy: Equatable {
    let title: String
    let detail: String

    static func make(
        forMessage errorMessage: String,
        shortErrorMessage: String,
        isRetryable: Bool
    ) -> MeetingFailureCopy {
        let message = errorMessage.lowercased()

        if message.contains("system audio is required")
            || message.contains("system audio recording")
            || message.contains("screen recording") {
            return MeetingFailureCopy(
                title: "Turn on System Audio Recording",
                detail: "Turn on System Audio Recording in System Settings, then retry the meeting."
            )
        }

        if message.contains("microphone access")
            || message.contains("microphone permission")
            || message.contains("mic_not_authorized") {
            return MeetingFailureCopy(
                title: "Turn on Microphone",
                detail: "Turn on Microphone access in System Settings, then retry the meeting."
            )
        }

        if MeetingFailureKind.isRecordingTooShortMessage(message) {
            return MeetingFailureCopy(
                title: "Recording ended too soon",
                detail: "Nothing broke - there just was not enough audio to transcribe. Record at least two seconds before stopping."
            )
        }

        if message.contains("no samples recorded") || message.contains("empty audio") {
            return MeetingFailureCopy(
                title: "No audio was captured",
                detail: "Transcripted kept the recording, but there was not enough audio signal to transcribe."
            )
        }

        if message.contains("failed to save") {
            return MeetingFailureCopy(
                title: "Couldn't save the transcript",
                detail: shortErrorMessage
            )
        }

        return MeetingFailureCopy(
            title: isRetryable ? "Transcript needs another pass" : "Recording needs attention",
            detail: shortErrorMessage
        )
    }
}
