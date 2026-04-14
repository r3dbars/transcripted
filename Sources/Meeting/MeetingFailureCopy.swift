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

        if message.contains("recording too short")
            || message.contains("at least")
            || message.contains("invalid audio data") {
            return MeetingFailureCopy(
                title: "Recording was too short",
                detail: "Transcripted needs at least a second of audio. Keep the meeting running a little longer, then retry."
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
