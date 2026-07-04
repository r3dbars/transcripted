import Foundation

enum MeetingFailureKind: String {
    case systemAudioPermission = "system_audio_permission"
    case microphonePermission = "microphone_permission"
    case microphoneMissing = "microphone_missing"
    case audioDeviceUnavailable = "audio_device_unavailable"
    case recordingTooShort = "recording_too_short"
    case emptyAudio = "empty_audio"
    case noSpeechDetected = "no_speech_detected"
    case invalidAudioFormat = "invalid_audio_format"
    case saveFailed = "save_failed"
    case speakerNameFinalizationFailed = "speaker_name_finalization_failed"
    case modelDownloadFailed = "model_download_failed"
    case modelNotLoaded = "model_not_loaded"
    case transcriptionInferenceFailed = "transcription_inference_failed"
    case diarizationFailed = "diarization_failed"
    case speakerFinalizationFailed = "speaker_finalization_failed"
    case importFileMissing = "import_file_missing"
    case importFileUnreadable = "import_file_unreadable"
    case importUnsupportedFile = "import_unsupported_file"
    case importCopyFailed = "import_copy_failed"
    case pipelineBusy = "pipeline_busy"
    case pipelineFailed = "pipeline_failed"
    case savedBeforeQuit = "saved_before_quit"
    case stopTimeout = "stop_timeout"
    case unexpectedError = "unexpected_error"

    var shouldReportAsSkippedTranscript: Bool {
        switch self {
        case .recordingTooShort, .emptyAudio, .noSpeechDetected:
            return true
        default:
            return false
        }
    }

    static func isRecordingTooShortMessage(_ message: String) -> Bool {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let mentionsAudioMinimum = (
            normalized.contains("at least 1 second")
                || normalized.contains("at least 2 seconds")
                || normalized.contains("at least one second")
                || normalized.contains("at least two seconds")
        ) && (normalized.contains("audio") || normalized.contains("recording"))
        let mentionsTooShortAudio = (
            normalized.contains("audio file is too short")
                || normalized.contains("saved audio is too short")
                || normalized.contains("audio is too short")
                || normalized.contains("recording is too short")
                || normalized.contains("too short to transcribe")
        )

        return normalized.contains("recording too short")
            || mentionsTooShortAudio
            || mentionsAudioMinimum
    }

    static func classify(message: String) -> MeetingFailureKind {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains(anyOf: [
            "saved before quit",
            "quit before this meeting could be transcribed",
            "quit before this queued meeting could be transcribed",
            "quit while this meeting was being transcribed",
        ]) {
            return .savedBeforeQuit
        }

        if normalized.contains(anyOf: [
            "stop timed out",
            "recording stop timed out",
        ]) {
            return .stopTimeout
        }

        if normalized.contains(anyOf: [
            "system audio is required",
            "system audio recording",
            "screen recording",
        ]) {
            return .systemAudioPermission
        }

        if normalized.contains(anyOf: [
            "microphone access",
            "microphone access denied",
            "microphone permission",
            "mic_not_authorized",
        ]) {
            return .microphonePermission
        }

        if normalized.contains("no microphone found") {
            return .microphoneMissing
        }

        if normalized.contains(anyOf: [
            "audio device unavailable",
            "microphone unavailable",
            "microphone recovery failed",
        ]) {
            return .audioDeviceUnavailable
        }

        if isRecordingTooShortMessage(normalized) {
            return .recordingTooShort
        }

        if normalized.contains(anyOf: [
            "selected audio file could not be found",
            "file could not be found",
            "moved or deleted",
        ]) {
            return .importFileMissing
        }

        if normalized.contains(anyOf: [
            "couldn't inspect that audio file",
            "couldn't read that audio file",
            "cannot read that audio file",
            "could not read that audio file",
        ]) {
            return .importFileUnreadable
        }

        if normalized.contains(anyOf: [
            "does not look like audio",
            "does not include a readable audio track",
            "choose an audio file",
            "choose an audio or video recording file",
            "not an audio file",
            "unsupported audio",
        ]) {
            return .importUnsupportedFile
        }

        if normalized.contains(anyOf: [
            "couldn't copy that audio file",
            "couldn't copy or extract that recording",
            "could not copy that audio file",
            "working area",
        ]) {
            return .importCopyFailed
        }

        if normalized.contains(anyOf: [
            "invalid audio format",
            "invalid audio data",
        ]) {
            return .invalidAudioFormat
        }

        if normalized.contains(anyOf: [
            "empty audio file",
            "no samples recorded",
            "empty audio",
        ]) {
            return .emptyAudio
        }

        if normalized.contains(anyOf: [
            "no speech detected",
            "no speech was found",
        ]) {
            return .noSpeechDetected
        }

        let mentionsSpeakerNames = normalized.contains("speaker name")
            || normalized.contains("speaker names")
        let mentionsSpeakerNameSaveFailure = mentionsSpeakerNames
            && normalized.contains(anyOf: [
                "couldn't save",
                "couldnt save",
                "could not save",
                "failed to save",
                "save failed",
                "need another pass",
            ])
        if normalized.contains(anyOf: [
            "speaker names could not be saved",
            "speaker-name finalization failed",
        ]) || mentionsSpeakerNameSaveFailure {
            return .speakerNameFinalizationFailed
        }

        if normalized.contains(anyOf: [
            "failed to save",
            "could not write transcript",
        ]) {
            return .saveFailed
        }

        if normalized.contains(anyOf: [
            "transcription already in progress",
        ]) {
            return .pipelineBusy
        }

        if normalized.contains(anyOf: [
            "model not loaded",
            "models were not ready",
            "model failed to load",
            "speech model failed to load",
        ]) {
            return .modelNotLoaded
        }

        if normalized.contains("download") && normalized.contains("model") {
            return .modelDownloadFailed
        }

        if normalized.contains(anyOf: [
            "pyannote",
            "sortformer",
            "wespeaker",
            "diarization",
        ]) {
            return .diarizationFailed
        }

        if normalized.contains(anyOf: [
            "failed to finalize speaker names",
            "speaker naming finalization failed",
        ]) {
            return .speakerFinalizationFailed
        }

        if normalized.contains(anyOf: [
            "asr",
            "core ml",
            "coreml",
            "failed to transcribe",
            "fluid",
            "mlmodel",
            "multiarray",
            "parakeet",
            "prediction",
            "preprocessor",
            "inference failed",
            "transcription failed",
        ]) {
            return .transcriptionInferenceFailed
        }

        if normalized.contains(anyOf: [
            "pipeline failed",
            "pipeline error",
            "retry failed",
            "transcription pipeline",
        ]) {
            return .pipelineFailed
        }

        return .unexpectedError
    }
}

private extension String {
    func contains(anyOf fragments: [String]) -> Bool {
        fragments.contains(where: contains)
    }
}
