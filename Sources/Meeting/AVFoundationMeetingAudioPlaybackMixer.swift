import AVFoundation
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct AVFoundationMeetingAudioPlaybackMixer: MeetingAudioPlaybackMixing {
    private static let chunkFrames: AVAudioFrameCount = 4096
    private static let systemGain: Float = 0.95
    private static let microphoneGain: Float = 0.90

    func createPlaybackWAV(
        microphoneURL: URL,
        systemURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) async throws {
        try mix(
            microphoneURL: microphoneURL,
            systemURL: systemURL,
            destinationURL: destinationURL,
            fileManager: fileManager
        )
    }

    private func mix(
        microphoneURL: URL,
        systemURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let microphoneFile = try AVAudioFile(forReading: microphoneURL)
        let systemFile = try AVAudioFile(forReading: systemURL)
        let microphoneFormat = microphoneFile.processingFormat
        let systemFormat = systemFile.processingFormat

        let outputChannelCount = max(
            1,
            Int(max(microphoneFormat.channelCount, systemFormat.channelCount))
        )
        guard let outputFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: systemFormat.sampleRate,
            channels: AVAudioChannelCount(outputChannelCount),
            interleaved: false
        ) else {
            throw MeetingAudioStorageError.mixBufferAllocationFailed
        }

        try? fileManager.removeItem(at: destinationURL)
        do {
            let outputFile = try AVAudioFile(
                forWriting: destinationURL,
                settings: outputFormat.settings,
                commonFormat: outputFormat.commonFormat,
                interleaved: outputFormat.isInterleaved
            )

            var microphoneDone = false
            var systemDone = false
            let microphoneReader = try MixInputReader(file: microphoneFile, outputFormat: outputFormat)
            let systemReader = try MixInputReader(file: systemFile, outputFormat: outputFormat)

            while !microphoneDone || !systemDone {
                let microphoneBuffer = try microphoneReader.read(maximumFrames: Self.chunkFrames)
                let systemBuffer = try systemReader.read(maximumFrames: Self.chunkFrames)

                microphoneDone = microphoneBuffer == nil
                systemDone = systemBuffer == nil

                let frameCount = max(
                    Int(microphoneBuffer?.frameLength ?? 0),
                    Int(systemBuffer?.frameLength ?? 0)
                )
                guard frameCount > 0 else { continue }

                guard let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(frameCount)
                ) else {
                    throw MeetingAudioStorageError.mixBufferAllocationFailed
                }
                outputBuffer.frameLength = AVAudioFrameCount(frameCount)

                mix(
                    microphoneBuffer: microphoneBuffer,
                    systemBuffer: systemBuffer,
                    outputBuffer: outputBuffer,
                    frameCount: frameCount,
                    outputChannelCount: outputChannelCount
                )
                try outputFile.write(from: outputBuffer)
            }

            fileManager.restrictFileToOwnerOnly(at: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private func mix(
        microphoneBuffer: AVAudioPCMBuffer?,
        systemBuffer: AVAudioPCMBuffer?,
        outputBuffer: AVAudioPCMBuffer,
        frameCount: Int,
        outputChannelCount: Int
    ) {
        // Relative loudness cannot distinguish speaker bleed from independent
        // microphone speech. Keep both tracks, including quiet and overlapping
        // speech, at stable gains rather than gating entire blocks of the mic.
        // Buffer properties are read once per chunk, not per sample.
        let system = MixChunkView(systemBuffer), microphone = MixChunkView(microphoneBuffer)
        let output = MixChunkView(outputBuffer)
        guard let out = output.data else { return }
        let writable = max(0, min(frameCount, output.frameLength))
        withExtendedLifetime((microphoneBuffer, systemBuffer, outputBuffer)) {
            for channel in 0..<outputChannelCount {
                let destination = min(channel, output.channelCount - 1)
                for frame in 0..<writable {
                    let mixedSample = (system.sample(channel: channel, frame: frame) * Self.systemGain)
                        + (microphone.sample(channel: channel, frame: frame) * Self.microphoneGain)
                    if output.isInterleaved {
                        out[0][frame * output.channelCount + destination] = limited(mixedSample)
                    } else {
                        out[destination][frame] = limited(mixedSample)
                    }
                }
            }
        }
    }

    /// Plain-pointer view of one chunk's buffer; only valid while `mix` holds the buffers.
    private struct MixChunkView {
        let data: UnsafePointer<UnsafeMutablePointer<Float>>?
        let frameLength: Int
        let channelCount: Int
        let isInterleaved: Bool

        init(_ buffer: AVAudioPCMBuffer?) {
            guard let buffer, let channelData = buffer.floatChannelData else {
                (data, frameLength, channelCount, isInterleaved) = (nil, 0, 1, false)
                return
            }
            data = UnsafePointer(channelData)
            frameLength = Int(buffer.frameLength)
            channelCount = max(1, Int(buffer.format.channelCount))
            isInterleaved = buffer.format.isInterleaved
        }

        @inline(__always) func sample(channel: Int, frame: Int) -> Float {
            guard let data, frame >= 0, frame < frameLength else { return 0 }
            let sourceChannel = channelCount == 1 ? 0 : min(channel, channelCount - 1)
            return isInterleaved ? data[0][frame * channelCount + sourceChannel] : data[sourceChannel][frame]
        }
    }

    private func limited(_ sample: Float) -> Float {
        min(0.98, max(-0.98, sample))
    }

    private final class MixInputReader {
        private let file: AVAudioFile
        private let outputFormat: AVAudioFormat
        private let converter: AVAudioConverter?
        private var didReachInputEnd = false
        private var didReachOutputEnd = false

        init(file: AVAudioFile, outputFormat: AVAudioFormat) throws {
            self.file = file
            self.outputFormat = outputFormat
            if Self.formatsMatch(file.processingFormat, outputFormat) {
                self.converter = nil
            } else {
                guard let converter = AVAudioConverter(from: file.processingFormat, to: outputFormat) else {
                    throw MeetingAudioStorageError.unsupportedPlaybackMixFormat
                }
                self.converter = converter
            }
        }

        func read(maximumFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
            guard !didReachOutputEnd else { return nil }
            guard let converter else {
                return try readDirect(maximumFrames: maximumFrames)
            }
            return try readConverted(maximumFrames: maximumFrames, converter: converter)
        }

        private func readDirect(maximumFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
            let remainingFrames = file.length - file.framePosition
            guard remainingFrames > 0 else {
                didReachOutputEnd = true
                return nil
            }

            let framesToRead = min(AVAudioFramePosition(maximumFrames), remainingFrames)
            guard framesToRead > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat,
                    frameCapacity: AVAudioFrameCount(framesToRead)
                  ) else {
                return nil
            }

            try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
            if buffer.frameLength == 0 {
                didReachOutputEnd = true
                return nil
            }
            return buffer
        }

        private func readConverted(
            maximumFrames: AVAudioFrameCount,
            converter: AVAudioConverter
        ) throws -> AVAudioPCMBuffer? {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat,
                frameCapacity: maximumFrames
            ) else {
                throw MeetingAudioStorageError.mixBufferAllocationFailed
            }

            var conversionError: NSError?
            var sourceReadError: NSError?
            let status = converter.convert(to: outputBuffer, error: &conversionError) { packetCount, outStatus in
                if self.didReachInputEnd {
                    outStatus.pointee = .endOfStream
                    return nil
                }

                do {
                    let sourceBuffer = try self.readSourceBuffer(maximumFrames: packetCount)
                    guard let sourceBuffer else {
                        self.didReachInputEnd = true
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    outStatus.pointee = .haveData
                    return sourceBuffer
                } catch {
                    sourceReadError = error as NSError
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            if let failure = sourceReadError ?? conversionError {
                throw failure
            }

            switch status {
            case .haveData, .inputRanDry:
                if outputBuffer.frameLength > 0 {
                    return outputBuffer
                }
                return try read(maximumFrames: maximumFrames)
            case .endOfStream:
                didReachOutputEnd = true
                return outputBuffer.frameLength > 0 ? outputBuffer : nil
            case .error:
                throw MeetingAudioStorageError.unsupportedPlaybackMixFormat
            @unknown default:
                throw MeetingAudioStorageError.unsupportedPlaybackMixFormat
            }
        }

        private func readSourceBuffer(maximumFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
            let remainingFrames = file.length - file.framePosition
            guard remainingFrames > 0 else { return nil }

            let framesToRead = min(AVAudioFramePosition(maximumFrames), remainingFrames)
            guard framesToRead > 0,
                  let buffer = AVAudioPCMBuffer(
                    pcmFormat: file.processingFormat,
                    frameCapacity: AVAudioFrameCount(framesToRead)
                  ) else {
                return nil
            }

            try file.read(into: buffer, frameCount: AVAudioFrameCount(framesToRead))
            return buffer.frameLength > 0 ? buffer : nil
        }

        private static func formatsMatch(_ lhs: AVAudioFormat, _ rhs: AVAudioFormat) -> Bool {
            lhs.commonFormat == rhs.commonFormat
                && lhs.sampleRate == rhs.sampleRate
                && lhs.channelCount == rhs.channelCount
                && lhs.isInterleaved == rhs.isInterleaved
        }
    }
}
