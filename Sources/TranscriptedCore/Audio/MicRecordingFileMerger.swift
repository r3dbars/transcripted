import Foundation
@preconcurrency import AVFoundation

enum MicRecordingFileMerger {
    private static let outputSampleRate: Double = 16_000
    private static let chunkSize = 16_000 * 30
    private static let chunkDurationSeconds: Double = 30

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
            interleaved: false
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

                try appendSegment(segment.url, to: mergedFile, outputFormat: outputFormat)
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

    private static func appendSegment(
        _ url: URL,
        to outputFile: AVAudioFile,
        outputFormat: AVAudioFormat
    ) throws {
        let sourceFile = try AVAudioFile(forReading: url)
        let sourceFormat = sourceFile.processingFormat

        guard sourceFile.length > 0 else {
            throw PipelineError.emptyAudioFile
        }
        guard sourceFile.length <= Int64(AVAudioFrameCount.max) else {
            throw NSError(domain: "MicRecordingFileMerger", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Audio segment is too large to merge safely"
            ])
        }
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sourceFormat.sampleRate),
              AudioRecordingFormatPolicy.isUsableSampleRate(outputFormat.sampleRate),
              sourceFormat.channelCount > 0 else {
            throw NSError(domain: "MicRecordingFileMerger", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Audio segment has an invalid sample rate or channel count"
            ])
        }
        if formatsMatch(sourceFormat, outputFormat) {
            try appendCompatibleSegment(sourceFile, to: outputFile, format: outputFormat)
            return
        }
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw NSError(domain: "MicRecordingFileMerger", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create segment converter"
            ])
        }

        let outputCapacity = AVAudioFrameCount(outputFormat.sampleRate * chunkDurationSeconds)
        let inputCapacity = AVAudioFrameCount(sourceFormat.sampleRate * chunkDurationSeconds)
        var inputEnded = false
        var inputBlockError: Error?
        var noProgressIterations = 0

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: outputCapacity
            ) else {
                throw NSError(domain: "MicRecordingFileMerger", code: 7, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to allocate merged segment output buffer"
                ])
            }

            var conversionError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                guard !inputEnded, sourceFile.framePosition < sourceFile.length else {
                    inputEnded = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                let remainingFrames = sourceFile.length - sourceFile.framePosition
                let framesToRead = min(inputCapacity, AVAudioFrameCount(remainingFrames))
                guard framesToRead > 0,
                      let inputBuffer = AVAudioPCMBuffer(
                        pcmFormat: sourceFormat,
                        frameCapacity: framesToRead
                      ) else {
                    inputBlockError = NSError(domain: "MicRecordingFileMerger", code: 8, userInfo: [
                        NSLocalizedDescriptionKey: "Failed to allocate merged segment input buffer"
                    ])
                    inputEnded = true
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    try sourceFile.read(into: inputBuffer, frameCount: framesToRead)
                    outStatus.pointee = .haveData
                    return inputBuffer
                } catch {
                    inputBlockError = error
                    inputEnded = true
                    outStatus.pointee = .endOfStream
                    return nil
                }
            }

            if let conversionError { throw conversionError }
            if let inputBlockError { throw inputBlockError }

            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
                noProgressIterations = 0
            } else {
                noProgressIterations += 1
            }

            switch status {
            case .haveData, .inputRanDry:
                guard noProgressIterations < 32 else {
                    throw NSError(domain: "MicRecordingFileMerger", code: 9, userInfo: [
                        NSLocalizedDescriptionKey: "Segment conversion made no progress"
                    ])
                }
                continue
            case .endOfStream:
                return
            case .error:
                throw conversionError ?? NSError(domain: "MicRecordingFileMerger", code: 10, userInfo: [
                    NSLocalizedDescriptionKey: "Segment conversion failed"
                ])
            @unknown default:
                throw NSError(domain: "MicRecordingFileMerger", code: 12, userInfo: [
                    NSLocalizedDescriptionKey: "Segment conversion returned an unknown status"
                ])
            }
        }
    }

    private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
        lhs.commonFormat == rhs.commonFormat
            && lhs.sampleRate == rhs.sampleRate
            && lhs.channelCount == rhs.channelCount
            && lhs.isInterleaved == rhs.isInterleaved
    }

    private static func appendCompatibleSegment(
        _ sourceFile: AVAudioFile,
        to outputFile: AVAudioFile,
        format: AVAudioFormat
    ) throws {
        while sourceFile.framePosition < sourceFile.length {
            let remainingFrames = sourceFile.length - sourceFile.framePosition
            let framesToRead = min(AVAudioFrameCount(chunkSize), AVAudioFrameCount(remainingFrames))
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: framesToRead
            ) else {
                throw NSError(domain: "MicRecordingFileMerger", code: 13, userInfo: [
                    NSLocalizedDescriptionKey: "Failed to allocate direct segment buffer"
                ])
            }

            try sourceFile.read(into: buffer, frameCount: framesToRead)
            if buffer.frameLength > 0 {
                try outputFile.write(from: buffer)
            }
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
