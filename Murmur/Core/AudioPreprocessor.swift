import Foundation
import AVFoundation

/// Audio preprocessing utility for optimizing recordings before cloud transcription upload
/// Reduces file sizes by ~34x through downsampling and format conversion
@available(macOS 14.0, *)
class AudioPreprocessor {

    /// Cloud transcription optimized format: 16kHz mono Int16
    /// - 16kHz sample rate is optimal for speech recognition
    /// - Mono reduces size by 50% vs stereo with no quality loss for speech
    /// - Int16 reduces size by 50% vs Float32 while preserving speech frequencies
    static let cloudTranscriptionFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 1,
            interleaved: true
        ) else {
            fatalError("Failed to create cloud transcription audio format")
        }
        return format
    }()

    /// Prepare audio file for cloud transcription upload
    /// - Downsamples to 16kHz (from 48-96kHz)
    /// - Converts to mono (averages channels)
    /// - Converts to Int16 (from Float32)
    /// - Returns URL to temp file (caller must delete when done)
    ///
    /// Performance: ~0.5-1s per 30 minutes of audio, <50MB memory
    static func prepareForCloudTranscription(audioURL: URL) async throws -> URL {
        let inputFile = try AVAudioFile(forReading: audioURL)
        let inputFormat = inputFile.processingFormat

        // Log input format for debugging
        let inputSizeMB = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int)
            .map { Double($0) / 1_000_000 } ?? 0
        print("🔄 Preprocessing: \(audioURL.lastPathComponent)")
        print("   Input: \(Int(inputFormat.sampleRate))Hz, \(inputFormat.channelCount)ch, \(inputFormat.commonFormat == .pcmFormatFloat32 ? "Float32" : "Int16"), \(String(format: "%.1f", inputSizeMB))MB")

        // Skip if already in optimal format (unlikely but possible)
        if inputFormat.sampleRate == 16000 &&
           inputFormat.channelCount == 1 &&
           inputFormat.commonFormat == .pcmFormatInt16 {
            print("   ✓ Already optimized, skipping")
            return audioURL
        }

        // Create temp output file
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcription_\(UUID().uuidString).wav")

        // WAV settings for 16kHz mono Int16
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: outputSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        // Create converter from input format to cloud transcription format
        guard let converter = AVAudioConverter(from: inputFormat, to: Self.cloudTranscriptionFormat) else {
            throw NSError(
                domain: "AudioPreprocessor",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create audio converter from \(inputFormat) to 16kHz mono"]
            )
        }

        // Use highest quality resampling (polyphase FIR filter)
        converter.sampleRateConverterQuality = .max

        // Process in 0.5-second chunks to minimize memory usage
        let chunkDurationSeconds = 0.5
        let chunkFrames = AVAudioFrameCount(inputFormat.sampleRate * chunkDurationSeconds)
        let totalFrames = AVAudioFrameCount(inputFile.length)
        var processedFrames: AVAudioFrameCount = 0

        // Sample rate conversion ratio
        let sampleRateRatio = Self.cloudTranscriptionFormat.sampleRate / inputFormat.sampleRate

        while processedFrames < totalFrames {
            let framesToRead = min(chunkFrames, totalFrames - processedFrames)

            // Create input buffer
            guard let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat,
                frameCapacity: framesToRead
            ) else {
                throw NSError(
                    domain: "AudioPreprocessor",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create input buffer"]
                )
            }

            // Read chunk from file
            try inputFile.read(into: inputBuffer, frameCount: framesToRead)

            // Calculate output buffer capacity
            // Account for sample rate change and add padding for rounding
            let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * sampleRateRatio) + 100

            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.cloudTranscriptionFormat,
                frameCapacity: outputCapacity
            ) else {
                throw NSError(
                    domain: "AudioPreprocessor",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to create output buffer"]
                )
            }

            // Convert chunk
            // AVAudioConverter handles both sample rate conversion and channel downmixing
            var conversionError: NSError?
            let inputBufferCapture = inputBuffer // Capture for closure

            let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                outStatus.pointee = .haveData
                return inputBufferCapture
            }

            if let error = conversionError {
                throw error
            }

            if status == .error {
                throw NSError(
                    domain: "AudioPreprocessor",
                    code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "Audio conversion failed at frame \(processedFrames)"]
                )
            }

            // Write converted chunk to output file
            if outputBuffer.frameLength > 0 {
                try outputFile.write(from: outputBuffer)
            }

            processedFrames += framesToRead
        }

        // Log output stats
        let outputSizeMB = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int)
            .map { Double($0) / 1_000_000 } ?? 0
        let reduction = inputSizeMB > 0 ? inputSizeMB / outputSizeMB : 0

        print("   Output: 16000Hz, 1ch, Int16, \(String(format: "%.1f", outputSizeMB))MB")
        print("   ✓ Reduced by \(String(format: "%.0f", reduction))x (\(String(format: "%.1f", inputSizeMB))MB → \(String(format: "%.1f", outputSizeMB))MB)")

        return tempURL
    }

    // MARK: - Stereo Merge for Multichannel Transcription

    /// Stereo format for multichannel transcription: 16kHz stereo Int16
    /// Left channel = Microphone, Right channel = System audio
    static let stereoTranscriptionFormat: AVAudioFormat = {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 16000,
            channels: 2,
            interleaved: true
        ) else {
            fatalError("Failed to create stereo transcription audio format")
        }
        return format
    }()

    /// Merge mic and system audio into a single stereo file for multichannel transcription
    /// - Left channel (1): Microphone audio (you)
    /// - Right channel (2): System audio (meeting participants)
    ///
    /// This enables AssemblyAI's multichannel transcription which:
    /// - Uses a single API call instead of two
    /// - Provides perfectly synchronized timestamps
    /// - Identifies speakers by channel automatically
    ///
    /// - Parameters:
    ///   - micURL: Microphone audio file URL
    ///   - systemURL: System audio file URL
    /// - Returns: URL to merged stereo temp file (caller must delete when done)
    static func prepareMergedStereoForCloud(
        micURL: URL,
        systemURL: URL
    ) async throws -> URL {
        print("🔀 Merging audio for multichannel transcription...")

        // Open both input files
        let micFile = try AVAudioFile(forReading: micURL)
        let systemFile = try AVAudioFile(forReading: systemURL)

        let micFormat = micFile.processingFormat
        let systemFormat = systemFile.processingFormat

        print("   Mic: \(Int(micFormat.sampleRate))Hz, \(micFormat.channelCount)ch")
        print("   System: \(Int(systemFormat.sampleRate))Hz, \(systemFormat.channelCount)ch")

        // Create temp output file for stereo
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("merged_stereo_\(UUID().uuidString).wav")

        // WAV settings for 16kHz stereo Int16
        let outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]

        let outputFile = try AVAudioFile(
            forWriting: tempURL,
            settings: outputSettings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        // Create converters for each input to 16kHz mono
        // We convert each to mono first, then combine into stereo
        guard let micConverter = AVAudioConverter(from: micFormat, to: Self.cloudTranscriptionFormat) else {
            throw NSError(
                domain: "AudioPreprocessor",
                code: 10,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create mic audio converter"]
            )
        }
        micConverter.sampleRateConverterQuality = .max

        guard let systemConverter = AVAudioConverter(from: systemFormat, to: Self.cloudTranscriptionFormat) else {
            throw NSError(
                domain: "AudioPreprocessor",
                code: 11,
                userInfo: [NSLocalizedDescriptionKey: "Failed to create system audio converter"]
            )
        }
        systemConverter.sampleRateConverterQuality = .max

        // Calculate total frames at 16kHz
        let micDuration = Double(micFile.length) / micFormat.sampleRate
        let systemDuration = Double(systemFile.length) / systemFormat.sampleRate
        let maxDuration = max(micDuration, systemDuration)
        let totalOutputFrames = AVAudioFrameCount(maxDuration * 16000)

        print("   Mic duration: \(String(format: "%.1f", micDuration))s")
        print("   System duration: \(String(format: "%.1f", systemDuration))s")

        // Process in chunks
        let chunkDurationSeconds = 0.5
        let outputChunkFrames = AVAudioFrameCount(16000 * chunkDurationSeconds)
        var outputFramesWritten: AVAudioFrameCount = 0

        // Calculate input chunk sizes based on sample rate ratios
        let micChunkFrames = AVAudioFrameCount(micFormat.sampleRate * chunkDurationSeconds)
        let systemChunkFrames = AVAudioFrameCount(systemFormat.sampleRate * chunkDurationSeconds)

        var micFramesRead: AVAudioFrameCount = 0
        var systemFramesRead: AVAudioFrameCount = 0
        let micTotalFrames = AVAudioFrameCount(micFile.length)
        let systemTotalFrames = AVAudioFrameCount(systemFile.length)

        while outputFramesWritten < totalOutputFrames {
            // Determine how many frames to process this chunk
            let framesThisChunk = min(outputChunkFrames, totalOutputFrames - outputFramesWritten)

            // Create mono buffers for each channel
            guard let micMonoBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.cloudTranscriptionFormat,
                frameCapacity: framesThisChunk + 100
            ) else { throw NSError(domain: "AudioPreprocessor", code: 12, userInfo: nil) }

            guard let systemMonoBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.cloudTranscriptionFormat,
                frameCapacity: framesThisChunk + 100
            ) else { throw NSError(domain: "AudioPreprocessor", code: 13, userInfo: nil) }

            // Convert mic chunk (or zero-fill if past end)
            if micFramesRead < micTotalFrames {
                let framesToRead = min(micChunkFrames, micTotalFrames - micFramesRead)
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: framesToRead) else {
                    throw NSError(domain: "AudioPreprocessor", code: 14, userInfo: nil)
                }
                try micFile.read(into: inputBuffer, frameCount: framesToRead)
                micFramesRead += framesToRead

                var conversionError: NSError?
                let capturedBuffer = inputBuffer
                _ = micConverter.convert(to: micMonoBuffer, error: &conversionError) { _, outStatus in
                    outStatus.pointee = .haveData
                    return capturedBuffer
                }
                if let error = conversionError { throw error }
            } else {
                // Zero-fill if mic audio ended
                micMonoBuffer.frameLength = framesThisChunk
                if let data = micMonoBuffer.int16ChannelData?[0] {
                    for i in 0..<Int(framesThisChunk) {
                        data[i] = 0
                    }
                }
            }

            // Convert system chunk (or zero-fill if past end)
            if systemFramesRead < systemTotalFrames {
                let framesToRead = min(systemChunkFrames, systemTotalFrames - systemFramesRead)
                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: systemFormat, frameCapacity: framesToRead) else {
                    throw NSError(domain: "AudioPreprocessor", code: 15, userInfo: nil)
                }
                try systemFile.read(into: inputBuffer, frameCount: framesToRead)
                systemFramesRead += framesToRead

                var conversionError: NSError?
                let capturedBuffer = inputBuffer
                _ = systemConverter.convert(to: systemMonoBuffer, error: &conversionError) { _, outStatus in
                    outStatus.pointee = .haveData
                    return capturedBuffer
                }
                if let error = conversionError { throw error }
            } else {
                // Zero-fill if system audio ended
                systemMonoBuffer.frameLength = framesThisChunk
                if let data = systemMonoBuffer.int16ChannelData?[0] {
                    for i in 0..<Int(framesThisChunk) {
                        data[i] = 0
                    }
                }
            }

            // Combine into stereo buffer (interleaved: L, R, L, R, ...)
            let actualFrames = max(micMonoBuffer.frameLength, systemMonoBuffer.frameLength)
            guard let stereoBuffer = AVAudioPCMBuffer(
                pcmFormat: Self.stereoTranscriptionFormat,
                frameCapacity: actualFrames
            ) else { throw NSError(domain: "AudioPreprocessor", code: 16, userInfo: nil) }
            stereoBuffer.frameLength = actualFrames

            // Copy samples: interleaved stereo layout is [L0, R0, L1, R1, ...]
            if let stereoData = stereoBuffer.int16ChannelData?[0],
               let micData = micMonoBuffer.int16ChannelData?[0],
               let systemData = systemMonoBuffer.int16ChannelData?[0] {
                for i in 0..<Int(actualFrames) {
                    let micSample = i < Int(micMonoBuffer.frameLength) ? micData[i] : 0
                    let sysSample = i < Int(systemMonoBuffer.frameLength) ? systemData[i] : 0
                    stereoData[i * 2] = micSample      // Left channel (mic)
                    stereoData[i * 2 + 1] = sysSample  // Right channel (system)
                }
            }

            // Write stereo chunk to output
            if stereoBuffer.frameLength > 0 {
                try outputFile.write(from: stereoBuffer)
            }

            outputFramesWritten += actualFrames
        }

        // Log output stats
        let outputSizeMB = (try? FileManager.default.attributesOfItem(atPath: tempURL.path)[.size] as? Int)
            .map { Double($0) / 1_000_000 } ?? 0

        print("   ✓ Merged: 16kHz stereo, \(String(format: "%.1f", outputSizeMB))MB")
        print("   Channel 1 (L): Microphone")
        print("   Channel 2 (R): System Audio")

        return tempURL
    }

    /// Clean up temporary preprocessed files
    /// Call this after successful cloud transcription upload
    static func cleanup(tempURL: URL) {
        // Only delete files in temp directory that we created
        guard tempURL.path.contains("transcription_") || tempURL.path.contains("merged_stereo_") else {
            return
        }

        do {
            try FileManager.default.removeItem(at: tempURL)
            print("🗑️ Cleaned up temp file: \(tempURL.lastPathComponent)")
        } catch {
            print("⚠️ Failed to cleanup temp file: \(error.localizedDescription)")
        }
    }
}
