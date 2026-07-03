import AVFoundation
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

protocol MeetingAudioFileConverting {
    func convertWAVToM4A(sourceURL: URL, destinationURL: URL) async throws
}

protocol MeetingAudioFileValidating {
    func isUsableAudioFile(at url: URL, fileManager: FileManager) -> Bool
}

protocol MeetingAudioPlaybackMixing {
    func createPlaybackWAV(
        microphoneURL: URL,
        systemURL: URL,
        destinationURL: URL,
        fileManager: FileManager
    ) async throws
}

struct AVFoundationMeetingAudioConverter: MeetingAudioFileConverting {
    func convertWAVToM4A(sourceURL: URL, destinationURL: URL) async throws {
        let asset = AVURLAsset(url: sourceURL)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw MeetingAudioStorageError.exportSessionUnavailable
        }

        session.shouldOptimizeForNetworkUse = false

        try await session.export(to: destinationURL, as: .m4a)
    }
}

struct AVFoundationMeetingAudioPlaybackMixer: MeetingAudioPlaybackMixing {
    private static let chunkFrames: AVAudioFrameCount = 4096
    private static let gateWindowFrames = 1024
    private static let micActiveThreshold: Float = 0.012
    private static let systemActiveThreshold: Float = 0.012
    private static let systemGain: Float = 0.95
    private static let micGainQuietSystem: Float = 0.90
    private static let micGainLikelySpeech: Float = 0.75
    private static let micGainAmbiguous: Float = 0.12

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
        var startFrame = 0
        while startFrame < frameCount {
            let blockFrameCount = min(Self.gateWindowFrames, frameCount - startFrame)
            let microphoneRMS = rms(
                in: microphoneBuffer,
                startFrame: startFrame,
                frameCount: blockFrameCount
            )
            let systemRMS = rms(
                in: systemBuffer,
                startFrame: startFrame,
                frameCount: blockFrameCount
            )
            let microphoneGain = gainForMicrophone(
                microphoneRMS: microphoneRMS,
                systemRMS: systemRMS
            )

            for frame in startFrame..<(startFrame + blockFrameCount) {
                for channel in 0..<outputChannelCount {
                    let systemSample = sample(
                        from: systemBuffer,
                        channel: channel,
                        frame: frame
                    )
                    let microphoneSample = sample(
                        from: microphoneBuffer,
                        channel: channel,
                        frame: frame
                    )
                    let mixedSample = (systemSample * Self.systemGain)
                        + (microphoneSample * microphoneGain)
                    write(
                        limited(mixedSample),
                        to: outputBuffer,
                        channel: channel,
                        frame: frame
                    )
                }
            }

            startFrame += blockFrameCount
        }
    }

    private func gainForMicrophone(microphoneRMS: Float, systemRMS: Float) -> Float {
        guard microphoneRMS >= Self.micActiveThreshold else { return 0 }
        guard systemRMS >= Self.systemActiveThreshold else { return Self.micGainQuietSystem }

        if microphoneRMS >= systemRMS * 1.25 {
            return Self.micGainLikelySpeech
        }

        if microphoneRMS >= systemRMS * 0.75 {
            return Self.micGainAmbiguous
        }

        return 0
    }

    private func rms(
        in buffer: AVAudioPCMBuffer?,
        startFrame: Int,
        frameCount: Int
    ) -> Float {
        guard let buffer else { return 0 }
        let endFrame = min(startFrame + frameCount, Int(buffer.frameLength))
        guard startFrame < endFrame else { return 0 }

        let channels = max(1, Int(buffer.format.channelCount))
        var sum: Float = 0
        var sampleCount = 0

        for frame in startFrame..<endFrame {
            for channel in 0..<channels {
                let value = sample(from: buffer, channel: channel, frame: frame)
                sum += value * value
                sampleCount += 1
            }
        }

        guard sampleCount > 0 else { return 0 }
        return sqrt(sum / Float(sampleCount))
    }

    private func sample(
        from buffer: AVAudioPCMBuffer?,
        channel: Int,
        frame: Int
    ) -> Float {
        guard let buffer,
              frame >= 0,
              frame < Int(buffer.frameLength),
              let channelData = buffer.floatChannelData else {
            return 0
        }

        let channelCount = max(1, Int(buffer.format.channelCount))
        let sourceChannel = channelCount == 1 ? 0 : min(channel, channelCount - 1)
        if buffer.format.isInterleaved {
            return channelData[0][frame * channelCount + sourceChannel]
        }

        return channelData[sourceChannel][frame]
    }

    private func write(
        _ sample: Float,
        to buffer: AVAudioPCMBuffer,
        channel: Int,
        frame: Int
    ) {
        guard let channelData = buffer.floatChannelData,
              frame >= 0,
              frame < Int(buffer.frameLength) else {
            return
        }

        let channelCount = max(1, Int(buffer.format.channelCount))
        let destinationChannel = min(channel, channelCount - 1)
        if buffer.format.isInterleaved {
            channelData[0][frame * channelCount + destinationChannel] = sample
        } else {
            channelData[destinationChannel][frame] = sample
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
                    conversionError = error as NSError
                    outStatus.pointee = .noDataNow
                    return nil
                }
            }

            if let conversionError {
                throw conversionError
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

struct AVFoundationMeetingAudioValidator: MeetingAudioFileValidating {
    func isUsableAudioFile(at url: URL, fileManager: FileManager) -> Bool {
        guard hasNonEmptyFile(at: url, fileManager: fileManager),
              let file = try? AVAudioFile(forReading: url) else {
            return false
        }

        return file.length > 0 && file.fileFormat.sampleRate > 0
    }

    private func hasNonEmptyFile(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
    }
}

enum MeetingAudioStorageError: Error {
    case exportSessionUnavailable
    case conversionFailed
    case emptyConvertedFile
    case unsupportedPlaybackMixFormat
    case mixBufferAllocationFailed
}

struct MeetingAudioStorageMaintenanceResult: Equatable {
    let scannedDirectories: Int
    let convertedFiles: Int
    let prunedDirectories: Int
    let createdPlaybackMixes: Int

    init(
        scannedDirectories: Int,
        convertedFiles: Int,
        prunedDirectories: Int,
        createdPlaybackMixes: Int = 0
    ) {
        self.scannedDirectories = scannedDirectories
        self.convertedFiles = convertedFiles
        self.prunedDirectories = prunedDirectories
        self.createdPlaybackMixes = createdPlaybackMixes
    }

    var changedArtifacts: Bool {
        convertedFiles > 0 || prunedDirectories > 0 || createdPlaybackMixes > 0
    }
}

struct FailedMeetingAudioCompressionCandidate: Equatable {
    let id: UUID
    let micAudioURL: URL
    let systemAudioURL: URL?
}

struct FailedMeetingAudioCompressionUpdate: Equatable {
    let id: UUID
    let micAudioURL: URL
    let systemAudioURL: URL?
}

struct FailedMeetingAudioCompressionResult: Equatable {
    let scannedEntries: Int
    let convertedFiles: Int
    let updatedEntries: Int
}

/// Coarse, privacy-safe record of a retained-audio maintenance failure. Carries
/// only the operation name and the NSError domain/code — never a path, filename,
/// or meeting title — so forwarding it into the observability pipeline needs no
/// extra sanitization.
struct MeetingAudioMaintenanceFailure: Equatable {
    let operation: String
    let errorDomain: String
    let errorCode: Int
}

enum MeetingAudioStorageManager {
    private static let frontmatterPreviewByteLimit = 64 * 1024
    private static let staleTemporaryAudioAge: TimeInterval = 6 * 60 * 60
    private static let managedAudioStems = ["microphone", "system_audio", "recording", "playback"]

    // MARK: - Maintenance failure reporting

    /// Maintenance loops deliberately keep going when one file fails (a stuck
    /// conversion must not block retention for every other meeting), but the
    /// failures used to vanish into `catch { continue }` — orphaned WAVs and
    /// unpruned audio accumulated with no signal anywhere. Each swallowed error
    /// now also reports here. The app wires this to `EventReporter` at startup;
    /// tests inject a recorder. The hook must be safe to call from any queue.
    private static let maintenanceFailureLock = NSLock()
    private static var maintenanceFailureHandler: ((MeetingAudioMaintenanceFailure) -> Void)?

    static func setMaintenanceFailureHandler(_ handler: ((MeetingAudioMaintenanceFailure) -> Void)?) {
        maintenanceFailureLock.lock()
        maintenanceFailureHandler = handler
        maintenanceFailureLock.unlock()
    }

    private static func reportMaintenanceFailure(_ operation: String, _ error: Error) {
        maintenanceFailureLock.lock()
        let handler = maintenanceFailureHandler
        maintenanceFailureLock.unlock()
        let nsError = error as NSError
        handler?(MeetingAudioMaintenanceFailure(
            operation: operation,
            errorDomain: nsError.domain,
            errorCode: nsError.code
        ))
    }

    @discardableResult
    static func processExistingRetainedAudio(
        in meetingsFolder: URL,
        retentionWindow: AudioRetentionWindow = AudioStoragePreferences.deleteAudioAfter(),
        now: Date = Date(),
        fileManager: FileManager = .default,
        converter: MeetingAudioFileConverting = AVFoundationMeetingAudioConverter(),
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator(),
        playbackMixer: MeetingAudioPlaybackMixing = AVFoundationMeetingAudioPlaybackMixer()
    ) async -> MeetingAudioStorageMaintenanceResult {
        let prunedDirectories = pruneRetainedAudio(
            in: meetingsFolder,
            retentionWindow: retentionWindow,
            now: now,
            fileManager: fileManager
        )

        let directories = audioArchiveDirectoriesWithTranscripts(
            in: meetingsFolder,
            fileManager: fileManager
        )

        var convertedFiles = 0
        var createdPlaybackMixes = 0
        for directory in directories {
            if await createPlaybackMixIfNeeded(
                in: directory,
                now: now,
                fileManager: fileManager,
                validator: validator,
                playbackMixer: playbackMixer
            ) {
                createdPlaybackMixes += 1
            }
            convertedFiles += await compressWAVAudio(
                in: directory,
                now: now,
                fileManager: fileManager,
                converter: converter,
                validator: validator
            )
        }

        return MeetingAudioStorageMaintenanceResult(
            scannedDirectories: directories.count,
            convertedFiles: convertedFiles,
            prunedDirectories: prunedDirectories,
            createdPlaybackMixes: createdPlaybackMixes
        )
    }

    /// - Returns: `true` when this pass changed the saved meeting's on-disk audio
    ///   files (a playback mix was created, a WAV was recompressed to M4A, or
    ///   retained audio was pruned). Home caches audio URLs at scan time, so the
    ///   caller uses this to decide whether to broadcast a capture-changed signal.
    @discardableResult
    static func processSavedTranscript(
        at transcriptURL: URL,
        retentionWindow: AudioRetentionWindow = AudioStoragePreferences.deleteAudioAfter(),
        now: Date = Date(),
        fileManager: FileManager = .default,
        converter: MeetingAudioFileConverting = AVFoundationMeetingAudioConverter(),
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator(),
        playbackMixer: MeetingAudioPlaybackMixing = AVFoundationMeetingAudioPlaybackMixer()
    ) async -> Bool {
        let audioDirectory = audioDirectoryURL(forTranscript: transcriptURL)
        let didMix = await createPlaybackMixIfNeeded(
            in: audioDirectory,
            now: now,
            fileManager: fileManager,
            validator: validator,
            playbackMixer: playbackMixer
        )
        let convertedCount = await compressWAVAudio(
            in: audioDirectory,
            now: now,
            fileManager: fileManager,
            converter: converter,
            validator: validator
        )

        let prunedCount = pruneRetainedAudio(
            in: transcriptURL.deletingLastPathComponent(),
            retentionWindow: retentionWindow,
            now: now,
            fileManager: fileManager
        )

        return didMix || convertedCount > 0 || prunedCount > 0
    }

    @discardableResult
    static func pruneRetainedAudio(
        in meetingsFolder: URL,
        retentionWindow: AudioRetentionWindow = AudioStoragePreferences.deleteAudioAfter(),
        now: Date = Date(),
        fileManager: FileManager = .default
    ) -> Int {
        guard let days = retentionWindow.days else { return 0 }
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: now) else { return 0 }

        let directories = audioArchiveDirectoriesWithTranscripts(
            in: meetingsFolder,
            fileManager: fileManager
        )

        var removedCount = 0
        for directory in directories {
            guard let transcript = transcriptInfo(
                forAudioDirectory: directory,
                meetingsFolder: meetingsFolder,
                fileManager: fileManager
            ), transcript.referenceDate < cutoff else {
                continue
            }

            guard pruneManagedAudioFiles(in: directory, fileManager: fileManager) else {
                continue
            }
            removedCount += 1

            if isDirectoryEmpty(directory, fileManager: fileManager) {
                try? fileManager.removeItem(at: directory)
            }
        }

        return removedCount
    }

    private static func pruneManagedAudioFiles(in audioDirectory: URL, fileManager: FileManager) -> Bool {
        guard isSafeNonSymlinkDirectory(audioDirectory, fileManager: fileManager) else { return false }
        guard let files = try? fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else {
            return false
        }

        var removedAny = false
        for file in files where isManagedRetainedAudioFile(file, fileManager: fileManager)
            || isTranscriptedTemporaryAudioFileName(file) {
            do {
                try fileManager.removeItem(at: file)
                removedAny = true
            } catch {
                reportMaintenanceFailure("retention_prune", error)
                continue
            }
        }

        return removedAny
    }

    private static func isDirectoryEmpty(_ directory: URL, fileManager: FileManager) -> Bool {
        guard isSafeNonSymlinkDirectory(directory, fileManager: fileManager) else { return false }
        guard let remaining = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return false
        }
        return remaining.isEmpty
    }

    @discardableResult
    static func createPlaybackMixIfNeeded(
        in audioDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator(),
        playbackMixer: MeetingAudioPlaybackMixing = AVFoundationMeetingAudioPlaybackMixer()
    ) async -> Bool {
        guard isSafeNonSymlinkDirectory(audioDirectory, fileManager: fileManager) else { return false }
        removeStaleTemporaryAudioFiles(in: audioDirectory, now: now, fileManager: fileManager)

        let playbackWAVURL = audioDirectory.appendingPathComponent("playback.wav")
        let playbackM4AURL = audioDirectory.appendingPathComponent("playback.m4a")
        if validator.isUsableAudioFile(at: playbackM4AURL, fileManager: fileManager)
            || validator.isUsableAudioFile(at: playbackWAVURL, fileManager: fileManager) {
            return false
        }

        guard let microphoneURL = firstRetainedAudioFile(
            named: "microphone",
            in: audioDirectory,
            validator: validator,
            fileManager: fileManager
        ), let systemURL = firstRetainedAudioFile(
            named: "system_audio",
            in: audioDirectory,
            validator: validator,
            fileManager: fileManager
        ) else {
            return false
        }

        let tempURL = audioDirectory
            .appendingPathComponent(".playback-\(UUID().uuidString)")
            .appendingPathExtension("wav")

        do {
            try await playbackMixer.createPlaybackWAV(
                microphoneURL: microphoneURL,
                systemURL: systemURL,
                destinationURL: tempURL,
                fileManager: fileManager
            )
            guard validator.isUsableAudioFile(at: tempURL, fileManager: fileManager) else {
                throw MeetingAudioStorageError.emptyConvertedFile
            }
            if fileManager.fileExists(atPath: playbackWAVURL.path) {
                try fileManager.removeItem(at: playbackWAVURL)
            }
            try fileManager.moveItem(at: tempURL, to: playbackWAVURL)
            fileManager.restrictFileToOwnerOnly(at: playbackWAVURL)
            return true
        } catch {
            reportMaintenanceFailure("playback_mix", error)
            try? fileManager.removeItem(at: tempURL)
            return false
        }
    }

    @discardableResult
    static func compressWAVAudio(
        in audioDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        converter: MeetingAudioFileConverting = AVFoundationMeetingAudioConverter(),
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator()
    ) async -> Int {
        guard isSafeNonSymlinkDirectory(audioDirectory, fileManager: fileManager) else { return 0 }
        removeStaleTemporaryAudioFiles(in: audioDirectory, now: now, fileManager: fileManager)

        guard let files = try? fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        restrictRetainedM4AFiles(files, fileManager: fileManager)

        var convertedCount = 0
        for sourceURL in files where isWAVFile(sourceURL, fileManager: fileManager)
            && isManagedRetainedAudioFile(sourceURL, fileManager: fileManager) {
            let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")

            if validator.isUsableAudioFile(at: destinationURL, fileManager: fileManager) {
                fileManager.restrictFileToOwnerOnly(at: destinationURL)
                try? fileManager.removeItem(at: sourceURL)
                continue
            }

            switch await convertWAVToM4AAtomically(
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                in: audioDirectory,
                checkingCancellation: false,
                fileManager: fileManager,
                converter: converter,
                validator: validator
            ) {
            case .converted:
                try? fileManager.removeItem(at: sourceURL)
                convertedCount += 1
            case .cancelled, .failed:
                continue
            }
        }

        return convertedCount
    }

    /// Outcome of an atomic WAV → M4A conversion attempt.
    private enum WAVToM4AConversionOutcome {
        /// `destinationURL` now holds a validated M4A and any existing file
        /// there was replaced.
        case converted
        /// The task was cancelled mid-flight; nothing was moved into place.
        case cancelled
        /// Conversion or validation failed; nothing was moved into place.
        case failed
    }

    /// Convert `sourceURL` (a WAV) into `destinationURL` (an `.m4a`) atomically:
    /// write to a hidden temp file in `audioDirectory`, validate it, replace any
    /// existing destination, move it into place, and restrict it to the owner.
    /// The temp file is always removed on cancellation or failure. The caller
    /// owns whether to delete or retain `sourceURL`.
    ///
    /// This is the single implementation shared by retained-audio compression
    /// and failed-meeting audio promotion, which previously duplicated the whole
    /// temp/convert/validate/move/cleanup flow.
    private static func convertWAVToM4AAtomically(
        sourceURL: URL,
        destinationURL: URL,
        in audioDirectory: URL,
        checkingCancellation: Bool,
        operation: String = "wav_to_m4a",
        fileManager: FileManager,
        converter: MeetingAudioFileConverting,
        validator: MeetingAudioFileValidating
    ) async -> WAVToM4AConversionOutcome {
        let tempURL = audioDirectory
            .appendingPathComponent(".\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        do {
            try await converter.convertWAVToM4A(sourceURL: sourceURL, destinationURL: tempURL)
            if checkingCancellation, Task.isCancelled {
                try? fileManager.removeItem(at: tempURL)
                return .cancelled
            }
            guard validator.isUsableAudioFile(at: tempURL, fileManager: fileManager) else {
                throw MeetingAudioStorageError.emptyConvertedFile
            }
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.moveItem(at: tempURL, to: destinationURL)
            fileManager.restrictFileToOwnerOnly(at: destinationURL)
            return .converted
        } catch {
            // The maintenance loops deliberately keep going past a failed file;
            // report the skip so it doesn't vanish (cancellation is not a failure).
            reportMaintenanceFailure(operation, error)
            try? fileManager.removeItem(at: tempURL)
            return .failed
        }
    }

    @discardableResult
    static func compressFailedTranscriptionAudio(
        candidates: [FailedMeetingAudioCompressionCandidate],
        audioArchiveRoot: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        converter: MeetingAudioFileConverting = AVFoundationMeetingAudioConverter(),
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator(),
        persistUpdate: (FailedMeetingAudioCompressionUpdate) async -> Bool
    ) async -> FailedMeetingAudioCompressionResult {
        var scannedEntries = 0
        var convertedFiles = 0
        var updatedEntries = 0

        for candidate in candidates {
            guard !Task.isCancelled else { break }
            guard failedAudioCandidateIsArchiveOwned(
                candidate,
                audioArchiveRoot: audioArchiveRoot,
                fileManager: fileManager
            ) else {
                continue
            }

            scannedEntries += 1

            let micResolution = await resolveCompressedFailedAudioURL(
                candidate.micAudioURL,
                now: now,
                fileManager: fileManager,
                converter: converter,
                validator: validator
            )
            let systemResolution: FailedAudioCompressionResolution?
            if let systemAudioURL = candidate.systemAudioURL {
                systemResolution = await resolveCompressedFailedAudioURL(
                    systemAudioURL,
                    now: now,
                    fileManager: fileManager,
                    converter: converter,
                    validator: validator
                )
            } else {
                systemResolution = nil
            }

            let updatedMicURL = micResolution.updatedURL
            let updatedSystemURL = systemResolution?.updatedURL
            guard updatedMicURL != candidate.micAudioURL
                || updatedSystemURL != candidate.systemAudioURL else {
                continue
            }

            var promotedFiles = [FailedAudioPromotion]()
            if let promotedFile = micResolution.promotedFile {
                promotedFiles.append(promotedFile)
            }
            if let promotedFile = systemResolution?.promotedFile {
                promotedFiles.append(promotedFile)
            }
            guard !Task.isCancelled else {
                for promoted in promotedFiles where promoted.wasConverted {
                    try? fileManager.removeItem(at: promoted.destinationURL)
                }
                break
            }

            let didPersist = await persistUpdate(FailedMeetingAudioCompressionUpdate(
                id: candidate.id,
                micAudioURL: updatedMicURL,
                systemAudioURL: updatedSystemURL
            ))

            if didPersist {
                for promoted in promotedFiles {
                    try? fileManager.removeItem(at: promoted.sourceURL)
                    if promoted.wasConverted {
                        convertedFiles += 1
                    }
                }
                updatedEntries += 1
            } else {
                for promoted in promotedFiles where promoted.wasConverted {
                    try? fileManager.removeItem(at: promoted.destinationURL)
                }
            }
        }

        return FailedMeetingAudioCompressionResult(
            scannedEntries: scannedEntries,
            convertedFiles: convertedFiles,
            updatedEntries: updatedEntries
        )
    }

    @discardableResult
    static func removeStaleTemporaryAudioFiles(
        in audioDirectory: URL,
        now: Date = Date(),
        minimumAge: TimeInterval = staleTemporaryAudioAge,
        fileManager: FileManager = .default
    ) -> Int {
        guard isSafeNonSymlinkDirectory(audioDirectory, fileManager: fileManager) else { return 0 }
        guard let files = try? fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: []
        ) else {
            return 0
        }

        var removedCount = 0
        for file in files where isStaleTemporaryAudioFile(
            file,
            now: now,
            minimumAge: minimumAge,
            fileManager: fileManager
        ) {
            do {
                try fileManager.removeItem(at: file)
                removedCount += 1
            } catch {
                reportMaintenanceFailure("stale_temp_cleanup", error)
                continue
            }
        }
        return removedCount
    }

    private static func audioArchiveDirectoriesWithTranscripts(
        in meetingsFolder: URL,
        fileManager: FileManager
    ) -> [URL] {
        let audioRoot = meetingsFolder.appendingPathComponent("audio", isDirectory: true)
        guard isSafeNonSymlinkDirectory(audioRoot, fileManager: fileManager) else { return [] }
        guard let directories = try? fileManager.contentsOfDirectory(
            at: audioRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.filter { directory in
            isAudioArchiveDirectory(directory, fileManager: fileManager)
                && transcriptInfo(
                    forAudioDirectory: directory,
                    meetingsFolder: meetingsFolder,
                    fileManager: fileManager
                ) != nil
        }
    }

    private static func audioDirectoryURL(forTranscript transcriptURL: URL) -> URL {
        MeetingArtifactRenamer.audioDirectoryURL(for: transcriptURL)
    }

    private static func isAudioArchiveDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.lastPathComponent.hasSuffix("_audio") else { return false }
        return isSafeNonSymlinkDirectory(url, fileManager: fileManager)
    }

    private struct TranscriptInfo {
        let referenceDate: Date
    }

    private static func transcriptInfo(
        forAudioDirectory audioDirectory: URL,
        meetingsFolder: URL,
        fileManager: FileManager
    ) -> TranscriptInfo? {
        let name = audioDirectory.lastPathComponent
        guard name.hasSuffix("_audio") else { return nil }
        let stem = String(name.dropLast("_audio".count))
        let transcriptURL = meetingsFolder.appendingPathComponent(stem).appendingPathExtension("md")
        guard fileManager.fileExists(atPath: transcriptURL.path) else { return nil }
        guard let raw = try? previewString(at: transcriptURL),
              isTranscriptedMeetingTranscript(raw) else {
            return nil
        }

        return TranscriptInfo(referenceDate: transcriptReferenceDate(for: transcriptURL, raw: raw))
    }

    private static func previewString(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: frontmatterPreviewByteLimit) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func isTranscriptedMeetingTranscript(_ raw: String) -> Bool {
        guard raw.contains("\n## Full Transcript") || raw.contains("\n## Transcript"),
              let values = TranscriptFrontmatter.values(in: raw),
              values["capture_type"]?.lowercased() == "meeting" else {
            return false
        }

        return isValidTranscriptIdentifier(values["transcript_id"])
            || isValidTranscriptIdentifier(values["capture_id"])
    }

    private static func transcriptReferenceDate(for url: URL, raw: String) -> Date {
        if let frontmatterDate = TranscriptFrontmatter.recordedAt(in: raw) {
            return frontmatterDate
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private static func isValidTranscriptIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return UUID(uuidString: value) != nil
    }

    private static func isWAVFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.pathExtension.localizedCaseInsensitiveCompare("wav") == .orderedSame else { return false }
        guard !isSymbolicLink(url, fileManager: fileManager) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    private static func isManagedRetainedAudioFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard ["wav", "m4a"].contains(where: { url.pathExtension.localizedCaseInsensitiveCompare($0) == .orderedSame }) else {
            return false
        }
        guard !isSymbolicLink(url, fileManager: fileManager) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return false }
        let stem = url.deletingPathExtension().lastPathComponent
        return managedAudioStems.contains { managedStem in
            stem == managedStem || stem.range(of: #"^\#(managedStem)-[0-9]+$"#, options: .regularExpression) != nil
        }
    }

    private static func firstRetainedAudioFile(
        named stem: String,
        in audioDirectory: URL,
        validator: MeetingAudioFileValidating,
        fileManager: FileManager
    ) -> URL? {
        guard let files = try? fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }

        let candidates = files
            .filter { url in
                url.deletingPathExtension().lastPathComponent == stem
                    && isManagedRetainedAudioFile(url, fileManager: fileManager)
            }
            .sorted { lhs, rhs in
                retainedAudioFileSortKey(lhs) < retainedAudioFileSortKey(rhs)
            }

        return candidates.first { url in
            validator.isUsableAudioFile(at: url, fileManager: fileManager)
        } ?? candidates.first
    }

    private static func retainedAudioFileSortKey(_ url: URL) -> String {
        let extensionRank: String
        switch url.pathExtension.lowercased() {
        case "wav":
            extensionRank = "0"
        case "m4a":
            extensionRank = "1"
        default:
            extensionRank = "2"
        }
        return "\(extensionRank)-\(url.lastPathComponent)"
    }

    private static func restrictRetainedM4AFiles(_ files: [URL], fileManager: FileManager) {
        for file in files where file.pathExtension.localizedCaseInsensitiveCompare("m4a") == .orderedSame
            && isManagedRetainedAudioFile(file, fileManager: fileManager) {
            fileManager.restrictFileToOwnerOnly(at: file)
        }
    }

    private struct FailedAudioPromotion {
        let sourceURL: URL
        let destinationURL: URL
        let wasConverted: Bool
    }

    private struct FailedAudioCompressionResolution {
        let updatedURL: URL
        let promotedFile: FailedAudioPromotion?
    }

    private static func failedAudioCandidateIsArchiveOwned(
        _ candidate: FailedMeetingAudioCompressionCandidate,
        audioArchiveRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        var urls = [candidate.micAudioURL]
        if let systemAudioURL = candidate.systemAudioURL {
            urls.append(systemAudioURL)
        }
        return urls.allSatisfy { url in
            isManagedFailedAudioFile(url, audioArchiveRoot: audioArchiveRoot, fileManager: fileManager)
        }
    }

    private static func resolveCompressedFailedAudioURL(
        _ sourceURL: URL,
        now: Date,
        fileManager: FileManager,
        converter: MeetingAudioFileConverting,
        validator: MeetingAudioFileValidating
    ) async -> FailedAudioCompressionResolution {
        let audioDirectory = sourceURL.deletingLastPathComponent()
        removeStaleTemporaryAudioFiles(in: audioDirectory, now: now, fileManager: fileManager)

        guard isWAVFile(sourceURL, fileManager: fileManager) else {
            if sourceURL.pathExtension.localizedCaseInsensitiveCompare("m4a") == .orderedSame,
               isManagedFailedAudioPayloadFile(sourceURL, fileManager: fileManager) {
                fileManager.restrictFileToOwnerOnly(at: sourceURL)
            }
            return FailedAudioCompressionResolution(updatedURL: sourceURL, promotedFile: nil)
        }

        let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")
        if validator.isUsableAudioFile(at: destinationURL, fileManager: fileManager) {
            fileManager.restrictFileToOwnerOnly(at: destinationURL)
            return FailedAudioCompressionResolution(
                updatedURL: destinationURL,
                promotedFile: FailedAudioPromotion(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    wasConverted: false
                )
            )
        }

        switch await convertWAVToM4AAtomically(
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            in: audioDirectory,
            checkingCancellation: true,
            operation: "failed_audio_compress",
            fileManager: fileManager,
            converter: converter,
            validator: validator
        ) {
        case .converted:
            return FailedAudioCompressionResolution(
                updatedURL: destinationURL,
                promotedFile: FailedAudioPromotion(
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    wasConverted: true
                )
            )
        case .cancelled, .failed:
            return FailedAudioCompressionResolution(updatedURL: sourceURL, promotedFile: nil)
        }
    }

    private static func isManagedFailedAudioFile(
        _ url: URL,
        audioArchiveRoot: URL,
        fileManager: FileManager
    ) -> Bool {
        guard isManagedFailedAudioPayloadFile(url, fileManager: fileManager) else { return false }
        let directory = url.deletingLastPathComponent()
        guard directory.lastPathComponent.hasPrefix("Failed_"),
              directory.lastPathComponent.hasSuffix("_audio"),
              isSafeNonSymlinkDirectory(directory, fileManager: fileManager) else {
            return false
        }
        return isFile(directory, containedIn: audioArchiveRoot)
    }

    private static func isManagedFailedAudioPayloadFile(_ url: URL, fileManager: FileManager) -> Bool {
        if isManagedRetainedAudioFile(url, fileManager: fileManager) {
            return true
        }
        guard ["wav", "m4a"].contains(where: { url.pathExtension.localizedCaseInsensitiveCompare($0) == .orderedSame }) else {
            return false
        }
        guard !isSymbolicLink(url, fileManager: fileManager) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        guard values?.isRegularFile == true else { return false }
        return url.deletingPathExtension().lastPathComponent == "microphone_placeholder"
    }

    private static func isStaleTemporaryAudioFile(
        _ url: URL,
        now: Date,
        minimumAge: TimeInterval,
        fileManager: FileManager
    ) -> Bool {
        guard isTranscriptedTemporaryAudioFileName(url) else { return false }
        guard !isSymbolicLink(url, fileManager: fileManager) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values?.isRegularFile == true, let modified = values?.contentModificationDate else {
            return false
        }
        return now.timeIntervalSince(modified) >= max(0, minimumAge)
    }

    private static func isTranscriptedTemporaryAudioFileName(_ url: URL) -> Bool {
        guard ["m4a", "wav"].contains(where: { url.pathExtension.localizedCaseInsensitiveCompare($0) == .orderedSame }) else {
            return false
        }
        let hiddenStem = url.deletingPathExtension().lastPathComponent
        guard hiddenStem.hasPrefix(".") else { return false }
        let stem = String(hiddenStem.dropFirst())
        guard stem.count > 37 else { return false }
        let separatorIndex = stem.index(stem.endIndex, offsetBy: -37)
        guard stem[separatorIndex] == "-" else { return false }
        let uuidString = String(stem.suffix(36))
        return UUID(uuidString: uuidString) != nil
    }

    private static func isSafeNonSymlinkDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard !isSymbolicLink(url, fileManager: fileManager) else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isSymbolicLink(_ url: URL, fileManager: FileManager) -> Bool {
        if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
           let type = attributes[.type] as? FileAttributeType,
           type == .typeSymbolicLink {
            return true
        }

        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    private static func isFile(_ fileURL: URL, containedIn directoryURL: URL) -> Bool {
        let filePath = canonicalURL(fileURL).path
        let directoryPath = canonicalURL(directoryURL).path
        let normalizedDirectoryPath = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath == directoryPath || filePath.hasPrefix(normalizedDirectoryPath)
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
