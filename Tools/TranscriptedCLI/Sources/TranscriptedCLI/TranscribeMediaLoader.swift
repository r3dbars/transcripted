import AVFoundation
import CoreMedia
import Foundation

enum TranscribeMediaLoaderError: LocalizedError {
    case emptyAudio(String)
    case noAudioTrack(String)
    case unreadableMedia(fileName: String, fileExtension: String, detail: String)

    var errorDescription: String? {
        switch self {
        case .emptyAudio(let fileName):
            return "\(fileName) contains no decodable audio samples."
        case .noAudioTrack(let fileName):
            return "\(fileName) has no audio track to transcribe."
        case .unreadableMedia(let fileName, let fileExtension, let detail):
            var message = "Could not decode audio from \(fileName): \(detail)"
            if TranscribeMediaLoader.likelyUnsupportedContainerExtensions.contains(fileExtension.lowercased()) {
                message += " The .\(fileExtension.lowercased()) container is not supported by macOS media decoding."
                    + " Convert it first, e.g. `ffmpeg -i input.\(fileExtension.lowercased()) -ac 1 -ar 16000 output.wav`."
            }
            return message
        }
    }
}

/// Decodes an audio or video file into 16kHz mono Float32 samples for the
/// local Parakeet model. Audio files go through `AVAudioFile` +
/// `AVAudioConverter`; video containers (MP4, MOV, M4V, ...) fall back to
/// `AVAssetReader`, which mixes every audio track down to one mono stream.
enum TranscribeMediaLoader {
    static let targetSampleRate: Double = 16000

    /// Containers AVFoundation generally cannot open, used only to improve
    /// the error message after both decode paths have failed.
    static let likelyUnsupportedContainerExtensions: Set<String> = [
        "webm", "mkv", "ogg", "ogv", "opus", "wma", "wmv", "flv",
    ]

    struct DecodedAudio {
        let samples: [Float]
        var durationSeconds: Double {
            Double(samples.count) / TranscribeMediaLoader.targetSampleRate
        }
    }

    static func loadSamples(from url: URL) async throws -> DecodedAudio {
        // Always give the asset-reader path a chance: even oddities the
        // AVAudioFile path rejects (unusual formats, containers it half-opens)
        // can still decode through AVAssetReader.
        let audioFileFailure: Error
        do {
            return try loadWithAudioFile(url: url)
        } catch {
            audioFileFailure = error
        }

        do {
            return try await loadWithAssetReader(url: url)
        } catch let error as TranscribeMediaLoaderError {
            throw error
        } catch {
            throw TranscribeMediaLoaderError.unreadableMedia(
                fileName: url.lastPathComponent,
                fileExtension: url.pathExtension,
                detail: "audio decode failed (\(audioFileFailure.localizedDescription));"
                    + " video decode failed (\(error.localizedDescription))"
            )
        }
    }

    // MARK: - AVAudioFile path (audio containers)

    /// Streaming decode + resample in one `AVAudioConverter.convert` call,
    /// mirroring the app's `AudioResampler`: a single convert with an
    /// on-demand input block avoids the converter terminal-state bug that
    /// truncates output when `.endOfStream` is signalled between chunks.
    private static func loadWithAudioFile(url: URL) throws -> DecodedAudio {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat

        guard file.length > 0 else {
            throw TranscribeMediaLoaderError.emptyAudio(url.lastPathComponent)
        }
        guard file.length <= Int64(AVAudioFrameCount.max),
              srcFormat.sampleRate > 0,
              srcFormat.channelCount > 0
        else {
            throw decodeFailure(url: url, detail: "unsupported audio format (\(srcFormat.sampleRate)Hz, \(srcFormat.channelCount)ch)")
        }

        guard let dstFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw decodeFailure(url: url, detail: "could not create \(Int(targetSampleRate))Hz mono target format")
        }

        if srcFormat.sampleRate == targetSampleRate,
           srcFormat.channelCount == 1,
           srcFormat.commonFormat == .pcmFormatFloat32 {
            return try readWholeFile(file)
        }

        guard let converter = AVAudioConverter(from: srcFormat, to: dstFormat) else {
            throw decodeFailure(url: url, detail: "could not convert \(srcFormat.sampleRate)Hz \(srcFormat.channelCount)ch audio to \(Int(targetSampleRate))Hz mono")
        }

        let ratio = targetSampleRate / srcFormat.sampleRate
        let estimatedDstFrames = Double(file.length) * ratio + 64
        guard estimatedDstFrames.isFinite,
              estimatedDstFrames > 0,
              estimatedDstFrames <= Double(AVAudioFrameCount.max)
        else {
            throw decodeFailure(url: url, detail: "converted audio frame count is unsafe")
        }

        guard let dstBuffer = AVAudioPCMBuffer(
            pcmFormat: dstFormat,
            frameCapacity: AVAudioFrameCount(estimatedDstFrames)
        ) else {
            throw decodeFailure(url: url, detail: "could not allocate destination audio buffer")
        }

        let chunkFrames = AVAudioFrameCount(srcFormat.sampleRate * 30.0)
        var conversionError: NSError?
        var inputBlockError: Error?
        let status = converter.convert(to: dstBuffer, error: &conversionError) { _, outStatus in
            guard file.framePosition < file.length else {
                outStatus.pointee = .endOfStream
                return nil
            }
            let framesToRead = min(chunkFrames, AVAudioFrameCount(file.length - file.framePosition))
            guard let srcBuffer = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: framesToRead) else {
                inputBlockError = TranscribeMediaLoaderError.unreadableMedia(
                    fileName: url.lastPathComponent,
                    fileExtension: url.pathExtension,
                    detail: "buffer allocation failed at frame \(file.framePosition)/\(file.length)"
                )
                outStatus.pointee = .endOfStream
                return nil
            }
            do {
                try file.read(into: srcBuffer, frameCount: framesToRead)
            } catch {
                inputBlockError = error
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return srcBuffer
        }

        if status == .error, let conversionError {
            throw conversionError
        }
        if let inputBlockError {
            throw inputBlockError
        }

        guard let channelData = dstBuffer.floatChannelData, dstBuffer.frameLength > 0 else {
            throw TranscribeMediaLoaderError.emptyAudio(url.lastPathComponent)
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(dstBuffer.frameLength)))
        return DecodedAudio(samples: samples)
    }

    private static func readWholeFile(_ file: AVAudioFile) throws -> DecodedAudio {
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw decodeFailure(url: file.url, detail: "could not allocate audio buffer")
        }
        try file.read(into: buffer)
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else {
            throw TranscribeMediaLoaderError.emptyAudio(file.url.lastPathComponent)
        }
        let samples = Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
        return DecodedAudio(samples: samples)
    }

    // MARK: - AVAssetReader path (video containers)

    private static func loadWithAssetReader(url: URL) async throws -> DecodedAudio {
        let asset = AVURLAsset(url: url)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw TranscribeMediaLoaderError.noAudioTrack(url.lastPathComponent)
        }

        let reader = try AVAssetReader(asset: asset)
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: outputSettings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw decodeFailure(url: url, detail: "asset reader rejected the audio output configuration")
        }
        reader.add(output)

        guard reader.startReading() else {
            throw decodeFailure(url: url, detail: reader.error?.localizedDescription ?? "asset reader failed to start")
        }

        var samples: [Float] = []
        while let sampleBuffer = output.copyNextSampleBuffer() {
            guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteLength = CMBlockBufferGetDataLength(blockBuffer)
            let sampleCount = byteLength / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }

            let previousCount = samples.count
            samples.append(contentsOf: repeatElement(0, count: sampleCount))
            let copyStatus = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return OSStatus(kCMBlockBufferBadPointerParameterErr) }
                return CMBlockBufferCopyDataBytes(
                    blockBuffer,
                    atOffset: 0,
                    dataLength: sampleCount * MemoryLayout<Float>.size,
                    destination: base.advanced(by: previousCount * MemoryLayout<Float>.size)
                )
            }
            guard copyStatus == kCMBlockBufferNoErr else {
                throw decodeFailure(url: url, detail: "audio sample copy failed (status \(copyStatus))")
            }
        }

        if reader.status == .failed {
            throw decodeFailure(url: url, detail: reader.error?.localizedDescription ?? "asset reader failed while decoding")
        }
        guard !samples.isEmpty else {
            throw TranscribeMediaLoaderError.emptyAudio(url.lastPathComponent)
        }
        return DecodedAudio(samples: samples)
    }

    private static func decodeFailure(url: URL, detail: String) -> TranscribeMediaLoaderError {
        .unreadableMedia(
            fileName: url.lastPathComponent,
            fileExtension: url.pathExtension,
            detail: detail
        )
    }
}
