import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class TranscriptionPipelineHelpersTests: XCTestCase {

    func testEmbeddingWeightUsesExpectedThresholds() {
        XCTAssertEqual(Transcription.embeddingWeight(forMicFraction: 0.20), 1.0)
        XCTAssertEqual(Transcription.embeddingWeight(forMicFraction: 0.35), 0.5)
        XCTAssertEqual(Transcription.embeddingWeight(forMicFraction: 0.60), 0.2)
        XCTAssertNil(Transcription.embeddingWeight(forMicFraction: 0.85))
    }

    func testAudioCaptureStartStateWaitsForFreshSystemAudioFile() {
        let readyURL = URL(fileURLWithPath: "/tmp/system.wav")

        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                systemAudioFileURL: nil,
                errorMessage: nil
            ),
            .waiting
        )

        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                systemAudioFileURL: readyURL,
                errorMessage: nil
            ),
            .ready
        )

        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                systemAudioFileURL: readyURL,
                errorMessage: "System audio unavailable"
            ),
            .failed("System audio unavailable")
        )
    }

    func testMergeConsecutiveUtterancesMergesSameSpeakerAndPropagatesSpeakerMetadata() {
        let secondSpeakerId = UUID()
        let merged = Transcription.mergeConsecutiveUtterances(
            [
                utterance(start: 0.0, end: 1.0, speakerId: 7, persistentSpeakerId: nil, matchSimilarity: nil, transcript: "Hello"),
                utterance(start: 1.4, end: 2.1, speakerId: 7, persistentSpeakerId: secondSpeakerId, matchSimilarity: 0.82, transcript: "there"),
            ],
            maxGap: 1.5
        )

        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].transcript, "Hello there")
        XCTAssertEqual(merged[0].persistentSpeakerId, secondSpeakerId)
        XCTAssertEqual(merged[0].matchSimilarity ?? 0, 0.82, accuracy: 0.000_1)
    }

    func testMergeConsecutiveUtterancesKeepsSeparateSegmentsAcrossChannelBoundary() {
        let merged = Transcription.mergeConsecutiveUtterances(
            [
                utterance(start: 0.0, end: 1.0, channel: 0, speakerId: 3, transcript: "Mic"),
                utterance(start: 1.1, end: 2.0, channel: 1, speakerId: 3, transcript: "System"),
            ],
            maxGap: 1.5
        )

        XCTAssertEqual(merged.count, 2)
    }

    func testDetectSpeechSegmentsSplitsOnLongSilence() {
        let voiced = [Float](repeating: 0.2, count: 16_000)
        let silence = [Float](repeating: 0.0, count: 8_000)
        let samples = voiced + silence + voiced

        let segments = Transcription.detectSpeechSegments(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 0.02)
        XCTAssertEqual(segments[0].end, 1.0, accuracy: 0.05)
        XCTAssertEqual(segments[1].start, 1.5, accuracy: 0.05)
        XCTAssertEqual(segments[1].end, 2.5, accuracy: 0.05)
    }

    func testDetectSpeechSegmentsFallsBackToWholeTrackForSilentInput() {
        let samples = [Float](repeating: 0.0, count: 16_000)

        let segments = Transcription.detectSpeechSegments(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 0.000_1)
        XCTAssertEqual(segments[0].end, 1.0, accuracy: 0.000_1)
    }

    private func utterance(
        start: Double,
        end: Double,
        channel: Int = 1,
        speakerId: Int,
        persistentSpeakerId: UUID? = nil,
        matchSimilarity: Double? = nil,
        transcript: String
    ) -> TranscriptionUtterance {
        TranscriptionUtterance(
            start: start,
            end: end,
            channel: channel,
            speakerId: speakerId,
            persistentSpeakerId: persistentSpeakerId,
            matchSimilarity: matchSimilarity,
            transcript: transcript
        )
    }
}
