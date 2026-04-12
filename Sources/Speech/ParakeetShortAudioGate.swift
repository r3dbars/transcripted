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
}
