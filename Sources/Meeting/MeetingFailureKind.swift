import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum MeetingFailureKind: String {
    case systemAudioPermission = "system_audio_permission"
    case systemAudioPermissionCheckInconclusive = "system_audio_permission_check_inconclusive"
    case microphonePermission = "microphone_permission"
    case microphoneStartFailed = "microphone_start_failed"
    case systemAudioStartFailed = "system_audio_start_failed"
    case meetingAudioStartFailed = "meeting_audio_start_failed"
    case microphoneMissing = "microphone_missing"
    case microphoneAudioUnusable = "microphone_audio_unusable"
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

    /// Maps a typed Core pipeline failure onto this taxonomy. `PipelineErrorKind`
    /// only covers failures that flow through `TranscriptionTaskManager`'s typed
    /// error surface, so this is a total, non-failable mapping over that subset —
    /// it never produces `.unexpectedError`. Meeting-only categories (permission
    /// gates, import preparation, stop timeouts, speaker-name finalization, ...)
    /// have no `PipelineErrorKind` counterpart and stay on the legacy string path.
    init(errorKind: PipelineErrorKind) {
        switch errorKind {
        case .transcriptionAlreadyInProgress:
            self = .pipelineBusy
        case .missingSystemAudio:
            self = .systemAudioPermission
        case .recordingTooShort:
            self = .recordingTooShort
        case .emptyAudioFile:
            self = .emptyAudio
        case .noSpeechDetected:
            self = .noSpeechDetected
        case .invalidAudioFormat:
            self = .invalidAudioFormat
        case .microphoneAudioUnusable:
            self = .microphoneAudioUnusable
        case .saveFailed:
            self = .saveFailed
        case .modelNotLoaded:
            self = .modelNotLoaded
        case .diarizationFailed:
            self = .diarizationFailed
        case .transcriptionInferenceFailed:
            self = .transcriptionInferenceFailed
        case .pipelineFailed:
            self = .pipelineFailed
        }
    }

    /// Preferred entry point once a typed `errorKind` is available (e.g. from
    /// `FailedTranscription.errorKind`). Falls back to legacy string matching
    /// via `classify(message:)` only when `errorKind` is nil — persisted
    /// entries from before typed errors existed, or failures that never had
    /// a `PipelineError` in the first place.
    static func classify(errorKind: PipelineErrorKind?, message: String) -> MeetingFailureKind {
        if let errorKind {
            return MeetingFailureKind(errorKind: errorKind)
        }
        return classify(message: message)
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

    /// Legacy fallback: classifies by keyword matching over a free-form message.
    /// Prefer `classify(errorKind:message:)` when a typed `PipelineErrorKind` is
    /// available. This stays byte-equivalent to the pre-typed-error behavior so
    /// old persisted `FailedTranscription` rows (with `errorKind == nil`) keep
    /// classifying the same way.
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
            "couldn't verify system audio",
            "could not verify system audio",
            "inconclusive access check",
            "system audio recording check unavailable",
        ]) {
            return .systemAudioPermissionCheckInconclusive
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

        // Mid-meeting device loss must be checked before the start-failure
        // wording: the mic watchdog's give-up message ("Audio device
        // unavailable — recording stopped after N recovery attempts…")
        // contains both "unavailable" and "microphone", which the block
        // below would otherwise classify as a start failure and present as
        // "Microphone didn't start".
        if normalized.contains(anyOf: [
            "audio device unavailable",
            "microphone unavailable",
            "microphone recovery failed",
        ]) {
            return .audioDeviceUnavailable
        }

        let describesStartFailure = normalized.contains(anyOf: [
            "didn't start",
            "couldn't start",
            "could not start",
            "did not become ready",
            "unavailable",
        ])
        if describesStartFailure,
           normalized.contains(anyOf: ["microphone", "mic route", "input device"]) {
            return .microphoneStartFailed
        }
        if describesStartFailure, normalized.contains("system audio") {
            return .systemAudioStartFailed
        }
        if describesStartFailure, normalized.contains("meeting audio") {
            return .meetingAudioStartFailed
        }

        if normalized.contains("no microphone found") {
            return .microphoneMissing
        }

        if normalized.contains(anyOf: [
            "microphone audio was not usable",
            "microphone audio was unusable",
            "microphone artifact had no usable capture signal",
        ]) {
            return .microphoneAudioUnusable
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
