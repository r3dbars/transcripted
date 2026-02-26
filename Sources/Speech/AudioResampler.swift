// AudioResampler.swift
// Resamples Float32 mono audio from native sample rate to 16kHz for Parakeet.
// Pure Swift — linear interpolation, no dependencies.

import Foundation

enum AudioResampler {

    /// Resample mono Float32 audio from `inputRate` to `outputRate`.
    /// Uses linear interpolation — sufficient for speech (bandwidth ≪ Nyquist at 16kHz).
    static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double = 16000) -> [Float] {
        guard inputRate != outputRate, !samples.isEmpty else { return samples }

        let ratio = inputRate / outputRate
        let outputCount = Int(Double(samples.count) / ratio)
        guard outputCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let srcIndex = Double(i) * ratio
            let lo = Int(srcIndex)
            let hi = min(lo + 1, samples.count - 1)
            let frac = Float(srcIndex - Double(lo))
            output[i] = samples[lo] + frac * (samples[hi] - samples[lo])
        }
        return output
    }
}
