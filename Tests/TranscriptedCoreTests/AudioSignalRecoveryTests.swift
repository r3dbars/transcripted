import XCTest
@testable import TranscriptedCore

final class AudioSignalRecoveryTests: XCTestCase {

    private func assertNear(_ actual: Float, _ expected: Float, tolerance: Float = 0.001, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(abs(actual - expected) <= tolerance, "\(message) — expected \(expected), got \(actual)", file: file, line: line)
    }

    // MARK: - analyze

    func testAnalyzeReturnsZeroedAnalysisForEmptySamples() {
        let analysis = AudioSignalRecovery.analyze(samples: [], sampleRate: 16_000)

        XCTAssertEqual(analysis.sampleCount, 0)
        XCTAssertEqual(analysis.peak, 0)
        XCTAssertEqual(analysis.rms, 0)
        XCTAssertEqual(analysis.activeRatio, 0)
    }

    func testAnalyzeReturnsZeroedAnalysisForUnusableSampleRate() {
        let analysis = AudioSignalRecovery.analyze(samples: [0.5, -0.5], sampleRate: 0)

        XCTAssertEqual(analysis.sampleCount, 2, "sample count should still be reported even when the rate is unusable")
        XCTAssertEqual(analysis.sampleRate, 0)
        XCTAssertEqual(analysis.peak, 0)
        XCTAssertEqual(analysis.rms, 0)
        XCTAssertEqual(analysis.activeRatio, 0)
    }

    func testAnalyzeTreatsAllZeroSamplesAsSilence() {
        let analysis = AudioSignalRecovery.analyze(samples: [0, 0, 0, 0], sampleRate: 16_000)

        XCTAssertEqual(analysis.peak, 0)
        XCTAssertEqual(analysis.rms, 0)
        XCTAssertEqual(analysis.activeRatio, 0)
        XCTAssertFalse(analysis.hasSpeechCandidate, "pure silence should never look like a speech candidate")
    }

    func testAnalyzeComputesPeakAndFullActiveRatioForUniformLoudSamples() {
        let analysis = AudioSignalRecovery.analyze(samples: [0.1, -0.1, 0.1, -0.1], sampleRate: 16_000)

        XCTAssertEqual(analysis.peak, 0.1)
        XCTAssertEqual(analysis.activeRatio, 1.0, "every sample at peak amplitude should count as active")
        assertNear(analysis.rms, 0.1, tolerance: 0.0001)
    }

    // MARK: - AudioSignalAnalysis derived properties

    func testDurationAndActiveDurationDeriveFromSampleCountAndRate() {
        let analysis = AudioSignalAnalysis(sampleCount: 32_000, sampleRate: 16_000, peak: 0.01, rms: 0.001, activeRatio: 0.5)

        XCTAssertEqual(analysis.durationSeconds, 2.0)
        XCTAssertEqual(analysis.activeDurationSeconds, 1.0)
    }

    func testDurationIsZeroForUnusableSampleRate() {
        let analysis = AudioSignalAnalysis(sampleCount: 32_000, sampleRate: 0, peak: 0.01, rms: 0.001, activeRatio: 0.5)

        XCTAssertEqual(analysis.durationSeconds, 0)
        XCTAssertEqual(analysis.activeDurationSeconds, 0)
    }

    func testHasSpeechCandidateRequiresAllFourGates() {
        let qualifying = AudioSignalAnalysis(sampleCount: 32_000, sampleRate: 16_000, peak: 0.01, rms: 0.001, activeRatio: 0.5)
        XCTAssertTrue(qualifying.hasSpeechCandidate)

        let peakTooLow = AudioSignalAnalysis(sampleCount: 32_000, sampleRate: 16_000, peak: 0.001, rms: 0.001, activeRatio: 0.5)
        XCTAssertFalse(peakTooLow.hasSpeechCandidate, "peak below 0.004 should never qualify")

        let rmsTooLow = AudioSignalAnalysis(sampleCount: 32_000, sampleRate: 16_000, peak: 0.01, rms: 0.0001, activeRatio: 0.5)
        XCTAssertFalse(rmsTooLow.hasSpeechCandidate, "rms below 0.0005 should never qualify")

        let activeRatioTooLow = AudioSignalAnalysis(sampleCount: 32_000, sampleRate: 16_000, peak: 0.01, rms: 0.001, activeRatio: 0.001)
        XCTAssertFalse(activeRatioTooLow.hasSpeechCandidate, "active ratio below 0.005 should never qualify")

        let durationTooShort = AudioSignalAnalysis(sampleCount: 100, sampleRate: 16_000, peak: 0.01, rms: 0.001, activeRatio: 1.0)
        XCTAssertFalse(durationTooShort.hasSpeechCandidate, "active duration below 0.20s should never qualify")
    }

    // MARK: - normalizationGain

    func testNormalizationGainStaysUnityBelowMinPeak() {
        let analysis = AudioSignalAnalysis(sampleCount: 16_000, sampleRate: 16_000, peak: 0.0005, rms: 0.0001, activeRatio: 0.1)
        let gain = AudioSignalRecovery.normalizationGain(for: analysis)

        XCTAssertEqual(gain, 1.0, "signal below the min-peak floor should not be boosted")
    }

    func testNormalizationGainTargetsConfiguredPeak() {
        let analysis = AudioSignalAnalysis(sampleCount: 16_000, sampleRate: 16_000, peak: 0.15, rms: 0.02, activeRatio: 0.5)
        let gain = AudioSignalRecovery.normalizationGain(for: analysis, targetPeak: 0.45, maxGain: 12.0, minPeak: 0.0008)

        assertNear(gain, 3.0, tolerance: 0.01, "gain should scale peak up toward the target peak")
    }

    func testNormalizationGainClampsToMaxGain() {
        let analysis = AudioSignalAnalysis(sampleCount: 16_000, sampleRate: 16_000, peak: 0.01, rms: 0.002, activeRatio: 0.5)
        let gain = AudioSignalRecovery.normalizationGain(for: analysis, targetPeak: 0.45, maxGain: 12.0, minPeak: 0.0008)

        assertNear(gain, 12.0, tolerance: 0.01, "gain should clamp at the configured max instead of overshooting")
    }

    // MARK: - normalizeForSpeech

    func testNormalizeForSpeechLeavesSilenceUntouched() {
        let samples: [Float] = [0.0001, -0.0001, 0.0002]
        let result = AudioSignalRecovery.normalizeForSpeech(samples: samples, sampleRate: 16_000)

        XCTAssertEqual(result.samples, samples, "near-silent buffers should not be rewritten")
        XCTAssertEqual(result.gain, 1.0)
        XCTAssertFalse(result.wasNormalized)
    }

    func testNormalizeForSpeechLeavesAlreadyLoudSignalUntouched() {
        let samples: [Float] = [0.5, -0.5]
        let result = AudioSignalRecovery.normalizeForSpeech(samples: samples, sampleRate: 16_000, targetPeak: 0.45)

        XCTAssertEqual(result.samples, samples, "signal already above the target peak should not be attenuated")
        XCTAssertEqual(result.gain, 1.0)
        XCTAssertFalse(result.wasNormalized)
    }

    func testNormalizeForSpeechBoostsQuietSignalTowardTargetPeak() {
        let samples: [Float] = [0.1, -0.1]
        let result = AudioSignalRecovery.normalizeForSpeech(samples: samples, sampleRate: 16_000, targetPeak: 0.45, maxGain: 12.0)

        XCTAssertTrue(result.wasNormalized)
        assertNear(result.gain, 4.5, tolerance: 0.01)
        XCTAssertEqual(result.samples.count, samples.count)
        assertNear(result.samples[0], 0.45, tolerance: 0.01)
        assertNear(result.samples[1], -0.45, tolerance: 0.01)
    }

    func testNormalizeForSpeechClampsToUnitRange() {
        let samples: [Float] = [0.09, -0.09]
        let result = AudioSignalRecovery.normalizeForSpeech(samples: samples, sampleRate: 16_000, targetPeak: 0.45, maxGain: 20.0)

        for sample in result.samples {
            XCTAssertLessThanOrEqual(sample, 1.0)
            XCTAssertGreaterThanOrEqual(sample, -1.0)
        }
    }

    // MARK: - padForParakeet

    func testPadForParakeetLeavesLongEnoughBuffersUnchanged() {
        let samples = [Float](repeating: 0.1, count: AudioSignalRecovery.parakeetMinimumInferenceSamples)
        let padded = AudioSignalRecovery.padForParakeet(samples: samples)

        XCTAssertEqual(padded.count, samples.count)
        XCTAssertEqual(padded, samples)
    }

    func testPadForParakeetZeroPadsShortBuffers() {
        let samples: [Float] = [0.1, 0.2, 0.3]
        let padded = AudioSignalRecovery.padForParakeet(samples: samples)

        XCTAssertEqual(padded.count, AudioSignalRecovery.parakeetMinimumInferenceSamples)
        XCTAssertEqual(Array(padded.prefix(3)), samples)
        XCTAssertTrue(padded.suffix(from: 3).allSatisfy { $0 == 0 })
    }

    // MARK: - activeThreshold / speechDetectionThreshold

    func testActiveThresholdClampsToConfiguredRange() {
        assertNear(AudioSignalRecovery.activeThreshold(forPeak: 0), 0.003, tolerance: 0.0001, "threshold should never fall below the floor")
        assertNear(AudioSignalRecovery.activeThreshold(forPeak: 1.0), 0.020, tolerance: 0.0001, "threshold should never exceed the ceiling")
        assertNear(AudioSignalRecovery.activeThreshold(forPeak: 0.1), 0.008, tolerance: 0.0005, "threshold should scale with peak in between")
    }

    func testSpeechDetectionThresholdUsesConservativeFloorWithoutSpeechCandidate() {
        let analysis = AudioSignalAnalysis(sampleCount: 16_000, sampleRate: 16_000, peak: 0.001, rms: 0.0001, activeRatio: 0.001)
        XCTAssertFalse(analysis.hasSpeechCandidate)

        let threshold = AudioSignalRecovery.speechDetectionThreshold(for: analysis)
        assertNear(threshold, 0.003, tolerance: 0.0005)
    }

    func testSpeechDetectionThresholdCombinesPeakAndRMSWhenQualifying() {
        let analysis = AudioSignalAnalysis(sampleCount: 32_000, sampleRate: 16_000, peak: 0.1, rms: 0.01, activeRatio: 0.5)
        XCTAssertTrue(analysis.hasSpeechCandidate)

        let threshold = AudioSignalRecovery.speechDetectionThreshold(for: analysis)
        assertNear(threshold, 0.008, tolerance: 0.0005)
    }
}
