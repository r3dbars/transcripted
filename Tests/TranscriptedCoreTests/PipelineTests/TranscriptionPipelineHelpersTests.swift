import XCTest
import Combine
import FluidAudio
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
                systemAudioStreaming: true,
                errorMessage: nil
            ),
            .waiting
        )

        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                systemAudioFileURL: readyURL,
                systemAudioStreaming: true,
                errorMessage: nil
            ),
            .ready
        )

        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                systemAudioFileURL: readyURL,
                systemAudioStreaming: true,
                errorMessage: "System audio unavailable"
            ),
            .failed("System audio unavailable")
        )
    }

    func testAudioCaptureStartStateWaitsWhenTapHasNotStreamedYet() {
        // The silent-death case: the I/O proc started and a file URL was
        // assigned, but the tap never delivered a buffer. Readiness must stay
        // `.waiting` so the start deadline fails it instead of reporting a tap
        // that is silently writing nothing as "recording".
        XCTAssertEqual(
            AudioCaptureStartState.meetingCaptureOutcome(
                isRecording: true,
                systemAudioFileURL: URL(fileURLWithPath: "/tmp/system.wav"),
                systemAudioStreaming: false,
                errorMessage: nil
            ),
            .waiting
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

    @MainActor
    func testMicDiarizationKeepsWeakGhostSpeakerStandalone() async throws {
        let speakerDB = try temporarySpeakerDatabase()
        var droppedSegments = 0

        let result = try await Transcription.processMicChannelWithDiarization(
            samples: alternatingSamples(amplitude: 0.02, count: 47 * 16_000),
            diarization: PipelineStubDiarizationEngine(segments: [
                speakerSegment(speakerId: 7, start: 0.0, end: 35.0, embedding: [1.0, 0.0], qualityScore: 0.95),
                speakerSegment(speakerId: 6, start: 35.0, end: 47.0, embedding: unitVector(cosineToXAxis: 0.42), qualityScore: 0.20),
            ]),
            parakeet: PipelineStubSpeechToTextEngine(transcript: "spoken words"),
            speakerDB: speakerDB,
            existingProfiles: [],
            droppedSegments: &droppedSegments,
            onProgress: nil
        )

        XCTAssertEqual(droppedSegments, 0)
        XCTAssertEqual(Set(result.utterances.map(\.speakerId)), [6, 7])
        XCTAssertEqual(result.speakerContexts.count, 2)
        XCTAssertEqual(speakerDB.allSpeakers().count, 2)
    }

    @MainActor
    func testMicDiarizationStillMergesStrongGhostSpeakerMatch() async throws {
        let speakerDB = try temporarySpeakerDatabase()
        var droppedSegments = 0

        let result = try await Transcription.processMicChannelWithDiarization(
            samples: alternatingSamples(amplitude: 0.02, count: 47 * 16_000),
            diarization: PipelineStubDiarizationEngine(segments: [
                speakerSegment(speakerId: 7, start: 0.0, end: 35.0, embedding: [1.0, 0.0], qualityScore: 0.95),
                speakerSegment(speakerId: 6, start: 35.0, end: 47.0, embedding: unitVector(cosineToXAxis: 0.78), qualityScore: 0.20),
            ]),
            parakeet: PipelineStubSpeechToTextEngine(transcript: "spoken words"),
            speakerDB: speakerDB,
            existingProfiles: [],
            droppedSegments: &droppedSegments,
            onProgress: nil
        )

        XCTAssertEqual(droppedSegments, 0)
        XCTAssertEqual(Set(result.utterances.map(\.speakerId)), [7])
        XCTAssertEqual(result.speakerContexts.count, 1)
        XCTAssertEqual(speakerDB.allSpeakers().count, 1)
    }

    @MainActor
    func testMicDiarizationKeepsGhostSpeakerStandaloneWhenNoNonGhostTargetExists() async throws {
        let speakerDB = try temporarySpeakerDatabase()
        var droppedSegments = 0

        let result = try await Transcription.processMicChannelWithDiarization(
            samples: alternatingSamples(amplitude: 0.02, count: 24 * 16_000),
            diarization: PipelineStubDiarizationEngine(segments: [
                speakerSegment(speakerId: 6, start: 0.0, end: 12.0, embedding: [1.0, 0.0], qualityScore: 0.20),
                speakerSegment(speakerId: 7, start: 12.0, end: 24.0, embedding: [0.0, 1.0], qualityScore: 0.20),
            ]),
            parakeet: PipelineStubSpeechToTextEngine(transcript: "spoken words"),
            speakerDB: speakerDB,
            existingProfiles: [],
            droppedSegments: &droppedSegments,
            onProgress: nil
        )

        XCTAssertEqual(droppedSegments, 0)
        XCTAssertEqual(Set(result.utterances.map(\.speakerId)), [6, 7])
        XCTAssertEqual(result.speakerContexts.count, 2)
        XCTAssertEqual(speakerDB.allSpeakers().count, 2)
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

    func testDetectSpeechSegmentsFindsAttenuatedSpeechBelowOldFixedThreshold() {
        let voiced = alternatingSamples(amplitude: 0.006, count: 16_000)
        let silence = [Float](repeating: 0.0, count: 8_000)
        let samples = voiced + silence + voiced

        let segments = Transcription.detectSpeechSegments(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(segments.count, 2)
        XCTAssertEqual(segments[0].start, 0.0, accuracy: 0.02)
        XCTAssertEqual(segments[0].end, 1.0, accuracy: 0.05)
        XCTAssertEqual(segments[1].start, 1.5, accuracy: 0.05)
        XCTAssertEqual(segments[1].end, 2.5, accuracy: 0.05)
    }

    func testDetectSpeechSegmentsDoesNotRaiseThresholdAboveLegacyValue() {
        let voiced = alternatingSamples(amplitude: 0.011, count: 16_000)
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

    func testDetectSpeechSegmentsRejectsInvalidSampleRates() {
        let samples = alternatingSamples(amplitude: 0.02, count: 16_000)

        for sampleRate in [Double.nan, Double.infinity, -Double.infinity, 0.0, 7_999.0, 384_001.0] {
            XCTAssertEqual(
                Transcription.detectSpeechSegments(samples: samples, sampleRate: sampleRate).count,
                0
            )
        }
    }

    func testAudioSignalRecoveryNormalizesQuietSpeechCandidate() {
        var samples = [Float](repeating: 0.0, count: 64_000)
        let quietSpeech = alternatingSamples(amplitude: 0.008, count: 24_000)
        samples.replaceSubrange(20_000..<44_000, with: quietSpeech)

        let analysis = AudioSignalRecovery.analyze(samples: samples, sampleRate: 16_000)
        let normalized = AudioSignalRecovery.normalizeForSpeech(
            samples: samples,
            sampleRate: 16_000,
            analysis: analysis
        )

        XCTAssertTrue(analysis.hasSpeechCandidate)
        XCTAssertTrue(normalized.wasNormalized)
        XCTAssertEqual(normalized.samples.count, samples.count)
        XCTAssertGreaterThan(normalized.samples.map(abs).max() ?? 0, analysis.peak)
    }

    func testAudioSignalRecoveryDoesNotNormalizeSilence() {
        let samples = [Float](repeating: 0.0, count: 16_000)

        let analysis = AudioSignalRecovery.analyze(samples: samples, sampleRate: 16_000)
        let normalized = AudioSignalRecovery.normalizeForSpeech(
            samples: samples,
            sampleRate: 16_000,
            analysis: analysis
        )

        XCTAssertFalse(analysis.hasSpeechCandidate)
        XCTAssertFalse(normalized.wasNormalized)
        XCTAssertEqual(normalized.samples, samples)
    }

    func testAudioSignalRecoveryRejectsInvalidSampleRates() {
        let samples = alternatingSamples(amplitude: 0.02, count: 16_000)

        for sampleRate in [Double.nan, Double.infinity, -Double.infinity, 0.0, 7_999.0, 384_001.0] {
            let analysis = AudioSignalRecovery.analyze(samples: samples, sampleRate: sampleRate)

            XCTAssertEqual(analysis.durationSeconds, 0)
            XCTAssertFalse(analysis.hasSpeechCandidate)
        }
    }

    func testAudioSignalRecoveryNormalizesAttenuatedSpeechBelowLegacyGate() {
        // Issue #500 reproduction: WebRTC attenuation in Safari/Firefox can
        // pull mic peaks below the old hasSpeechCandidate gate (peak >= 0.004),
        // and the previous normalizer short-circuited to gain=1.0 on exactly
        // this case. Now we should still apply gain.
        var samples = [Float](repeating: 0.0, count: 64_000)
        let attenuatedSpeech = alternatingSamples(amplitude: 0.002, count: 24_000)
        samples.replaceSubrange(20_000..<44_000, with: attenuatedSpeech)

        let analysis = AudioSignalRecovery.analyze(samples: samples, sampleRate: 16_000)
        let normalized = AudioSignalRecovery.normalizeForSpeech(
            samples: samples,
            sampleRate: 16_000,
            analysis: analysis
        )

        XCTAssertFalse(analysis.hasSpeechCandidate, "Peak 0.002 must remain below the legacy candidate threshold")
        XCTAssertTrue(normalized.wasNormalized, "Attenuated speech should still be amplified")
        XCTAssertGreaterThan(normalized.gain, 1.0)
        XCTAssertLessThanOrEqual(normalized.gain, 12.0)
        XCTAssertGreaterThan(normalized.samples.map(abs).max() ?? 0, analysis.peak)
    }

    func testQuietWebRTCMicSegmentIsPreparedForTranscription() {
        var samples = [Float](repeating: 0.0, count: 64_000)
        let quietSpeech = alternatingSamples(amplitude: 0.006, count: 24_000)
        samples.replaceSubrange(20_000..<44_000, with: quietSpeech)

        let segments = Transcription.detectSpeechSegments(samples: samples, sampleRate: 16_000)
        let prepared = Transcription.prepareMicSegmentForTranscription(
            samples: samples,
            sampleRate: 16_000
        )

        XCTAssertFalse(segments.isEmpty, "Quiet issue #500-style mic speech should still be segmented")
        XCTAssertNotNil(prepared, "Quiet issue #500-style mic speech should still reach Parakeet")
        XCTAssertGreaterThan(prepared?.gain ?? 1, 1, "Prepared mic speech should be normalized before STT")
        XCTAssertGreaterThan(
            prepared?.samples.map(abs).max() ?? 0,
            samples.map(abs).max() ?? 0,
            "Prepared mic speech should be louder than the captured quiet segment"
        )
    }

    func testPrepareMicSegmentPadsShortQuietSpeechForParakeet() {
        let samples = alternatingSamples(amplitude: 0.006, count: 8_000)

        let prepared = Transcription.prepareMicSegmentForTranscription(
            samples: samples,
            sampleRate: 16_000
        )

        XCTAssertNotNil(prepared)
        XCTAssertEqual(prepared?.samples.count, 16_000)
        XCTAssertEqual(prepared?.paddedSampleCount, 8_000)
        XCTAssertGreaterThan(prepared?.gain ?? 1, 1)
    }

    func testPrepareMicSegmentSkipsShortSilenceInsteadOfPaddingNoise() {
        let samples = [Float](repeating: 0.0, count: 8_000)

        let prepared = Transcription.prepareMicSegmentForTranscription(
            samples: samples,
            sampleRate: 16_000
        )

        XCTAssertNil(prepared)
    }

    func testPrepareMicSegmentRejectsInvalidSampleRates() {
        let samples = alternatingSamples(amplitude: 0.02, count: 16_000)

        for sampleRate in [Double.nan, Double.infinity, -Double.infinity, 0.0, 7_999.0, 384_001.0] {
            XCTAssertNil(
                Transcription.prepareMicSegmentForTranscription(samples: samples, sampleRate: sampleRate)
            )
        }
    }

    func testAudioResamplerRejectsUnsafeSliceMath() {
        let samples = [Float](repeating: 0.1, count: 16_000)

        XCTAssertEqual(
            AudioResampler.resample(samples, from: Double.infinity, to: 16_000),
            samples
        )
        XCTAssertEqual(
            AudioResampler.resample(samples, from: 48_000, to: Double.nan),
            samples
        )
        XCTAssertEqual(
            AudioResampler.extractSlice(from: samples, sampleRate: Double.infinity, startTime: 0, endTime: 1),
            []
        )
        XCTAssertEqual(
            AudioResampler.extractSlice(from: samples, sampleRate: 16_000, startTime: Double.nan, endTime: 1),
            []
        )
        XCTAssertEqual(
            AudioResampler.extractSlice(from: samples, sampleRate: 16_000, startTime: 0, endTime: Double.greatestFiniteMagnitude),
            []
        )
    }

    private func alternatingSamples(amplitude: Float, count: Int) -> [Float] {
        (0..<count).map { $0.isMultiple(of: 2) ? amplitude : -amplitude }
    }

    private func unitVector(cosineToXAxis: Float) -> [Float] {
        let y = sqrt(max(0, 1 - (cosineToXAxis * cosineToXAxis)))
        return [cosineToXAxis, y]
    }

    private func speakerSegment(
        speakerId: Int,
        start: Double,
        end: Double,
        embedding: [Float],
        qualityScore: Float
    ) -> SpeakerSegment {
        SpeakerSegment(
            speakerId: speakerId,
            startTime: start,
            endTime: end,
            embedding: embedding,
            qualityScore: qualityScore
        )
    }

    private func temporarySpeakerDatabase() throws -> SpeakerDatabase {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptionPipelineHelpersTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return SpeakerDatabase(path: root.appendingPathComponent("speakers.sqlite").path)
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

@available(macOS 14.0, *)
@MainActor
private final class PipelineStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private let transcript: String

    init(transcript: String) {
        self.transcript = transcript
    }

    func initialize() async {
        isReady = true
    }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        transcript
    }

    func cleanup() {
        isReady = false
    }
}

@available(macOS 14.0, *)
@MainActor
private final class PipelineStubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private let segments: [SpeakerSegment]

    init(segments: [SpeakerSegment]) {
        self.segments = segments
    }

    func initialize() async {
        isReady = true
    }

    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        segments
    }

    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        segments
    }

    func cleanup() {
        isReady = false
    }
}
