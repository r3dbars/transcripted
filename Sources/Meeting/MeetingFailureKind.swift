import Foundation

enum MeetingFailureKind: String {
    case systemAudioPermission = "system_audio_permission"
    case microphonePermission = "microphone_permission"
    case microphoneMissing = "microphone_missing"
    case audioDeviceUnavailable = "audio_device_unavailable"
    case recordingTooShort = "recording_too_short"
    case emptyAudio = "empty_audio"
    case invalidAudioFormat = "invalid_audio_format"
    case saveFailed = "save_failed"
    case modelDownloadFailed = "model_download_failed"
    case modelNotLoaded = "model_not_loaded"
    case transcriptionInferenceFailed = "transcription_inference_failed"
    case diarizationFailed = "diarization_failed"
    case pipelineBusy = "pipeline_busy"
    case unexpectedError = "unexpected_error"

    static func classify(message: String) -> MeetingFailureKind {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("system audio is required")
            || normalized.contains("system audio recording")
            || normalized.contains("screen recording") {
            return .systemAudioPermission
        }

        if normalized.contains("microphone access denied")
            || normalized.contains("microphone permission")
            || normalized.contains("mic_not_authorized") {
            return .microphonePermission
        }

        if normalized.contains("no microphone found") {
            return .microphoneMissing
        }

        if normalized.contains("audio device unavailable")
            || normalized.contains("microphone unavailable")
            || normalized.contains("microphone recovery failed") {
            return .audioDeviceUnavailable
        }

        if normalized.contains("invalid audio format") {
            return .invalidAudioFormat
        }

        if normalized.contains("recording too short")
            || normalized.contains("invalid audio data")
            || normalized.contains("at least 1 second")
            || normalized.contains("at least 2 seconds") {
            return .recordingTooShort
        }

        if normalized.contains("empty audio file")
            || normalized.contains("no samples recorded")
            || normalized.contains("empty audio") {
            return .emptyAudio
        }

        if normalized.contains("failed to save")
            || normalized.contains("could not write transcript") {
            return .saveFailed
        }

        if normalized.contains("another pipeline is already active") {
            return .pipelineBusy
        }

        if normalized.contains("model not loaded") {
            return .modelNotLoaded
        }

        if normalized.contains("download") && normalized.contains("model") {
            return .modelDownloadFailed
        }

        if normalized.contains("pyannote")
            || normalized.contains("sortformer")
            || normalized.contains("wespeaker")
            || normalized.contains("diarization") {
            return .diarizationFailed
        }

        if normalized.contains("parakeet")
            || normalized.contains("inference failed")
            || normalized.contains("transcription failed") {
            return .transcriptionInferenceFailed
        }

        return .unexpectedError
    }
}
