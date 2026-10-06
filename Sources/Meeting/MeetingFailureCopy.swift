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
                title: "Allow call audio",
                detail: "Turn on System Audio Recording for Transcripted, then try again."
            )
        case .systemAudioPermissionCheckInconclusive:
            return MeetingFailureCopy(
                title: "Can't check call audio access",
                detail: "Try again. If it keeps failing, check System Audio Recording in System Settings."
            )
        case .microphonePermission:
            return MeetingFailureCopy(
                title: "Allow the mic",
                detail: "Turn on Microphone for Transcripted in System Settings, then try again."
            )
        case .microphoneStartFailed:
            return MeetingFailureCopy(
                title: "Mic didn't start",
                detail: "Check your mic, then try again."
            )
        case .systemAudioStartFailed:
            return MeetingFailureCopy(
                title: "Call audio didn't start",
                detail: "Try again. If it keeps happening, quit and reopen Transcripted."
            )
        case .meetingAudioStartFailed:
            return MeetingFailureCopy(
                title: "Audio didn't start",
                detail: "Check your mic and speakers, then try again."
            )
        case .microphoneAudioUnusable:
            return MeetingFailureCopy(
                title: "Your mic recorded nothing",
                detail: "The call audio is saved. Try again to transcribe it, and check your mic before the next meeting."
            )
        case .recordingTooShort:
            // TranscriptionTaskManager.recordingTooShortCaptureStoppedEarlyMessage:
            // the session ran longer than a tap, so something did break.
            if message.contains("capture stopped early") {
                return MeetingFailureCopy(
                    title: "Recording ended too soon",
                    detail: "Recording stopped early. Check your mic and try again."
                )
            }
            return MeetingFailureCopy(
                title: "Recording ended too soon",
                detail: "Record at least 2 seconds before you stop."
            )
        case .emptyAudio:
            return MeetingFailureCopy(
                title: "No sound recorded",
                detail: "The recording is saved. Try again from Meetings, or record with mic and call audio on."
            )
        case .noSpeechDetected:
            // Imports and saved-meeting retranscriptions leave no Meetings row to retry
            // from, so they keep their own flow-specific copy instead of the pointer.
            // These match PipelineFailureDisplayCopy's noSpeechDetected messages;
            // MeetingFailureCopyTests reads them from that table, so a wording
            // change there fails the test instead of silently losing the match.
            if message.contains("that saved audio") || message.contains("that audio file") {
                return MeetingFailureCopy(title: "No speech found", detail: shortErrorMessage)
            }
            return MeetingFailureCopy(
                title: "No speech found",
                detail: "The audio is saved but has no words. If people talked, try again from Meetings."
            )
        case .saveFailed:
            return MeetingFailureCopy(
                title: "Couldn't save the transcript",
                detail: shortErrorMessage
            )
        case .languageNeedsWhisperModel:
            return MeetingFailureCopy(
                title: "Choose a Whisper model",
                detail: "This meeting was saved with a language choice the selected model can't use. Pick a Whisper model under Model in Settings > General, then retry."
            )
        case .importFileMissing:
            return MeetingFailureCopy(
                title: "Audio file was missing",
                detail: "The file may have moved or been deleted. Choose it again from Finder."
            )
        case .importFileUnreadable:
            return MeetingFailureCopy(
                title: "Can't read that file",
                detail: "Try moving the recording to a folder you can access, then import it again."
            )
        case .importUnsupportedFile:
            return MeetingFailureCopy(
                title: "Choose a recording with audio",
                detail: "Transcripted can import common audio files plus MP4 or MOV recordings with an audio track."
            )
        case .importCopyFailed:
            return MeetingFailureCopy(
                title: "Couldn't prepare the file",
                detail: "Check disk space, then try importing the recording again."
            )
        case .speakerNameFinalizationFailed,
             .speakerFinalizationFailed:
            return MeetingFailureCopy(
                title: "Couldn't save speaker names",
                detail: "The transcript saved, but the speaker names did not. Try again to rebuild the meeting and save the names."
            )
        case .stopTimeout:
            return MeetingFailureCopy(
                title: "Recording may be cut off",
                detail: "Try again to transcribe what was saved, or delete it."
            )
        case .savedBeforeQuit:
            return MeetingFailureCopy(
                title: "Saved when you quit",
                detail: "The audio is safe. Finish it from Meetings."
            )
        case .audioDeviceUnavailable:
            return MeetingFailureCopy(
                title: "Mic disconnected",
                detail: "It dropped mid-meeting. Reconnect it, then try again."
            )
        case .microphoneMissing:
            return MeetingFailureCopy(
                title: "No mic found",
                detail: "Connect a mic or pick one in System Settings > Sound."
            )
        case .invalidAudioFormat:
            return MeetingFailureCopy(
                title: "Couldn't read the recording",
                detail: "Try again from Meetings. If it fails again, the file may be damaged."
            )
        case .modelNotLoaded:
            return MeetingFailureCopy(
                title: "Voice model still loading",
                detail: "Wait a moment, then try again."
            )
        case .modelDownloadFailed:
            return MeetingFailureCopy(
                title: "Voice model didn't download",
                detail: "Check your internet, then try again."
            )
        case .transcriptionInferenceFailed:
            // Core publishes this exact display message for every live
            // transcription throw (TranscriptionTaskManager's publishFailure),
            // whatever the cause, so it must not blame the speech model.
            if message == "transcription failed" {
                return MeetingFailureCopy(
                    title: "Transcription didn't finish",
                    detail: "The audio is saved. Open Meetings to try again."
                )
            }
            return MeetingFailureCopy(
                title: "Transcription didn't finish",
                detail: "Something broke partway. Try again, or quit and reopen Transcripted."
            )
        case .diarizationFailed:
            return MeetingFailureCopy(
                title: "Couldn't tell speakers apart",
                detail: "Try again, or quit and reopen Transcripted."
            )
        case .pipelineBusy:
            return MeetingFailureCopy(
                title: "Transcription didn't start",
                detail: "Another transcript was running. Try again once it finishes."
            )
        case .pipelineFailed:
            return MeetingFailureCopy(
                title: "Transcription didn't finish",
                detail: "Try again. If it keeps happening, quit and reopen Transcripted."
            )
        default:
            // Messages the app writes itself that the classifier leaves
            // unmapped. Matched here instead of in MeetingFailureKind so the
            // analytics kind for these failures doesn't change.
            if message.contains("no meeting audio was") {
                return MeetingFailureCopy(
                    title: "Nothing was recorded",
                    detail: "No meeting audio was saved, so there's nothing to retry. Check your mic and audio devices, then record again."
                )
            }
            if message.contains("didn't close cleanly") {
                return MeetingFailureCopy(
                    title: "Recording may be cut off",
                    detail: "Try again from Meetings to transcribe what was saved."
                )
            }
            if message.contains("recording stopped early") || message.contains("recording stopped unexpectedly") {
                return MeetingFailureCopy(
                    title: "Recording stopped early",
                    detail: "Open the Meetings page to retry the saved audio."
                )
            }
            return MeetingFailureCopy(
                title: isRetryable ? "Something went wrong" : "Recording needs attention",
                detail: shortErrorMessage
            )
        }
    }
}
