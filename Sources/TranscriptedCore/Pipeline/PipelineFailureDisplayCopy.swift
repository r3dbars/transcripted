// PipelineFailureDisplayCopy.swift
// Per-flow user-facing failure copy keyed by the typed `PipelineErrorKind`
// classification. This table replaced the pair of structurally identical
// string-matching chains that used to re-derive the failure bucket from the
// diagnostic message text inside `TranscriptionTaskManager`.
//
// This file must depend only on `PipelineErrorKind` (Models/FailedTranscription.swift):
// the root fast-test runner compiles it flatly next to
// Tests/PipelineErrorKindContractTests.swift, which pins the full per-kind
// copy table for both flows.

enum PipelineFailureDisplayCopy {

    enum Flow {
        /// Transcribing a user-imported audio/video file.
        case importedAudio
        /// Re-transcribing retained audio beside an already-saved transcript.
        case savedAudioRetranscription
    }

    static func message(for kind: PipelineErrorKind, flow: Flow) -> String {
        let copy = copy(for: kind)
        switch flow {
        case .importedAudio:
            return copy.importedAudio
        case .savedAudioRetranscription:
            return copy.savedAudioRetranscription
        }
    }

    private struct Copy {
        let importedAudio: String
        let savedAudioRetranscription: String
    }

    private static func copy(for kind: PipelineErrorKind) -> Copy {
        switch kind {
        case .transcriptionAlreadyInProgress:
            return Copy(
                importedAudio: "Another transcript is already running. Wait for it to finish, then import the file again.",
                savedAudioRetranscription: "Another transcript is already running. Wait for it to finish, then try again."
            )
        case .recordingTooShort:
            return Copy(
                importedAudio: "That audio file is too short to transcribe. Choose audio that is at least two seconds long.",
                savedAudioRetranscription: "That saved audio is too short to transcribe again."
            )
        case .emptyAudioFile:
            return Copy(
                importedAudio: "That audio file has no readable audio. Choose a different recording and try again.",
                savedAudioRetranscription: "That saved audio has no readable audio. Try another saved recording."
            )
        case .noSpeechDetected:
            return Copy(
                importedAudio: "No speech was found in that audio file. Choose a file with clear spoken audio and try again.",
                savedAudioRetranscription: "No speech was found in that saved audio. Try a recording with clearer spoken audio."
            )
        case .invalidAudioFormat:
            return Copy(
                importedAudio: "Transcripted couldn't read that audio file. Choose a WAV, MP3, M4A, AAC, or AIFF file.",
                savedAudioRetranscription: "Transcripted couldn't read that saved audio. Try another retained recording."
            )
        case .saveFailed:
            return Copy(
                importedAudio: "Transcripted couldn't save the transcript. Check your capture folder and try again.",
                savedAudioRetranscription: "Transcripted couldn't save the transcript. Check your capture folder and try again."
            )
        case .modelNotLoaded:
            return Copy(
                importedAudio: "The local transcription model was not ready. Try again after Models finishes loading.",
                savedAudioRetranscription: "The local transcription model was not ready. Try again after Models finishes loading."
            )
        case .diarizationFailed:
            return Copy(
                importedAudio: "Transcripted couldn't separate speakers in that file. Try importing it again.",
                savedAudioRetranscription: "Transcripted couldn't separate speakers in that saved audio. Try again with the retained recording."
            )
        case .transcriptionInferenceFailed:
            return Copy(
                importedAudio: "The local transcription model couldn't process that file. Try converting it to WAV or M4A and import again.",
                savedAudioRetranscription: "The local transcription model couldn't process that saved audio. Try again, or start a new recording if the retained audio is damaged."
            )
        case .missingSystemAudio, .microphoneAudioUnusable, .pipelineFailed:
            // No kind-specific copy: the old string-matching chains had no
            // branch for these buckets either, so they keep the generic
            // per-flow fallback they always showed.
            return Copy(
                importedAudio: "Transcripted couldn't transcribe that audio file. Try converting it to WAV or M4A and import again.",
                savedAudioRetranscription: "Transcripted couldn't re-transcribe that saved audio. Try again, or start a new recording if the retained audio is damaged."
            )
        }
    }
}
