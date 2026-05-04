import AVFoundation
import Foundation

protocol MeetingAudioFileConverting {
    func convertWAVToM4A(sourceURL: URL, destinationURL: URL) async throws
}

protocol MeetingAudioFileValidating {
    func isUsableAudioFile(at url: URL, fileManager: FileManager) -> Bool
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
}

struct MeetingAudioStorageMaintenanceResult: Equatable {
    let scannedDirectories: Int
    let convertedFiles: Int
    let prunedDirectories: Int
}

enum MeetingAudioStorageManager {
    @discardableResult
    static func processExistingRetainedAudio(
        in meetingsFolder: URL,
        retentionWindow: AudioRetentionWindow = AudioStoragePreferences.deleteAudioAfter(),
        now: Date = Date(),
        fileManager: FileManager = .default,
        converter: MeetingAudioFileConverting = AVFoundationMeetingAudioConverter(),
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator()
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
        for directory in directories {
            convertedFiles += await compressWAVAudio(
                in: directory,
                fileManager: fileManager,
                converter: converter,
                validator: validator
            )
        }

        return MeetingAudioStorageMaintenanceResult(
            scannedDirectories: directories.count,
            convertedFiles: convertedFiles,
            prunedDirectories: prunedDirectories
        )
    }

    static func processSavedTranscript(
        at transcriptURL: URL,
        retentionWindow: AudioRetentionWindow = AudioStoragePreferences.deleteAudioAfter(),
        now: Date = Date(),
        fileManager: FileManager = .default,
        converter: MeetingAudioFileConverting = AVFoundationMeetingAudioConverter(),
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator()
    ) async {
        let audioDirectory = audioDirectoryURL(forTranscript: transcriptURL)
        await compressWAVAudio(
            in: audioDirectory,
            fileManager: fileManager,
            converter: converter,
            validator: validator
        )

        pruneRetainedAudio(
            in: transcriptURL.deletingLastPathComponent(),
            retentionWindow: retentionWindow,
            now: now,
            fileManager: fileManager
        )
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
            guard let referenceDate = transcriptDate(
                forAudioDirectory: directory,
                meetingsFolder: meetingsFolder,
                fileManager: fileManager
            ), referenceDate < cutoff else {
                continue
            }

            do {
                try fileManager.removeItem(at: directory)
                removedCount += 1
            } catch {
                continue
            }
        }

        return removedCount
    }

    @discardableResult
    static func compressWAVAudio(
        in audioDirectory: URL,
        fileManager: FileManager = .default,
        converter: MeetingAudioFileConverting = AVFoundationMeetingAudioConverter(),
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator()
    ) async -> Int {
        guard let files = try? fileManager.contentsOfDirectory(
            at: audioDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var convertedCount = 0
        for sourceURL in files where isWAVFile(sourceURL, fileManager: fileManager) {
            let destinationURL = sourceURL.deletingPathExtension().appendingPathExtension("m4a")

            if validator.isUsableAudioFile(at: destinationURL, fileManager: fileManager) {
                try? fileManager.removeItem(at: sourceURL)
                continue
            }

            let tempURL = audioDirectory
                .appendingPathComponent(".\(sourceURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString)")
                .appendingPathExtension("m4a")

            do {
                try await converter.convertWAVToM4A(sourceURL: sourceURL, destinationURL: tempURL)
                guard validator.isUsableAudioFile(at: tempURL, fileManager: fileManager) else {
                    throw MeetingAudioStorageError.emptyConvertedFile
                }
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: tempURL, to: destinationURL)
                try fileManager.removeItem(at: sourceURL)
                convertedCount += 1
            } catch {
                try? fileManager.removeItem(at: tempURL)
                continue
            }
        }

        return convertedCount
    }

    private static func audioArchiveDirectoriesWithTranscripts(
        in meetingsFolder: URL,
        fileManager: FileManager
    ) -> [URL] {
        let audioRoot = meetingsFolder.appendingPathComponent("audio", isDirectory: true)
        guard let directories = try? fileManager.contentsOfDirectory(
            at: audioRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.filter { directory in
            isAudioArchiveDirectory(directory, fileManager: fileManager)
                && transcriptDate(
                    forAudioDirectory: directory,
                    meetingsFolder: meetingsFolder,
                    fileManager: fileManager
                ) != nil
        }
    }

    private static func audioDirectoryURL(forTranscript transcriptURL: URL) -> URL {
        transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
    }

    private static func isAudioArchiveDirectory(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.lastPathComponent.hasSuffix("_audio") else { return false }
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func transcriptDate(
        forAudioDirectory audioDirectory: URL,
        meetingsFolder: URL,
        fileManager: FileManager
    ) -> Date? {
        let name = audioDirectory.lastPathComponent
        guard name.hasSuffix("_audio") else { return nil }
        let stem = String(name.dropLast("_audio".count))
        let transcriptURL = meetingsFolder.appendingPathComponent(stem).appendingPathExtension("md")
        guard fileManager.fileExists(atPath: transcriptURL.path) else { return nil }
        return modificationDate(for: transcriptURL)
    }

    private static func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private static func isWAVFile(_ url: URL, fileManager: FileManager) -> Bool {
        guard url.pathExtension.localizedCaseInsensitiveCompare("wav") == .orderedSame else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }

    private static func hasNonEmptyFile(at url: URL, fileManager: FileManager) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
    }
}
