import Foundation

struct DictationAudioAnalysis: Equatable {
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

    var hasUsableSpeechSignal: Bool {
        peak >= 0.010 && rms >= 0.0015 && activeRatio >= 0.005 && activeDurationSeconds >= 0.20
    }

    var context: [String: String] {
        [
            "audio_duration_s": String(format: "%.2f", durationSeconds),
            "audio_peak": String(format: "%.5f", peak),
            "audio_rms": String(format: "%.5f", rms),
            "audio_active_ratio": String(format: "%.3f", activeRatio),
            "audio_active_duration_s": String(format: "%.2f", activeDurationSeconds),
            "audio_has_signal": "\(hasUsableSpeechSignal)",
        ]
    }
}

enum DictationAudioRecovery {
    static func analyze(samples: [Float], sampleRate: Double) -> DictationAudioAnalysis {
        guard !samples.isEmpty, sampleRate > 0 else {
            return DictationAudioAnalysis(
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
        let activityThreshold = activeThreshold(forPeak: peak)
        var activeCount = 0
        for sample in samples {
            if abs(sample) >= activityThreshold { activeCount += 1 }
        }

        return DictationAudioAnalysis(
            sampleCount: samples.count,
            sampleRate: sampleRate,
            peak: peak,
            rms: rms,
            activeRatio: Double(activeCount) / Double(samples.count)
        )
    }

    static func retrySamples(
        from samples: [Float],
        sampleRate: Double,
        analysis: DictationAudioAnalysis? = nil
    ) -> [Float]? {
        let resolvedAnalysis = analysis ?? analyze(samples: samples, sampleRate: sampleRate)
        guard resolvedAnalysis.hasUsableSpeechSignal else { return nil }

        let threshold = activeThreshold(forPeak: resolvedAnalysis.peak)
        guard
            let firstActive = samples.firstIndex(where: { abs($0) >= threshold }),
            let lastActive = samples.lastIndex(where: { abs($0) >= threshold }),
            firstActive <= lastActive
        else {
            return nil
        }

        let padding = Int(sampleRate * 0.25)
        let start = max(0, firstActive - padding)
        let end = min(samples.count, lastActive + padding + 1)
        guard end > start else { return nil }

        var focused = Array(samples[start..<end])
        guard focused.count >= TranscriptedConstants.parakeetMinimumInferenceSamples else {
            return nil
        }

        var focusedPeak: Float = 0
        for sample in focused { focusedPeak = max(focusedPeak, abs(sample)) }
        guard focusedPeak > 0.0001 else { return nil }

        let gain = max(1.0, min(12.0, 0.45 / focusedPeak))
        if gain > 1.0 {
            for index in focused.indices {
                focused[index] = max(-1.0, min(1.0, focused[index] * gain))
            }
        }

        return focused
    }

    private static func activeThreshold(forPeak peak: Float) -> Float {
        max(0.003, min(0.020, peak * 0.08))
    }
}
