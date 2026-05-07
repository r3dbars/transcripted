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
    private static let frontmatterPreviewByteLimit = 64 * 1024
    private static let staleTemporaryM4AAge: TimeInterval = 10 * 60
    private static let managedAudioStems = ["microphone", "system_audio", "recording", "playback"]
    private static let transcriptDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

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
                now: now,
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
            now: now,
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
            || isTranscriptedTemporaryM4AFileName(file) {
            do {
                try fileManager.removeItem(at: file)
                removedAny = true
            } catch {
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
    static func compressWAVAudio(
        in audioDirectory: URL,
        now: Date = Date(),
        fileManager: FileManager = .default,
        converter: MeetingAudioFileConverting = AVFoundationMeetingAudioConverter(),
        validator: MeetingAudioFileValidating = AVFoundationMeetingAudioValidator()
    ) async -> Int {
        guard isSafeNonSymlinkDirectory(audioDirectory, fileManager: fileManager) else { return 0 }
        removeStaleTemporaryM4AFiles(in: audioDirectory, now: now, fileManager: fileManager)

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
                fileManager.restrictFileToOwnerOnly(at: destinationURL)
                try fileManager.removeItem(at: sourceURL)
                convertedCount += 1
            } catch {
                try? fileManager.removeItem(at: tempURL)
                continue
            }
        }

        return convertedCount
    }

    @discardableResult
    static func removeStaleTemporaryM4AFiles(
        in audioDirectory: URL,
        now: Date = Date(),
        minimumAge: TimeInterval = staleTemporaryM4AAge,
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
        for file in files where isStaleTemporaryM4AFile(
            file,
            now: now,
            minimumAge: minimumAge,
            fileManager: fileManager
        ) {
            do {
                try fileManager.removeItem(at: file)
                removedCount += 1
            } catch {
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
        transcriptURL
            .deletingLastPathComponent()
            .appendingPathComponent("audio", isDirectory: true)
            .appendingPathComponent("\(transcriptURL.deletingPathExtension().lastPathComponent)_audio", isDirectory: true)
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
              let values = frontmatterValues(in: raw),
              values["capture_type"]?.lowercased() == "meeting" else {
            return false
        }

        return isValidTranscriptIdentifier(values["transcript_id"])
            || isValidTranscriptIdentifier(values["capture_id"])
    }

    private static func transcriptReferenceDate(for url: URL, raw: String) -> Date {
        if let frontmatterDate = frontmatterRecordedDate(in: raw) {
            return frontmatterDate
        }

        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private static func frontmatterRecordedDate(in raw: String) -> Date? {
        guard let values = frontmatterValues(in: raw) else { return nil }
        guard let date = values["date"], let time = values["time"] else { return nil }
        return transcriptDateFormatter.date(from: "\(date) \(time)")
    }

    private static func frontmatterValues(in raw: String) -> [String: String]? {
        guard let lines = frontmatterLines(in: raw) else { return nil }
        var values: [String: String] = [:]
        for line in lines {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        return values
    }

    private static func isValidTranscriptIdentifier(_ value: String?) -> Bool {
        guard let value else { return false }
        return UUID(uuidString: value) != nil
    }

    private static func frontmatterLines(in raw: String) -> [String]? {
        guard raw.hasPrefix("---\n"),
              let endRange = raw.range(
                of: "\n---\n",
                range: raw.index(raw.startIndex, offsetBy: 4)..<raw.endIndex
              ) else {
            return nil
        }

        let frontmatterText = String(raw[raw.index(raw.startIndex, offsetBy: 4)..<endRange.lowerBound])
        return frontmatterText.components(separatedBy: "\n")
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

    private static func restrictRetainedM4AFiles(_ files: [URL], fileManager: FileManager) {
        for file in files where file.pathExtension.localizedCaseInsensitiveCompare("m4a") == .orderedSame
            && isManagedRetainedAudioFile(file, fileManager: fileManager) {
            fileManager.restrictFileToOwnerOnly(at: file)
        }
    }

    private static func isStaleTemporaryM4AFile(
        _ url: URL,
        now: Date,
        minimumAge: TimeInterval,
        fileManager: FileManager
    ) -> Bool {
        guard isTranscriptedTemporaryM4AFileName(url) else { return false }
        guard !isSymbolicLink(url, fileManager: fileManager) else { return false }
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
        guard values?.isRegularFile == true, let modified = values?.contentModificationDate else {
            return false
        }
        return now.timeIntervalSince(modified) >= max(0, minimumAge)
    }

    private static func isTranscriptedTemporaryM4AFileName(_ url: URL) -> Bool {
        guard url.pathExtension.localizedCaseInsensitiveCompare("m4a") == .orderedSame else { return false }
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
}
