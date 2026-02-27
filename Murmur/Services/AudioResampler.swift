// AudioResampler.swift
// Resamples Float32 mono audio from native sample rate to 16kHz for Parakeet/Sortformer.
// Pure Swift — linear interpolation, no dependencies.
// Ported from Draft's AudioResampler.

import Foundation
import AVFoundation

enum AudioResampler {

    /// Resample mono Float32 audio from `inputRate` to `outputRate`.
    /// Uses linear interpolation — sufficient for speech (bandwidth << Nyquist at 16kHz).
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

    /// Load a WAV file and return mono Float32 samples at the file's native sample rate.
    /// Converts stereo to mono by averaging channels.
    static func loadWAV(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frameCount = AVAudioFrameCount(file.length)

        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw NSError(domain: "AudioResampler", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create audio buffer"
            ])
        }

        try file.read(into: buffer)

        guard let floatData = buffer.floatChannelData else {
            throw NSError(domain: "AudioResampler", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to get float channel data"
            ])
        }

        let frameLength = Int(buffer.frameLength)
        let channelCount = Int(format.channelCount)

        // Convert to mono Float32 array
        var samples = [Float](repeating: 0, count: frameLength)

        if channelCount == 1 {
            // Already mono
            samples = Array(UnsafeBufferPointer(start: floatData[0], count: frameLength))
        } else {
            // Average all channels to mono
            for frame in 0..<frameLength {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += floatData[ch][frame]
                }
                samples[frame] = sum / Float(channelCount)
            }
        }

        return (samples, format.sampleRate)
    }

    /// Load a WAV file and return mono Float32 samples resampled to 16kHz.
    static func loadAndResample(url: URL, targetRate: Double = 16000) throws -> [Float] {
        let (samples, sampleRate) = try loadWAV(url: url)
        return resample(samples, from: sampleRate, to: targetRate)
    }

    /// Extract a time slice from samples array.
    /// Returns samples between startTime and endTime (in seconds) at the given sample rate.
    static func extractSlice(
        from samples: [Float],
        sampleRate: Double,
        startTime: Double,
        endTime: Double
    ) -> [Float] {
        let startSample = max(0, Int(startTime * sampleRate))
        let endSample = min(samples.count, Int(endTime * sampleRate))
        guard startSample < endSample else { return [] }
        return Array(samples[startSample..<endSample])
    }
}
