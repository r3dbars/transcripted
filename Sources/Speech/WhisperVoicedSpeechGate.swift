// WhisperVoicedSpeechGate.swift
// Keeps Whisper from writing text for audio that has no voice in it.
//
// Whisper makes up confident text for silence, room tone, breaths and
// clicks: "Kiitos." in Finnish, "you" or "Thank you." in English, "..." in
// most languages. Its own signals don't catch it. Pinned WhisperKit 0.18
// never fills in the no-speech probability (it's always 0), and the made-up
// lines decode with an average log probability around -0.1, better than a lot
// of real speech, so a log-probability floor can't tell them apart.
//
// So the gate looks at the audio. Spoken words have voiced sounds (vowels,
// and consonants like m, n, l, j) that repeat at the speaker's pitch,
// 70-500 Hz, and hold that pitch for tens of milliseconds. Room tone, hiss,
// breaths, keyboard clicks and digital silence can line up for a frame or
// three by chance, but not for a steady run. A segment without one run of
// `minimumVoicedRun` steady-pitch frames has no voice in it.
//
// The measure is a normalized autocorrelation, so it doesn't care how loud
// the audio is. That matters because the meeting mic path boosts quiet
// segments up to 12x before STT. Zero padding carries no evidence either way.
// A steady tone in the pitch range (electrical hum with strong harmonics)
// does count as voiced; it gets the old behavior, never worse.

import Accelerate
import Foundation

enum WhisperVoicedSpeechGate {
    static let sampleRate: Double = 16_000
    /// Frame compared against itself one pitch period later (20 ms).
    static let frameSamples = 320
    /// Frames start every 10 ms.
    static let hopSamples = 160
    /// Shortest pitch period: 500 Hz.
    static let minimumLag = 32
    /// Longest pitch period: 70 Hz.
    static let maximumLag = 228
    /// Correlation at the pitch period for a frame to count as voiced.
    static let voicedCorrelation: Float = 0.7
    /// How far the pitch period may drift from one frame to the next and
    /// still be the same voice.
    static let pitchDriftTolerance: Float = 0.15
    /// Consecutive steady-pitch frames that make a segment voiced: 60 ms of
    /// audio. Over 90 minutes of synthetic room tone, hiss, rumble, breaths
    /// and typing the longest chance run was 2 frames. On real meeting audio
    /// (AMI headset mix) every annotated turn over 2 s passed, 98% of 1-2 s
    /// turns and 85% of turns under 0.5 s; most of the rest were backchannels
    /// Whisper wrote nothing for.
    static let minimumVoicedRun = 5
    /// Frames quieter than this after filtering carry no evidence either way:
    /// zero padding, or a fade into digital silence.
    static let minimumFrameRMS: Float = 0.000_05

    /// Whether `samples` (16 kHz mono) hold a voice. Stops reading at the
    /// first run long enough to say yes.
    static func hasVoicedSpeech(_ samples: [Float]) -> Bool {
        longestVoicedRun(samples, stopAt: minimumVoicedRun) >= minimumVoicedRun
    }

    /// Audio filtered and scanned per block, so an hour-long segment costs
    /// a few hundred kilobytes, not a filtered copy of the whole thing.
    static let blockSamples = 160_000

    /// Longest run of consecutive voiced frames with a steady pitch, counting
    /// no further than `stopAt`.
    static func longestVoicedRun(_ samples: [Float], stopAt: Int = .max) -> Int {
        guard samples.count >= frameSamples + maximumLag + 1, stopAt > 0 else { return 0 }

        // Band-pass to 120 Hz-1 kHz. The high-pass (run twice for a steep
        // edge) drops room rumble and DC, which otherwise line up into a
        // fake long pitch period. A low voice's fundamental goes with it, but
        // its harmonics repeat at the same period, so the pitch peak stays.
        // The low-pass drops hiss, which would bury that peak in a noisy room.
        var filters = [Biquad.highPass(cutoff: 120), Biquad.highPass(cutoff: 120), Biquad.lowPass(cutoff: 1_000)]
        var scan = RunScan(stopAt: stopAt)
        // Filtered audio from the next unscanned frame's start onward.
        var pending: [Float] = []
        var blockStart = 0
        while blockStart < samples.count, scan.longest < stopAt {
            let blockEnd = min(samples.count, blockStart + blockSamples)
            var block = Array(samples[blockStart..<blockEnd])
            for index in filters.indices {
                filters[index].apply(to: &block)
            }
            pending += block
            pending.removeFirst(scan.scanFrames(in: pending))
            blockStart = blockEnd
        }
        return scan.longest
    }

    /// Run-length state carried from one block to the next.
    private struct RunScan {
        let stopAt: Int
        var longest = 0
        var run = 0
        var previousLag = 0
        var correlations = [Float](repeating: 0, count: maximumLag + 2)

        init(stopAt: Int) {
            self.stopAt = stopAt
        }

        /// Scans every whole frame in `buffer`, which starts at a frame
        /// boundary, and returns where the next frame starts.
        mutating func scanFrames(in buffer: [Float]) -> Int {
            // Running sum of squares, so each lag's energy is one subtraction.
            var squareSums = [Double](repeating: 0, count: buffer.count + 1)
            for index in buffer.indices {
                squareSums[index + 1] = squareSums[index] + Double(buffer[index] * buffer[index])
            }
            var start = 0
            buffer.withUnsafeBufferPointer { pointer in
                guard let base = pointer.baseAddress else { return }
                while start + frameSamples + maximumLag + 1 <= pointer.count, longest < stopAt {
                    defer { start += hopSamples }
                    let energy = squareSums[start + frameSamples] - squareSums[start]
                    let rms = Float((energy / Double(frameSamples)).squareRoot())
                    guard rms >= minimumFrameRMS,
                          let lag = pitchLag(
                              base: base,
                              start: start,
                              energy: energy,
                              squareSums: squareSums,
                              correlations: &correlations
                          ) else {
                        run = 0
                        continue
                    }
                    let drift = abs(Float(lag - previousLag))
                    if run > 0, drift <= pitchDriftTolerance * Float(previousLag) {
                        run += 1
                    } else {
                        run = 1
                    }
                    previousLag = lag
                    longest = max(longest, run)
                }
            }
            return min(start, buffer.count)
        }
    }

    /// The frame's pitch period: the lag of the strongest peak in its
    /// normalized autocorrelation between the shortest and longest period,
    /// or nil when no peak reaches `voicedCorrelation`. Noise that only
    /// decays from lag 0 has no peak.
    private static func pitchLag(
        base: UnsafePointer<Float>,
        start: Int,
        energy: Double,
        squareSums: [Double],
        correlations: inout [Float]
    ) -> Int? {
        guard energy > 0 else { return nil }
        let frame = base + start
        let count = vDSP_Length(frameSamples)
        for lag in (minimumLag - 1)...(maximumLag + 1) {
            var dot: Float = 0
            vDSP_dotpr(frame, 1, frame + lag, 1, &dot, count)
            let shiftedEnergy = squareSums[start + lag + frameSamples] - squareSums[start + lag]
            let denominator = (energy * shiftedEnergy).squareRoot()
            correlations[lag] = denominator > 0 ? Float(Double(dot) / denominator) : 0
        }
        var bestLag: Int?
        var bestValue = voicedCorrelation
        for lag in minimumLag...maximumLag {
            let value = correlations[lag]
            if value >= bestValue, value >= correlations[lag - 1], value >= correlations[lag + 1] {
                bestValue = value
                bestLag = lag
            }
        }
        return bestLag
    }

    /// A second-order filter (RBJ cookbook), Q = 1/sqrt(2). Keeps its state
    /// between calls, so blocks filter as one continuous signal.
    private struct Biquad {
        let b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
        private var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        init(b0: Float, b1: Float, b2: Float, a1: Float, a2: Float) {
            self.b0 = b0
            self.b1 = b1
            self.b2 = b2
            self.a1 = a1
            self.a2 = a2
        }

        static func lowPass(cutoff: Double) -> Biquad {
            let (cosine, alpha) = terms(cutoff)
            let a0 = 1 + alpha
            return Biquad(
                b0: Float((1 - cosine) / 2 / a0), b1: Float((1 - cosine) / a0), b2: Float((1 - cosine) / 2 / a0),
                a1: Float(-2 * cosine / a0), a2: Float((1 - alpha) / a0)
            )
        }

        static func highPass(cutoff: Double) -> Biquad {
            let (cosine, alpha) = terms(cutoff)
            let a0 = 1 + alpha
            return Biquad(
                b0: Float((1 + cosine) / 2 / a0), b1: Float(-(1 + cosine) / a0), b2: Float((1 + cosine) / 2 / a0),
                a1: Float(-2 * cosine / a0), a2: Float((1 - alpha) / a0)
            )
        }

        private static func terms(_ cutoff: Double) -> (cosine: Double, alpha: Double) {
            let omega = 2 * Double.pi * cutoff / sampleRate
            return (cos(omega), sin(omega) / 2.0.squareRoot())
        }

        mutating func apply(to samples: inout [Float]) {
            for index in samples.indices {
                let x = samples[index]
                let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
                x2 = x1
                x1 = x
                y2 = y1
                y1 = y
                samples[index] = y
            }
        }
    }
}
