import Foundation
import Accelerate

struct AudioSignalAnalysis: Equatable {
    let sampleCount: Int
    let sampleRate: Double
    let peak: Float
    let rms: Float
    let activeRatio: Double

    var durationSeconds: Double {
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else { return 0 }
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
    // This is a capture-health floor, not a speech detector. It is deliberately
    // lower than hasSpeechCandidate so quiet but valid microphone input is kept.
    static let minimumCapturePeak: Float = 0.0008
    static let minimumCaptureActiveDuration: Double = 0.20
    private static let captureFrameDuration: Double = 0.10
    private static let minimumCaptureFrameRMS: Float = 0.0001

    static func analyze(samples: [Float], sampleRate: Double) -> AudioSignalAnalysis {
        guard !samples.isEmpty, AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else {
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

    /// Returns whether the finished microphone artifact contains a sustained,
    /// low-level capture signal. This deliberately does not claim that speech
    /// was spoken or understood; it only prevents an all-silent/one-buffer mic
    /// artifact from being saved as a healthy two-source meeting.
    static func hasUsableCaptureSignal(samples: [Float], sampleRate: Double) -> Bool {
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate),
              samples.count >= Int(sampleRate * minimumCaptureActiveDuration) else {
            return false
        }

        let frameSize = max(1, Int(sampleRate * captureFrameDuration))
        var peak: Float = 0
        var activeDuration = 0.0
        for start in stride(from: 0, to: samples.count, by: frameSize) {
            let end = min(samples.count, start + frameSize)
            let frame = samples[start..<end]
            guard !frame.isEmpty else { continue }
            var sumOfSquares = 0.0
            for sample in frame {
                peak = max(peak, abs(sample))
                sumOfSquares += Double(sample * sample)
            }
            let frameRMS = Float(sqrt(sumOfSquares / Double(frame.count)))
            if frameRMS >= minimumCaptureFrameRMS {
                activeDuration += Double(frame.count) / sampleRate
            }
            if activeDuration >= minimumCaptureActiveDuration {
                return peak >= minimumCapturePeak
            }
        }
        return peak >= minimumCapturePeak && activeDuration >= minimumCaptureActiveDuration
    }

    static func normalizeForSpeech(
        samples: [Float],
        sampleRate: Double,
        analysis: AudioSignalAnalysis? = nil,
        targetPeak: Float = 0.45,
        maxGain: Float = 12.0,
        minPeak: Float = 0.0008,
        ignoringSpikes: Bool = false
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

        // With `ignoringSpikes`, aim the gain at the spike-tolerant peak, not
        // the raw one. A single desk knock or mouse click sets the raw peak,
        // so the gain stays near 1 and a quiet voice next to it reaches STT as
        // quiet as it was captured. The click is clipped at +/-1 below.
        // Only the last-chance pass opts in for now: on normal meetings it can
        // also clip loud plosives or laughs, so it needs a corpus A/B first.
        let effectivePeak = ignoringSpikes
            ? spikeTolerantPeak(samples: samples, sampleRate: sampleRate)
            : resolvedAnalysis.peak
        guard effectivePeak >= minPeak else {
            return AudioNormalizationResult(samples: samples, analysis: resolvedAnalysis, gain: 1.0)
        }
        let gain = max(1.0, min(maxGain, targetPeak / effectivePeak))
        guard gain > 1.0 else {
            return AudioNormalizationResult(samples: samples, analysis: resolvedAnalysis, gain: 1.0)
        }

        let normalized = samples.map { sample in
            max(-1.0, min(1.0, sample * gain))
        }

        return AudioNormalizationResult(samples: normalized, analysis: resolvedAnalysis, gain: gain)
    }

    /// Frames per spike: a click or knock is a few milliseconds long, so it
    /// lands in one 20 ms frame, two at most when it straddles a boundary.
    static let spikeFrameDuration: Double = 0.020
    /// How many of the loudest frames to ignore when finding the level to
    /// normalize against. Speech fills many frames at a similar level, so
    /// skipping a few barely moves its peak; a handful of isolated clicks are
    /// skipped entirely.
    static let spikeFramesIgnored = 3

    /// The buffer's peak once its few loudest 20 ms frames are set aside.
    ///
    /// Returns the plain peak when the buffer has too few frames for that to
    /// mean anything. Never larger than the plain peak.
    static func spikeTolerantPeak(samples: [Float], sampleRate: Double) -> Float {
        guard !samples.isEmpty else { return 0 }
        let frameSize = AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate)
            ? max(1, Int(sampleRate * spikeFrameDuration))
            : samples.count
        // Loudest frame peaks seen so far, largest first. Only the top
        // `spikeFramesIgnored + 1` matter, so this stays tiny.
        var loudest: [Float] = []
        let keep = spikeFramesIgnored + 1
        var frameCount = 0
        var start = 0
        while start < samples.count {
            let end = min(samples.count, start + frameSize)
            var framePeak: Float = 0
            for index in start..<end {
                framePeak = max(framePeak, abs(samples[index]))
            }
            frameCount += 1
            if loudest.count < keep || framePeak > loudest[loudest.count - 1] {
                let insertAt = loudest.firstIndex(where: { framePeak > $0 }) ?? loudest.count
                loudest.insert(framePeak, at: insertAt)
                if loudest.count > keep { loudest.removeLast() }
            }
            start = end
        }
        // With only a few frames there is no way to tell a spike from the
        // signal itself, so keep the old behavior.
        guard frameCount > keep * 2 else { return loudest.first ?? 0 }
        return loudest[keep - 1]
    }

    /// Frame length for the speech-modulation check. Syllables rise and fall
    /// over roughly 100-300 ms, so 30 ms frames resolve them.
    static let modulationFrameDuration: Double = 0.030
    /// A frame counts as loud when it sits this far above the buffer's quiet
    /// floor (4x amplitude, about 12 dB).
    static let modulationLoudness: Float = 4.0
    /// Loud frames must add up to at least this much audio.
    static let minimumModulatedDuration: Double = 0.30
    /// Loud frames must also clear this absolute level, so digital near-silence
    /// with a slightly noisier patch never counts.
    static let minimumModulatedFrameRMS: Float = 0.0004

    /// Whether the buffer rises and falls the way speech does.
    ///
    /// This is the gate for the last-chance pass that runs when the normal
    /// meeting pass found no words. It is deliberately stricter than
    /// `hasSpeechCandidate`: steady hum, a DC offset, a constant tone and
    /// digital silence all fail, because none of them get louder and quieter
    /// again. Speech passes, and so does some bursty noise such as typing,
    /// which is fine because the STT engine then returns no words for it.
    static func hasSpeechLikeModulation(samples: [Float], sampleRate: Double) -> Bool {
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else { return false }
        let frameSize = max(1, Int(sampleRate * modulationFrameDuration))
        let frameCount = samples.count / frameSize
        let requiredLoudFrames = Int((minimumModulatedDuration / modulationFrameDuration).rounded(.up))
        guard frameCount >= requiredLoudFrames else { return false }

        var frameRMS = [Float](repeating: 0, count: frameCount)
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            for frame in 0..<frameCount {
                let frameStart = base + frame * frameSize
                var mean: Float = 0
                vDSP_meanv(frameStart, 1, &mean, vDSP_Length(frameSize))
                var sumOfSquares: Float = 0
                for index in 0..<frameSize {
                    let centered = frameStart[index] - mean
                    sumOfSquares += centered * centered
                }
                frameRMS[frame] = sqrt(sumOfSquares / Float(frameSize))
            }
        }

        // The quiet floor is the 20th-percentile frame: pauses between words
        // and sentences, or the room tone under them.
        let sorted = frameRMS.sorted()
        let floor = sorted[min(sorted.count - 1, sorted.count / 5)]
        let loudThreshold = max(minimumModulatedFrameRMS, floor * modulationLoudness)
        var loudFrames = 0
        for rms in frameRMS where rms >= loudThreshold {
            loudFrames += 1
            if loudFrames >= requiredLoudFrames { return true }
        }
        return false
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
