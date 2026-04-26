import Foundation

struct AudioSignalAnalysis: Equatable {
    let sampleCount: Int
    let sampleRate: Double
    let peak: Float
    let rms: Float
    let activeRatio: Double

    var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(sampleCount) / sampleRate
    }

    var activeDurationSeconds: Double {
        durationSeconds * activeRatio
    }

    var hasSpeechCandidate: Bool {
        peak >= 0.004 && rms >= 0.0005 && activeRatio >= 0.005 && activeDurationSeconds >= 0.20
    }

    var context: [String: String] {
        [
            "sample_count": "\(sampleCount)",
            "duration_s": String(format: "%.2f", durationSeconds),
            "peak": String(format: "%.5f", peak),
            "rms": String(format: "%.5f", rms),
            "active_ratio": String(format: "%.3f", activeRatio),
            "active_duration_s": String(format: "%.2f", activeDurationSeconds),
            "has_speech_candidate": "\(hasSpeechCandidate)",
        ]
    }
}

struct AudioNormalizationResult: Equatable {
    let samples: [Float]
    let analysis: AudioSignalAnalysis
    let gain: Float

    var wasNormalized: Bool {
        gain > 1.0001
    }
}

enum AudioSignalRecovery {
    static let parakeetSampleRate: Double = 16_000
    static let parakeetMinimumInferenceSamples = 16_000
    static let legacySpeechDetectionThreshold: Float = 0.010

    static func analyze(samples: [Float], sampleRate: Double) -> AudioSignalAnalysis {
        guard !samples.isEmpty, sampleRate > 0 else {
            return AudioSignalAnalysis(
                sampleCount: samples.count,
                sampleRate: sampleRate,
                peak: 0,
                rms: 0,
                activeRatio: 0
            )
        }

        var peak: Float = 0
        var sumOfSquares: Double = 0
        for sample in samples {
            let magnitude = abs(sample)
            peak = max(peak, magnitude)
            sumOfSquares += Double(sample * sample)
        }

        let rms = Float(sqrt(sumOfSquares / Double(samples.count)))
        let threshold = activeThreshold(forPeak: peak)
        var activeCount = 0
        for sample in samples {
            if abs(sample) >= threshold { activeCount += 1 }
        }

        return AudioSignalAnalysis(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            peak: peak,
            rms: rms,
            activeRatio: Double(activeCount) / Double(samples.count)
        )
    }

    static func normalizeForSpeech(
        samples: [Float],
        sampleRate: Double,
        analysis: AudioSignalAnalysis? = nil,
        targetPeak: Float = 0.45,
        maxGain: Float = 12.0,
        minPeak: Float = 0.0008
    ) -> AudioNormalizationResult {
        let resolvedAnalysis = analysis ?? analyze(samples: samples, sampleRate: sampleRate)
        // Issue #500: WebRTC-attenuated meeting mic audio routinely peaks below
        // the legacy hasSpeechCandidate gate (peak >= 0.004). The previous
        // short-circuit returned gain=1.0 for exactly the case we needed to
        // recover. Now we only bail when the buffer is essentially silence,
        // and otherwise let normalizationGain (clamped by maxGain) do its job.
        guard resolvedAnalysis.peak >= minPeak else {
            return AudioNormalizationResult(samples: samples, analysis: resolvedAnalysis, gain: 1.0)
        }

        let gain = normalizationGain(
            for: resolvedAnalysis,
            targetPeak: targetPeak,
            maxGain: maxGain,
            minPeak: minPeak
        )
        guard gain > 1.0 else {
            return AudioNormalizationResult(samples: samples, analysis: resolvedAnalysis, gain: 1.0)
        }

        let normalized = samples.map { sample in
            max(-1.0, min(1.0, sample * gain))
        }

        return AudioNormalizationResult(samples: normalized, analysis: resolvedAnalysis, gain: gain)
    }

    static func padForParakeet(samples: [Float]) -> [Float] {
        guard samples.count < parakeetMinimumInferenceSamples else { return samples }
        return samples + [Float](repeating: 0, count: parakeetMinimumInferenceSamples - samples.count)
    }

    static func normalizationGain(
        for analysis: AudioSignalAnalysis,
        targetPeak: Float = 0.45,
        maxGain: Float = 12.0,
        minPeak: Float = 0.0008
    ) -> Float {
        guard analysis.peak >= minPeak else { return 1.0 }
        return max(1.0, min(maxGain, targetPeak / analysis.peak))
    }

    static func speechDetectionThreshold(for analysis: AudioSignalAnalysis) -> Float {
        guard analysis.hasSpeechCandidate else {
            return min(legacySpeechDetectionThreshold, activeThreshold(forPeak: analysis.peak))
        }

        let peakBased = activeThreshold(forPeak: analysis.peak)
        let rmsBased = max(0.003, min(0.020, analysis.rms * 0.8))
        return min(legacySpeechDetectionThreshold, peakBased, rmsBased)
    }

    static func activeThreshold(forPeak peak: Float) -> Float {
        max(0.003, min(0.020, peak * 0.08))
    }
}
