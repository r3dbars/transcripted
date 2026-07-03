// AudioResampler.swift
// Resamples Float32 mono audio from native sample rate to 16kHz for Parakeet/Sortformer.
// Pure Swift — linear interpolation, no dependencies.
// Ported from the earlier app-side AudioResampler.

import Foundation
import AVFoundation

public enum AudioResampler {

    /// Resample mono Float32 audio from `inputRate` to `outputRate`.
    /// Uses linear interpolation — sufficient for speech (bandwidth << Nyquist at 16kHz).
    public static func resample(_ samples: [Float], from inputRate: Double, to outputRate: Double = 16000) -> [Float] {
        guard inputRate != outputRate, !samples.isEmpty else { return samples }
        guard AudioRecordingFormatPolicy.isUsableSampleRate(inputRate),
              AudioRecordingFormatPolicy.isUsableSampleRate(outputRate) else {
            return samples
        }

        let ratio = inputRate / outputRate
        let rawOutputCount = Double(samples.count) / ratio
        guard rawOutputCount.isFinite, rawOutputCount > 0, rawOutputCount <= Double(Int.max) else {
            return []
        }
        let outputCount = Int(rawOutputCount)
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
    public static func loadWAV(url: URL) throws -> (samples: [Float], sampleRate: Double) {
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
        guard channelCount > 0 else {
            throw NSError(domain: "AudioResampler", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Audio file has no readable channels"
            ])
        }

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
    public static func loadAndResample(url: URL, targetRate: Double = 16000) throws -> [Float] {
        return try convertToMono(url: url, targetRate: targetRate)
    }

    /// Hardware-accelerated resampling via AVAudioConverter.
    /// Handles channel mixing (stereo→mono) and sample rate conversion in one pass
    /// using Apple's polyphase anti-aliasing filter (vDSP under the hood).
    ///
    /// Uses a single convert() call with a streaming input block that reads chunks
    /// from the file on demand. This avoids the AVAudioConverter terminal state bug
    /// where signaling .endOfStream between chunks causes the converter to stop
    /// processing subsequent data.
    private static func convertToMono(url: URL, targetRate: Double) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat

        // Guard against empty audio files (e.g., mic device thrashing during recording)
        guard file.length > 0 else {
            throw PipelineError.emptyAudioFile
        }
        guard file.length <= Int64(AVAudioFrameCount.max) else {
            throw NSError(domain: "AudioResampler", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Audio file is too large to resample safely"
            ])
        }
        guard AudioRecordingFormatPolicy.isUsableSampleRate(srcFormat.sampleRate),
              AudioRecordingFormatPolicy.isUsableSampleRate(targetRate),
              srcFormat.channelCount > 0 else {
            throw NSError(domain: "AudioResampler", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Audio file has an invalid sample rate or channel count"
            ])
        }
        let srcFrames = AVAudioFrameCount(file.length)

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
        let totalDstFrameCount = Double(srcFrames) * ratio + 64
        guard totalDstFrameCount.isFinite,
              totalDstFrameCount > 0,
              totalDstFrameCount <= Double(AVAudioFrameCount.max),
              totalDstFrameCount * Double(MemoryLayout<Float>.stride) <= Double(UInt32.max) else {
            throw NSError(domain: "AudioResampler", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Converted audio frame count is unsafe"
            ])
        }

        let outputCapacity = Int(totalDstFrameCount)
        var output = [Float]()
        output.reserveCapacity(outputCapacity)

        // Read chunks from the file on demand inside the input block.
        // The converter calls this block repeatedly until we signal .endOfStream,
        // keeping the converter in a continuous state (no terminal state between chunks).
        let chunkDuration: Double = 30.0  // seconds per read
        let chunkFrames = AVAudioFrameCount(srcFormat.sampleRate * chunkDuration)

        var inputBlockError: Error?
        var didSignalEndOfStream = false
        let outputChunkFrames = AVAudioFrameCount(targetRate * 30.0)
        while true {
            guard let dstBuffer = AVAudioPCMBuffer(pcmFormat: dstFormat, frameCapacity: outputChunkFrames) else {
                throw NSError(domain: "AudioResampler", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to create destination audio buffer"
                ])
            }

            var conversionError: NSError?
            let status = converter.convert(to: dstBuffer, error: &conversionError) { _, outStatus in
                guard !didSignalEndOfStream else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard file.framePosition < file.length else {
                    didSignalEndOfStream = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let framesToRead = min(chunkFrames, AVAudioFrameCount(file.length - file.framePosition))
                guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: framesToRead) else {
                    inputBlockError = NSError(domain: "AudioResampler", code: 5, userInfo: [
                        NSLocalizedDescriptionKey: "Buffer allocation failed during resampling at frame \(file.framePosition)/\(file.length)"
                    ])
                    didSignalEndOfStream = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try file.read(into: srcBuffer, frameCount: framesToRead)
                } catch {
                    inputBlockError = error
                    didSignalEndOfStream = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                outStatus.pointee = .haveData
                return srcBuffer
            }

            if status == .error, let conversionError {
                throw conversionError
            }

            if let inputBlockError { throw inputBlockError }

            if dstBuffer.frameLength > 0 {
                guard let floatData = dstBuffer.floatChannelData else {
                    throw NSError(domain: "AudioResampler", code: 2, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to get float channel data from converted buffer"
                    ])
                }
                output.append(contentsOf: UnsafeBufferPointer(start: floatData[0], count: Int(dstBuffer.frameLength)))
            }

            if didSignalEndOfStream && dstBuffer.frameLength == 0 {
                break
            }
        }

        // Validate output length — catch silent truncation from converter issues
        let expectedMinFrames = Int(Double(srcFrames) * ratio * 0.9)
        if output.count < expectedMinFrames {
            AppLogger.transcription.warning("Audio resampling produced fewer frames than expected", [
                "expected": "\(expectedMinFrames)", "actual": "\(output.count)", "source": url.lastPathComponent
            ])
        }

        return output
    }

    /// Extract a time slice from samples array.
    /// Returns samples between startTime and endTime (in seconds) at the given sample rate.
    public static func extractSlice(
        from samples: [Float],
        sampleRate: Double,
        startTime: Double,
        endTime: Double
    ) -> [Float] {
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate),
              startTime.isFinite,
              endTime.isFinite else {
            return []
        }
        let rawStartSample = startTime * sampleRate
        let rawEndSample = endTime * sampleRate
        guard rawStartSample.isFinite,
              rawEndSample.isFinite,
              rawStartSample >= Double(Int.min),
              rawEndSample >= Double(Int.min),
              rawStartSample <= Double(Int.max),
              rawEndSample <= Double(Int.max) else {
            return []
        }
        let startSample = max(0, Int(rawStartSample))
        let endSample = min(samples.count, Int(rawEndSample))
        guard startSample < endSample else { return [] }
        return Array(samples[startSample..<endSample])
    }
}
