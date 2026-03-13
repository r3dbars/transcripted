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
    /// Uses AVAudioConverter for hardware-accelerated resampling with anti-aliasing.
    static func loadAndResample(url: URL, targetRate: Double = 16000) throws -> [Float] {
        return try convertToMono(url: url, targetRate: targetRate)
    }

    /// Hardware-accelerated resampling via AVAudioConverter.
    /// Handles channel mixing (stereo→mono) and sample rate conversion in one pass
    /// using Apple's polyphase anti-aliasing filter (vDSP under the hood).
    private static func convertToMono(url: URL, targetRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let srcFrames = AVAudioFrameCount(file.length)

        // Guard against empty audio files (e.g., mic device thrashing during recording)
        guard srcFrames > 0 else {
            throw PipelineError.emptyAudioFile
        }

        // Short-circuit if already at target format
        if srcFormat.sampleRate == targetRate && srcFormat.channelCount == 1 {
            return try loadWAV(url: url).samples
        }

        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioResampler", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create target audio format (\(targetRate)Hz mono)"
            ])
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw NSError(domain: "AudioResampler", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create AVAudioConverter (\(srcFormat.sampleRate)Hz \(srcFormat.channelCount)ch → \(targetRate)Hz mono)"
            ])
        }

        let ratio = targetRate / srcFormat.sampleRate

        // Process in chunks to avoid multi-GB allocations for long recordings
        // 30 seconds at 48kHz stereo float32 ≈ 11MB per chunk (vs 2.6GB for a 2-hour file)
        let chunkDuration: Double = 30.0  // seconds
        let chunkFrames = AVAudioFrameCount(srcFormat.sampleRate * chunkDuration)
        var allSamples: [Float] = []
        allSamples.reserveCapacity(Int(Double(srcFrames) * ratio) + 16)

        while file.framePosition < file.length {
            let framesToRead = min(chunkFrames, AVAudioFrameCount(file.length - file.framePosition))

            guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: framesToRead) else {
                throw NSError(domain: "AudioResampler", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create source audio buffer"
                ])
            }
            try file.read(into: srcBuffer, frameCount: framesToRead)

            let dstFrames = AVAudioFrameCount(Double(framesToRead) * ratio) + 16
            guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: dstFrames) else {
                throw NSError(domain: "AudioResampler", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create destination audio buffer"
                ])
            }

            var inputConsumed = false
            var conversionError: NSError?
            let status = converter.convert(to: dstBuffer, error: &conversionError) { _, outStatus in
                if inputConsumed {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                inputConsumed = true
                outStatus.pointee = .haveData
                return srcBuffer
            }

            if status == .error, let conversionError {
                throw conversionError
            }

            guard let floatData = dstBuffer.floatChannelData else {
                throw NSError(domain: "AudioResampler", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to get float channel data from converted buffer"
                ])
            }

            allSamples.append(contentsOf: UnsafeBufferPointer(start: floatData[0], count: Int(dstBuffer.frameLength)))
            // Do NOT reset converter between chunks — resetting discards the polyphase
            // filter's internal state, causing tiny clicks at chunk boundaries.
        }

        return allSamples
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
