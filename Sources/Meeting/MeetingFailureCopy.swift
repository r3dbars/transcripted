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
        case .noSpeechDetected:
            return MeetingFailureCopy(
                title: "No speech found",
                detail: "Transcripted found audio, but not enough spoken words to write a transcript."
            )
        case .saveFailed:
            return MeetingFailureCopy(
                title: "Couldn't save the transcript",
                detail: shortErrorMessage
            )
        case .importFileMissing:
            return MeetingFailureCopy(
                title: "Audio file was missing",
                detail: "The file may have moved or been deleted. Choose it again from Finder."
            )
        case .importFileUnreadable:
            return MeetingFailureCopy(
                title: "Can't read that file",
                detail: "Try moving the audio file to a folder you can access, then import it again."
            )
        case .importUnsupportedFile:
            return MeetingFailureCopy(
                title: "Choose an audio file",
                detail: "Transcripted can import common audio files like WAV, MP3, M4A, AAC, and AIFF."
            )
        case .importCopyFailed:
            return MeetingFailureCopy(
                title: "Couldn't prepare the file",
                detail: "Check disk space, then try importing the audio file again."
            )
        case .speakerNameFinalizationFailed,
             .speakerFinalizationFailed:
            return MeetingFailureCopy(
                title: "Couldn't save speaker names",
                detail: "The transcript saved, but the speaker names did not. Try again to rebuild the meeting and save the names."
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
