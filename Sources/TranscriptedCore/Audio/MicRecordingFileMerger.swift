import Foundation
@preconcurrency import AVFoundation

enum MicRecordingFileMerger {
    private static let outputSampleRate: Double = 16_000
    private static let chunkSize = 16_000 * 30

    static func merge(primaryURL: URL?, segments: [MicRecordingSegment]) throws -> URL? {
        guard let primaryURL else { return segments.last?.url }
        guard segments.count > 1 else { return primaryURL }

        let mergedFilename = primaryURL.deletingPathExtension().lastPathComponent + "_merged.wav"
        let mergedURL = primaryURL.deletingLastPathComponent().appendingPathComponent(mergedFilename)

        try? FileManager.default.removeItem(at: mergedURL)

        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: outputSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "MicRecordingFileMerger", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create merged mic format"
            ])
        }

        do {
            let mergedFile = try AVAudioFile(
                forWriting: mergedURL,
                settings: outputFormat.settings,
                commonFormat: outputFormat.commonFormat,
                interleaved: outputFormat.isInterleaved
            )

            for (index, segment) in segments.enumerated() {
                if index > 0 {
                    let silenceSamples = MicRecordingMergePlan.silenceSampleCount(
                        before: segment,
                        sampleRate: outputFormat.sampleRate
                    )
                    if silenceSamples > 0 {
                        try writeSilence(frameCount: silenceSamples, to: mergedFile, format: outputFormat)
                    }
                }

                let samples = try AudioResampler.loadAndResample(
                    url: segment.url,
                    targetRate: outputSampleRate
                )
                try writeSamples(samples, to: mergedFile, format: outputFormat)
            }

            FileManager.default.restrictToOwnerOnly(atPath: mergedURL.path)
            for segment in Set(segments.map(\.url)) {
                try? FileManager.default.removeItem(at: segment)
            }
            return mergedURL
        } catch {
            try? FileManager.default.removeItem(at: mergedURL)
            throw error
        }
    }

    private static func writeSamples(
        _ samples: [Float],
        to file: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        var offset = 0

        while offset < samples.count {
            let count = min(chunkSize, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ) else {
                throw NSError(domain: "MicRecordingFileMerger", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to allocate merged mic buffer"
                ])
            }

            buffer.frameLength = AVAudioFrameCount(count)
            if let channelData = buffer.floatChannelData?[0] {
                samples.withUnsafeBufferPointer { pointer in
                    channelData.update(from: pointer.baseAddress! + offset, count: count)
                }
            }

            try file.write(from: buffer)
            offset += count
        }
    }

    private static func writeSilence(
        frameCount: Int,
        to file: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        var remaining = frameCount

        while remaining > 0 {
            let count = min(chunkSize, remaining)
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(count)
            ) else {
                throw NSError(domain: "MicRecordingFileMerger", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to allocate silence buffer"
                ])
            }

            buffer.frameLength = AVAudioFrameCount(count)
            if let channelData = buffer.floatChannelData?[0] {
                channelData.initialize(repeating: 0, count: count)
            }

            try file.write(from: buffer)
            remaining -= count
        }
    }
}
