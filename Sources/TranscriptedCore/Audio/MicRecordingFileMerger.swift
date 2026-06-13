import Foundation
@preconcurrency import AVFoundation

struct MicRecordingMergeOutcome {
    let url: URL?
    let segmentCount: Int
    /// Segments that contributed at least one frame of real audio.
    let appendedSegments: Int
    /// Segments dropped entirely (missing, unreadable after repair, or empty).
    let skippedSegments: Int
    /// Segments whose unfinalized WAV header was patched before reading.
    let repairedSegments: Int
    /// Segments that failed mid-read and had their remainder padded with silence.
    let paddedSegments: Int

    /// True when every recorded frame made it into the merged file. When false,
    /// the source segment files are kept on disk for recovery.
    var isFullFidelity: Bool { skippedSegments == 0 && paddedSegments == 0 }

    static func passthrough(url: URL?, segmentCount: Int) -> MicRecordingMergeOutcome {
        MicRecordingMergeOutcome(
            url: url,
            segmentCount: segmentCount,
            appendedSegments: 0,
            skippedSegments: 0,
            repairedSegments: 0,
            paddedSegments: 0
        )
    }
}

enum MicRecordingFileMerger {
    private static let outputSampleRate: Double = 16_000
    private static let chunkSize = 16_000 * 30
    private static let chunkDurationSeconds: Double = 30

    /// Wraps failures writing to the merged output file (disk full, etc.) so
    /// they abort the merge, unlike source-segment failures which are salvaged.
    private struct MergedFileWriteError: Error {
        let underlying: Error
    }

    private struct SegmentCounters {
        var appended = 0
        var skipped = 0
        var repaired = 0
        var padded = 0
    }

    static func merge(primaryURL: URL?, segments: [MicRecordingSegment]) throws -> MicRecordingMergeOutcome {
        guard let primaryURL else {
            return .passthrough(url: segments.last?.url, segmentCount: segments.count)
        }
        guard segments.count > 1 else {
            return .passthrough(url: primaryURL, segmentCount: segments.count)
        }

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

        let counters: SegmentCounters
        do {
            counters = try writeMergedFile(at: mergedURL, segments: segments, outputFormat: outputFormat)
        } catch let error as MergedFileWriteError {
            try? FileManager.default.removeItem(at: mergedURL)
            throw error.underlying
        } catch {
            try? FileManager.default.removeItem(at: mergedURL)
            throw error
        }

        // A merged file with no real audio (every segment skipped) is useless;
        // throwing lets the caller fall back to the primary URL.
        guard counters.appended > 0 else {
            try? FileManager.default.removeItem(at: mergedURL)
            throw PipelineError.emptyAudioFile
        }

        FileManager.default.restrictToOwnerOnly(atPath: mergedURL.path)

        let outcome = MicRecordingMergeOutcome(
            url: mergedURL,
            segmentCount: segments.count,
            appendedSegments: counters.appended,
            skippedSegments: counters.skipped,
            repairedSegments: counters.repaired,
            paddedSegments: counters.padded
        )

        if outcome.isFullFidelity {
            for segment in Set(segments.map(\.url)) {
                try? FileManager.default.removeItem(at: segment)
            }
        }

        return outcome
    }

    private static func writeMergedFile(
        at mergedURL: URL,
        segments: [MicRecordingSegment],
        outputFormat: AVAudioFormat
    ) throws -> SegmentCounters {
        let mergedFile = try AVAudioFile(
            forWriting: mergedURL,
            settings: outputFormat.settings,
            commonFormat: outputFormat.commonFormat,
            interleaved: outputFormat.isInterleaved
        )
        // Finalize the merged file's own header before the caller validates it
        // or deletes the source segments.
        defer { mergedFile.close() }

        var counters = SegmentCounters()
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

            try appendSegmentSalvaging(
                segment.url,
                to: mergedFile,
                outputFormat: outputFormat,
                counters: &counters
            )
        }
        return counters
    }

    /// Appends one segment, downgrading source-side failures to skips or
    /// silence padding so a single bad segment cannot abort the whole merge
    /// and silently drop every other segment's audio. Output-side failures
    /// still propagate via `MergedFileWriteError`.
    private static func appendSegmentSalvaging(
        _ url: URL,
        to outputFile: AVAudioFile,
        outputFormat: AVAudioFormat,
        counters: inout SegmentCounters
    ) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            counters.skipped += 1
            AppLogger.audioMic.warning("Skipping missing mic segment during merge", [
                "file": url.lastPathComponent
            ])
            return
        }

        // A crashed or leaked writer leaves the WAV header sizes unpatched,
        // which reads back as a zero-length file even though the PCM payload
        // is on disk. Recompute the sizes from the actual file before reading.
        do {
            if try WAVHeaderRepair.repairIfNeeded(at: url) {
                counters.repaired += 1
                AppLogger.audioMic.warning("Repaired unfinalized mic segment header before merge", [
                    "file": url.lastPathComponent
                ])
            }
        } catch {
            // Not parseable as RIFF/WAVE; the open below decides whether the
            // segment is readable at all.
        }

        let sourceFile: AVAudioFile
        do {
            sourceFile = try AVAudioFile(forReading: url)
        } catch {
            counters.skipped += 1
            AppLogger.audioMic.warning("Skipping unreadable mic segment during merge", [
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
            return
        }
        defer { sourceFile.close() }

        let sourceFormat = sourceFile.processingFormat
        guard sourceFile.length > 0 else {
            counters.skipped += 1
            AppLogger.audioMic.warning("Skipping empty mic segment during merge", [
                "file": url.lastPathComponent
            ])
            return
        }
        guard sourceFile.length <= Int64(AVAudioFrameCount.max),
              AudioRecordingFormatPolicy.isUsableSampleRate(sourceFormat.sampleRate),
              AudioRecordingFormatPolicy.isUsableSampleRate(outputFormat.sampleRate),
              sourceFormat.channelCount > 0 else {
            counters.skipped += 1
            AppLogger.audioMic.warning("Skipping mic segment with unusable format during merge", [
                "file": url.lastPathComponent,
                "frames": "\(sourceFile.length)",
                "sampleRate": "\(sourceFormat.sampleRate)",
                "channels": "\(sourceFormat.channelCount)"
            ])
            return
        }

        let expectedOutputFrames = Int64(
            (Double(sourceFile.length) / sourceFormat.sampleRate * outputFormat.sampleRate).rounded(.down)
        )
        var outputFramesWritten: Int64 = 0

        do {
            try appendSegment(
                sourceFile,
                to: outputFile,
                outputFormat: outputFormat,
                outputFramesWritten: &outputFramesWritten
            )
            counters.appended += 1
        } catch let error as MergedFileWriteError {
            throw error
        } catch {
            // Source-side failure partway through. Keep what was read and pad
            // the remainder with silence so the mic timeline stays aligned
            // with the system-audio track.
            if outputFramesWritten > 0 {
                counters.appended += 1
            }
            counters.padded += 1
            let remaining = max(Int64(0), expectedOutputFrames - outputFramesWritten)
            if remaining > 0 {
                try writeSilence(frameCount: Int(remaining), to: outputFile, format: outputFormat)
            }
            AppLogger.audioMic.warning("Padded mic segment after mid-read failure during merge", [
                "file": url.lastPathComponent,
                "framesKept": "\(outputFramesWritten)",
                "framesPadded": "\(remaining)",
                "error": error.localizedDescription
            ])
        }
    }

    private static func appendSegment(
        _ sourceFile: AVAudioFile,
        to outputFile: AVAudioFile,
        outputFormat: AVAudioFormat,
        outputFramesWritten: inout Int64
    ) throws {
        let sourceFormat = sourceFile.processingFormat

        if formatsMatch(sourceFormat, outputFormat) {
            try appendCompatibleSegment(
                sourceFile,
                to: outputFile,
                format: outputFormat,
                outputFramesWritten: &outputFramesWritten
            )
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

            if outputBuffer.frameLength > 0 {
                do {
                    try outputFile.write(from: outputBuffer)
                } catch {
                    throw MergedFileWriteError(underlying: error)
                }
                outputFramesWritten += Int64(outputBuffer.frameLength)
                noProgressIterations = 0
            } else {
                noProgressIterations += 1
            }

            if let conversionError { throw conversionError }
            if let inputBlockError { throw inputBlockError }

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
        format: AVAudioFormat,
        outputFramesWritten: inout Int64
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
                do {
                    try outputFile.write(from: buffer)
                } catch {
                    throw MergedFileWriteError(underlying: error)
                }
                outputFramesWritten += Int64(buffer.frameLength)
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

            do {
                try file.write(from: buffer)
            } catch {
                throw MergedFileWriteError(underlying: error)
            }
            remaining -= count
        }
    }
}
