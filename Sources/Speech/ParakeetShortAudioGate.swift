import Foundation

struct ParakeetTranscriptionDecision: Equatable {
    let shouldTranscribe: Bool
    let event: String?
    let message: String?
    let context: [String: String]

    static let transcribe = ParakeetTranscriptionDecision(
        shouldTranscribe: true,
        event: nil,
        message: nil,
        context: [:]
    )
}

enum DictationEmptyTranscriptionReason: String, Equatable {
    case noSpeech = "no_speech"
    case recordingTooShort = "recording_too_short"
    case modelFailure = "model_failure"
    // Capture has measurable speech-like activity, but ASR (including its
    // focused retry) returned no words. This is not proof that speech occurred;
    // it is a reason to retain the WAV for a user-controlled import/retry.
    case audioNeedsRecovery = "audio_needs_recovery"
    // A multilingual model returned text in a writing system none of this
    // person's languages use (DictationLanguageScriptPolicy). Nothing pasted.
    case otherLanguage = "other_language"

    var analyticsEventName: String {
        switch self {
        case .noSpeech:
            return "dictation_no_speech"
        case .recordingTooShort:
            return "dictation_recording_too_short"
        case .modelFailure:
            return "dictation_transcription_failed"
        case .audioNeedsRecovery:
            return "dictation_audio_needs_recovery"
        case .otherLanguage:
            return "dictation_other_language"
        }
    }

    var localEventName: String {
        switch self {
        case .noSpeech:
            return "no_voice_input"
        case .recordingTooShort:
            return "dictation_recording_too_short"
        case .modelFailure:
            return "dictation_transcription_failed"
        case .audioNeedsRecovery:
            return "dictation_audio_needs_recovery"
        case .otherLanguage:
            return "dictation_other_language"
        }
    }

    var localEventMessage: String {
        switch self {
        case .noSpeech:
            return "Dictation transcription empty"
        case .recordingTooShort:
            return "Dictation ended before enough audio was captured"
        case .modelFailure:
            return "Dictation transcription model failed"
        case .audioNeedsRecovery:
            return "Captured dictation audio needs a retry"
        case .otherLanguage:
            return "Dictation came out in a language this Mac doesn't use"
        }
    }

    var frictionFailureKind: String {
        rawValue
    }

    var runtimeOutcome: String {
        switch self {
        case .noSpeech:
            return "no_speech"
        case .recordingTooShort:
            return "recording_too_short"
        case .modelFailure:
            return "model_failure"
        case .audioNeedsRecovery:
            return "audio_needs_recovery"
        case .otherLanguage:
            return "other_language"
        }
    }

    var shouldDiscardStoppedAudioRecovery: Bool {
        // A wrong-language guess on the same audio would come out the same way
        // again through Transcribe It, so there is nothing worth keeping.
        self == .noSpeech || self == .recordingTooShort || self == .otherLanguage
    }

    /// Longest press of the dictation shortcut that can be a mis-tap.
    static let accidentalStartMaximumPress: TimeInterval = 1.5

    /// A dictation released within `accidentalStartMaximumPress` that captured
    /// under a second of audio is a mis-tap of the shortcut, not a failed
    /// dictation. The overlay treats it like a cancel (no error text) and
    /// friction telemetry counts it as `cancelled`, not `give_up`. Its
    /// analytics event name is unchanged so existing counts stay comparable.
    ///
    /// The press length matters: `recordingTooShort` is also what a stalled
    /// microphone produces (no samples after a long press), and that is a real
    /// failure the person needs to see.
    func isAccidentalStart(pressDuration: TimeInterval) -> Bool {
        self == .recordingTooShort
            && pressDuration >= 0
            && pressDuration < Self.accidentalStartMaximumPress
    }
}

enum DictationEmptyInferencePolicy {
    enum RetryOutcome: Equatable {
        case notAttempted
        case empty
        case failed
    }

    static func reason(hasUsableSpeechSignal: Bool) -> DictationEmptyTranscriptionReason {
        // A retry can be unavailable (e.g. focused segment is too short) even
        // when the full recording has usable activity. Do not silently erase
        // that captured audio. Conversely, an empty inference on truly quiet
        // audio remains the ordinary no-speech path.
        return hasUsableSpeechSignal ? .audioNeedsRecovery : .noSpeech
    }
}

enum ParakeetShortAudioGate {
    static func dictation(nativeSampleCount: Int, resampledSampleCount: Int) -> ParakeetTranscriptionDecision {
        guard !TranscriptedConstants.hasMinimumParakeetAudioSamples(resampledSampleCount) else {
            return .transcribe
        }

        let audioDuration = Double(resampledSampleCount) / TranscriptedConstants.parakeetSampleRate
        return ParakeetTranscriptionDecision(
            shouldTranscribe: false,
            event: "recording_too_short",
            message: "Dictation audio too short for transcription",
            context: [
                "native_samples": "\(nativeSampleCount)",
                "samples": "\(resampledSampleCount)",
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "minimum_samples": "\(TranscriptedConstants.parakeetMinimumInferenceSamples)",
            ]
        )
    }

    static func dictationFallback(
        nativeSampleCount: Int,
        resampledSampleCount: Int,
        errorMessage: String
    ) -> ParakeetTranscriptionDecision? {
        // Enough audio means the error is a real model failure, whatever its
        // text says. Reporting it as "too short" discarded a full dictation's
        // audio instead of keeping it for recovery.
        guard !TranscriptedConstants.hasMinimumParakeetAudioSamples(resampledSampleCount),
              shouldTreatFailureAsShortAudio(
                sampleCount: resampledSampleCount,
                errorMessage: errorMessage
              ) else {
            return nil
        }

        return dictation(
            nativeSampleCount: nativeSampleCount,
            resampledSampleCount: resampledSampleCount
        )
    }

    static func meetingSegment(sampleCount: Int, sourceDescription: String) -> ParakeetTranscriptionDecision {
        guard !TranscriptedConstants.hasMinimumParakeetAudioSamples(sampleCount) else {
            return .transcribe
        }

        let audioDuration = Double(sampleCount) / TranscriptedConstants.parakeetSampleRate
        return ParakeetTranscriptionDecision(
            shouldTranscribe: false,
            event: "segment_too_short",
            message: "Skipped short audio segment before Parakeet transcription",
            context: [
                "samples": "\(sampleCount)",
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "minimum_samples": "\(TranscriptedConstants.parakeetMinimumInferenceSamples)",
                "source": sourceDescription,
            ]
        )
    }

    static func meetingSegmentFallback(
        sampleCount: Int,
        sourceDescription: String,
        errorMessage: String
    ) -> ParakeetTranscriptionDecision? {
        guard shouldTreatFailureAsShortAudio(
            sampleCount: sampleCount,
            errorMessage: errorMessage
        ) else {
            return nil
        }

        return meetingSegment(
            sampleCount: sampleCount,
            sourceDescription: sourceDescription
        )
    }

    private static func shouldTreatFailureAsShortAudio(
        sampleCount: Int,
        errorMessage: String
    ) -> Bool {
        if !TranscriptedConstants.hasMinimumParakeetAudioSamples(sampleCount) {
            return true
        }

        let normalized = errorMessage.lowercased()
        return normalized.contains("at least 1 second")
            || normalized.contains("invalid audio data")
            || normalized.contains("recording too short")
            || normalized.contains("too short")
    }
}
