// DictationStoppedAudioRecovery.swift
// Durable audio checkpoint for a stopped dictation awaiting transcription.

import Foundation
import Darwin
import CryptoKit

struct DictationStoppedAudioRecovery: Equatable, Sendable {
    let url: URL
    let sessionID: UUID
    let createdAt: Date
}

struct DictationStoppedAudioRecoveryRetryRegistry {
    private var recoveries: [UUID: DictationStoppedAudioRecovery] = [:]

    mutating func retain(_ recovery: DictationStoppedAudioRecovery, for failedMeetingID: UUID) {
        recoveries[failedMeetingID] = recovery
    }

    func recovery(for failedMeetingID: UUID) -> DictationStoppedAudioRecovery? {
        recoveries[failedMeetingID]
    }

    mutating func remove(for failedMeetingID: UUID) -> DictationStoppedAudioRecovery? {
        recoveries.removeValue(forKey: failedMeetingID)
    }
}

enum DictationStoppedAudioRecoveryCommitPolicy {
    static func shouldPersist(
        taskCancelled: Bool,
        isDictating: Bool,
        taskSessionID: UUID,
        currentSessionID: UUID
    ) -> Bool {
        !taskCancelled && isDictating && taskSessionID == currentSessionID
    }

    static func shouldRetainPersistedRecovery(
        taskSessionID: UUID,
        preservationSessionID: UUID?
    ) -> Bool {
        taskSessionID == preservationSessionID
    }
}

enum DictationStoppedAudioRecoveryStore {
    static let sampleRate: UInt32 = 16_000

    private struct Metadata: Codable {
        let version: Int
        let sessionID: UUID
        let createdAt: Date
        let audioFilename: String
        var archiveIntent: ArchiveIntent? = nil
        var retentionRequested: Bool? = nil
    }

    private struct ArchiveIntent: Codable {
        let relativePath: String
        let dictationsFolder: URL
        let checkpointDigest: String
        var transcriptCommitted: Bool? = nil
    }

    static var defaultDirectory: URL {
        FileManager.default.transcriptedStateDir
            .appendingPathComponent("dictation-audio-recovery", isDirectory: true)
    }

    static func persist(
        samples16k: [Float],
        sessionID: UUID,
        createdAt: Date = Date(),
        retentionRequested: Bool = false,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> DictationStoppedAudioRecovery? {
        // No storage-mutation lock: the stop path awaits this before paste,
        // and the lock's other owners hold it through library writes and
        // compression. Nothing else can touch this take's files yet. They're
        // new and named for this session. The folder-wide passes keep them:
        // the launch purge only removes files from before launch, and audio
        // retry only reads receipts with a committed transcript.
        guard !samples16k.isEmpty else { return nil }

        let folder = directory ?? defaultDirectory
        try fileManager.createPrivateDirectory(at: folder)
        let url = folder.appendingPathComponent("dictation_\(sessionID.uuidString.lowercased()).wav")
        try wavData(samples16k: samples16k).write(to: url, options: .atomic)
        fileManager.restrictFileToOwnerOnly(at: url)
        try synchronizeFileAndDirectory(url)
        let recovery = DictationStoppedAudioRecovery(url: url, sessionID: sessionID, createdAt: createdAt)
        do {
            try writeMetadata(for: recovery, retentionRequested: retentionRequested, fileManager: fileManager)
        } catch {
            try? fileManager.removeItem(at: url)
            throw error
        }
        return recovery
    }

    static func pendingRecoveries(
        limit: Int = 10,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> [DictationStoppedAudioRecovery] {
        guard limit > 0 else { return [] }
        let folder = directory ?? defaultDirectory
        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return [] }

        var recoveries: [DictationStoppedAudioRecovery] = []
        for case let metadataURL as URL in enumerator where metadataURL.pathExtension == "json" {
            guard let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL)),
                  metadata.version == 1 else { continue }
            let audioURL = folder.appendingPathComponent(metadata.audioFilename, isDirectory: false)
            guard fileManager.fileExists(atPath: audioURL.path) else { continue }
            recoveries.append(DictationStoppedAudioRecovery(
                url: audioURL,
                sessionID: metadata.sessionID,
                createdAt: metadata.createdAt
            ))
        }
        return mostRecent(recoveries, limit: limit)
    }

    static func mostRecent(
        _ recoveries: [DictationStoppedAudioRecovery],
        limit: Int
    ) -> [DictationStoppedAudioRecovery] {
        guard limit > 0 else { return [] }
        return Array(
            recoveries
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit)
        )
    }

    @discardableResult
    static func cleanup(
        _ recovery: DictationStoppedAudioRecovery?,
        transcriptPersisted: Bool = false,
        explicitDiscard: Bool = false,
        fileManager: FileManager = .default
    ) -> Bool {
        DictationAudioArchive.lockStorageMutation()
        defer { DictationAudioArchive.unlockStorageMutation() }
        guard transcriptPersisted || explicitDiscard,
              let recovery else { return false }

        do {
            if fileManager.fileExists(atPath: recovery.url.path) {
                try fileManager.removeItem(at: recovery.url)
            }
            let metadataURL = metadataURL(for: recovery.url)
            if fileManager.fileExists(atPath: metadataURL.path) {
                try fileManager.removeItem(at: metadataURL)
            }
            return true
        } catch {
            return false
        }
    }

    /// Retires a take's checkpoint once its transcript is saved. A failed
    /// save keeps the WAV. Requested retention also protects it from the
    /// next launch's short-take purge. When the saved
    /// entry recorded an `Audio:` path, the WAV moves into the dictation
    /// audio archive (and gets compressed in the background) instead of
    /// being deleted. A failed archive keeps the checkpoint and its durable
    /// archive intent; neither text success nor the short-take purge owns it.
    @discardableResult
    static func retire(
        _ recovery: DictationStoppedAudioRecovery?,
        afterSaving result: DictationTranscriptPersistenceResult,
        keptAudioRelativePath: String? = nil,
        dictationsFolder: URL? = nil,
        fileManager: FileManager = .default,
        compressKeptAudio: (URL) -> Void = DictationAudioArchive.compressInBackground
    ) -> Bool {
        DictationAudioArchive.lockStorageMutation()
        defer { DictationAudioArchive.unlockStorageMutation() }
        if result.saved != nil, let recovery, let keptAudioRelativePath {
            // Direct callers also get durable ownership. The shared save path
            // records this before Markdown, closing the save/crash gap.
            guard (try? markArchiveIntent(
                recovery, relativePath: keptAudioRelativePath,
                dictationsFolder: dictationsFolder, fileManager: fileManager
            )) != nil else { return false }
            // An intent protects audio across a save/crash boundary but is
            // not evidence of saved words. Maintenance owns only receipts
            // whose text save actually completed and was checkpointed.
            guard (try? markTranscriptCommitted(recovery, fileManager: fileManager)) != nil else { return false }
            guard let keptURL = DictationAudioArchive.keep(
               recovery: recovery,
               relativePath: keptAudioRelativePath,
               dictationsFolder: dictationsFolder,
               fileManager: fileManager
           ) else { return false }
            compressKeptAudio(keptURL)
            return true
        }
        return cleanup(recovery, transcriptPersisted: result.saved != nil, fileManager: fileManager)
    }

    /// The one save rule for a finished take, shared by the async and the
    /// synchronous save paths: decide whether this take's audio is kept,
    /// save the transcript (with its `Audio:` path when kept), then retire
    /// the checkpoint. `save` receives the path to record, or nil.
    static func saveTranscriptAndRetire(
        recovery: DictationStoppedAudioRecovery?,
        keepWindow: DictationAudioKeepWindow,
        currentKeepWindow: (() -> DictationAudioKeepWindow)? = nil,
        dictationsFolder: URL? = nil,
        fileManager: FileManager = .default,
        compressKeptAudio: (URL) -> Void = DictationAudioArchive.compressInBackground,
        save: (_ audioRelativePath: String?) throws -> SavedDictationTranscript
    ) -> DictationTranscriptPersistenceResult {
        DictationAudioArchive.lockStorageMutation()
        defer { DictationAudioArchive.unlockStorageMutation() }
        // A detached save can wait behind Off/Delete. Read the production
        // preference only after acquiring ownership, not when the task queued.
        let keepWindow = currentKeepWindow?() ?? keepWindow
        let audioRelativePath = DictationAudioArchive.plannedRelativePath(
            for: recovery,
            window: keepWindow,
            fileManager: fileManager
        )
        var result = DictationTranscriptPersistenceResult.measure {
            if let recovery, let audioRelativePath {
                // Write-ahead ownership: a crash after text save must not let
                // launch classify this as a disposable failed short take.
                try markArchiveIntent(
                    recovery, relativePath: audioRelativePath,
                    dictationsFolder: dictationsFolder, fileManager: fileManager
                )
            }
            return try save(audioRelativePath)
        }
        let retired = retire(
            recovery,
            afterSaving: result,
            keptAudioRelativePath: audioRelativePath,
            dictationsFolder: dictationsFolder,
            fileManager: fileManager,
            compressKeptAudio: compressKeptAudio
        )
        if result.saved != nil, audioRelativePath != nil, !retired {
            result.pendingAudioRetention = recovery
        }
        return result
    }

    private static func markArchiveIntent(
        _ recovery: DictationStoppedAudioRecovery,
        relativePath: String,
        dictationsFolder: URL?,
        fileManager: FileManager
    ) throws {
        guard DictationAudioArchive.takeStem(fromRelativePath: relativePath)
                == recovery.sessionID.uuidString.lowercased() else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        var metadata = try readOwnedMetadata(for: recovery.url, fileManager: fileManager)
        let folder = (dictationsFolder ?? DictationStoragePaths.transcriptsFolder).standardizedFileURL
        if metadata.archiveIntent?.relativePath == relativePath,
           metadata.archiveIntent?.dictationsFolder == folder { return }
        metadata.archiveIntent = ArchiveIntent(
            relativePath: relativePath,
            dictationsFolder: folder,
            checkpointDigest: try checkpointDigest(at: recovery.url)
        )
        try write(metadata, to: metadataURL(for: recovery.url), fileManager: fileManager)
    }

    private static func markTranscriptCommitted(
        _ recovery: DictationStoppedAudioRecovery,
        fileManager: FileManager
    ) throws {
        var metadata = try readOwnedMetadata(for: recovery.url, fileManager: fileManager)
        guard metadata.archiveIntent != nil else { throw CocoaError(.fileReadCorruptFile) }
        if metadata.archiveIntent?.transcriptCommitted == true { return }
        metadata.archiveIntent?.transcriptCommitted = true
        try write(metadata, to: metadataURL(for: recovery.url), fileManager: fileManager)
    }

    /// The current save result proves this exact take's text committed even
    /// if recording that proof failed. Repair only its audio, never its text.
    @discardableResult
    static func retryRetainedAudio(
        recovery: DictationStoppedAudioRecovery,
        afterSaving result: DictationTranscriptPersistenceResult,
        window: DictationAudioKeepWindow,
        currentKeepWindow: (() -> DictationAudioKeepWindow)? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default,
        compressKeptAudio: (URL) -> Void = DictationAudioArchive.compressInBackground
    ) -> Bool {
        DictationAudioArchive.lockStorageMutation()
        defer { DictationAudioArchive.unlockStorageMutation() }
        guard result.saved != nil, result.pendingAudioRetention == recovery,
              let metadata = try? readOwnedMetadata(for: recovery.url, fileManager: fileManager),
              let intent = metadata.archiveIntent else { return false }
        let window = currentKeepWindow?() ?? window
        if let days = window.days, days == 0 || metadata.createdAt < now.addingTimeInterval(-Double(days) * 86_400) {
            return cleanup(recovery, explicitDiscard: true, fileManager: fileManager)
        }
        return retire(recovery, afterSaving: result, keptAudioRelativePath: intent.relativePath,
                      dictationsFolder: intent.dictationsFolder, fileManager: fileManager,
                      compressKeptAudio: compressKeptAudio)
    }

    /// Audio-only retry. The receipt identifies the original library; it never
    /// calls a transcript writer, even after restart or repeated invocation.
    @discardableResult
    static func retryPendingAudioRetention(
        directory: URL? = nil,
        dictationsFolder: URL? = nil,
        window: DictationAudioKeepWindow,
        currentKeepWindow: (() -> DictationAudioKeepWindow)? = nil,
        now: Date = Date(),
        fileManager: FileManager = .default,
        onDiscard: (DictationStoppedAudioRecovery) -> Void = { _ in },
        compressKeptAudio: (URL) -> Void = DictationAudioArchive.compressInBackground
    ) -> Int {
        DictationAudioArchive.lockStorageMutation()
        defer { DictationAudioArchive.unlockStorageMutation() }
        let window = currentKeepWindow?() ?? window
        let folder = directory ?? defaultDirectory
        guard let contents = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return 0 }
        var retired = 0
        for receipt in contents where receipt.pathExtension == "json" {
            let url = receipt.deletingPathExtension().appendingPathExtension("wav")
            guard let metadata = try? readOwnedMetadata(for: url, allowMissingAudio: true, fileManager: fileManager),
                  metadata.archiveIntent?.transcriptCommitted == true else { continue }
            if let dictationsFolder, let intent = metadata.archiveIntent,
               intent.dictationsFolder != dictationsFolder.standardizedFileURL { continue }
            let recovery = DictationStoppedAudioRecovery(url: url, sessionID: metadata.sessionID, createdAt: metadata.createdAt)
            if let days = window.days, days == 0 || metadata.createdAt < now.addingTimeInterval(-Double(days) * 86_400) {
                if cleanup(recovery, explicitDiscard: true, fileManager: fileManager) {
                    onDiscard(recovery)
                    retired += 1
                }
            } else if !fileManager.fileExists(atPath: url.path), let intent = metadata.archiveIntent,
                      let stem = DictationAudioArchive.takeStem(fromRelativePath: intent.relativePath) {
                // Crash after durable archive publication and source removal,
                // but before metadata retirement: UUID/name alone is not proof.
                let archived = DictationAudioArchive.audioFolder(in: intent.dictationsFolder).appendingPathComponent("\(stem).wav")
                guard (try? fileManager.attributesOfItem(atPath: archived.deletingLastPathComponent().path))?[.type] as? FileAttributeType == .typeDirectory,
                      (try? fileManager.attributesOfItem(atPath: archived.path))?[.type] as? FileAttributeType == .typeRegular,
                      (try? checkpointDigest(at: archived)) == intent.checkpointDigest else { continue }
                removeMetadata(forAudioURL: url, fileManager: fileManager)
                compressKeptAudio(archived)
                retired += 1
            } else if let intent = metadata.archiveIntent, let kept = DictationAudioArchive.keep(
                recovery: recovery, relativePath: intent.relativePath,
                dictationsFolder: intent.dictationsFolder, fileManager: fileManager
            ) {
                compressKeptAudio(kept)
                retired += 1
            }
        }
        return retired
    }

    /// Resolve only a receipt for this exact UUID and library. Unrelated
    /// failed takes, malformed receipts and symlinks cannot become playback.
    static func pendingAudioURL(
        relativePath: String,
        dictationsFolder: URL,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        guard let stem = DictationAudioArchive.takeStem(fromRelativePath: relativePath) else { return nil }
        let url = (directory ?? defaultDirectory).appendingPathComponent("dictation_\(stem).wav")
        guard let metadata = try? readOwnedMetadata(for: url, fileManager: fileManager),
              metadata.archiveIntent?.transcriptCommitted == true,
              metadata.archiveIntent?.relativePath == relativePath,
              metadata.archiveIntent?.dictationsFolder == dictationsFolder.standardizedFileURL else { return nil }
        return url
    }

    @discardableResult
    static func deletePendingAudio(
        relativePath: String,
        dictationsFolder: URL,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Bool {
        guard let url = pendingAudioURL(relativePath: relativePath, dictationsFolder: dictationsFolder,
                                       directory: directory, fileManager: fileManager),
              let metadata = try? readOwnedMetadata(for: url, fileManager: fileManager) else { return false }
        return cleanup(.init(url: url, sessionID: metadata.sessionID, createdAt: metadata.createdAt),
                       explicitDiscard: true, fileManager: fileManager)
    }

    private static func readOwnedMetadata(
        for audioURL: URL,
        allowMissingAudio: Bool = false,
        fileManager: FileManager
    ) throws -> Metadata {
        let metadataURL = metadataURL(for: audioURL)
        let audioIsOwned = (allowMissingAudio && !fileManager.fileExists(atPath: audioURL.path))
            || (try? fileManager.attributesOfItem(atPath: audioURL.path))?[.type] as? FileAttributeType == .typeRegular
        guard (try fileManager.attributesOfItem(atPath: audioURL.deletingLastPathComponent().path))[.type] as? FileAttributeType == .typeDirectory,
              audioIsOwned,
              (try fileManager.attributesOfItem(atPath: metadataURL.path))[.type] as? FileAttributeType == .typeRegular else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let metadata = try JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL))
        guard metadata.version == 1,
              metadata.audioFilename == audioURL.lastPathComponent,
              audioURL.lastPathComponent == "dictation_\(metadata.sessionID.uuidString.lowercased()).wav",
              metadata.archiveIntent.map({
                  $0.dictationsFolder.isFileURL && $0.dictationsFolder.path.hasPrefix("/")
                      && $0.checkpointDigest.count == 64
                      && DictationAudioArchive.takeStem(fromRelativePath: $0.relativePath) == metadata.sessionID.uuidString.lowercased()
              }) ?? true else { throw CocoaError(.fileReadCorruptFile) }
        return metadata
    }

    private static func checkpointDigest(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 65_536), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Drops the restart-discovery metadata for a checkpoint WAV (used once
    /// the WAV has moved into the dictation audio archive).
    static func removeMetadata(forAudioURL audioURL: URL, fileManager: FileManager = .default) {
        let url = metadataURL(for: audioURL)
        if fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    /// Deletes short recordings saved before `cutoff`, with their metadata.
    /// Launch runs this with the launch time, and nothing asks about what's
    /// left. A take under 30 s (`DictationFailedTakePolicy`) is cheaper to
    /// say again, so its WAV from an earlier run (a failed take nobody
    /// transcribed, or one left by Quit or a crash) is just private audio
    /// sitting on disk. A take of 30 s or more stays on disk quietly, and so
    /// does any WAV whose length can't be read: never delete on a guess.
    /// Files from this run are newer than `cutoff` and stay. Only
    /// `dictation_*.wav` and `dictation_*.json` directly inside `directory`
    /// are touched. Returns how many recordings were removed.
    @discardableResult
    static func purgeLeftovers(
        createdBefore cutoff: Date,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) -> Int {
        DictationAudioArchive.lockStorageMutation()
        defer { DictationAudioArchive.unlockStorageMutation() }
        let folder = (directory ?? defaultDirectory).standardizedFileURL
        guard let contents = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        // Both sides resolved the same way, so /var vs /private/var can't
        // make a file look like it lives somewhere else.
        func resolvedPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardizedFileURL.path
        }
        let folderPath = resolvedPath(folder)
        func isOwnedFile(_ url: URL, extension pathExtension: String) -> Bool {
            url.lastPathComponent.hasPrefix("dictation_")
                && url.pathExtension == pathExtension
                && resolvedPath(url.deletingLastPathComponent()) == folderPath
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }
        func modifiedBeforeCutoff(_ url: URL) -> Bool {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else {
                return false
            }
            return modified < cutoff
        }
        // An unreadable length counts as long: keep the file.
        func isShortTake(_ audioURL: URL) -> Bool {
            guard let seconds = recordedDuration(ofWAVAt: audioURL) else { return false }
            return !DictationFailedTakePolicy.keepsSavedRecording(takeLength: seconds)
        }

        var removed = 0
        var claimedAudio: Set<String> = []
        for metadataURL in contents where isOwnedFile(metadataURL, extension: "json") {
            let audioURL: URL?
            let isOld: Bool
            if let metadata = try? JSONDecoder().decode(Metadata.self, from: Data(contentsOf: metadataURL)) {
                let candidate = folder.appendingPathComponent(metadata.audioFilename, isDirectory: false)
                audioURL = isOwnedFile(candidate, extension: "wav") ? candidate : nil
                if metadata.archiveIntent != nil || metadata.retentionRequested == true {
                    // Pending retention is not a failed take. Claim even a
                    // short WAV so the orphan pass cannot discard it either.
                    if let audioURL { claimedAudio.insert(audioURL.lastPathComponent) }
                    continue
                }
                isOld = metadata.createdAt < cutoff
            } else {
                // Unreadable metadata from an older or broken write. Its
                // WAV, if any, has the same name.
                let sibling = metadataURL.deletingPathExtension().appendingPathExtension("wav")
                audioURL = isOwnedFile(sibling, extension: "wav") ? sibling : nil
                isOld = modifiedBeforeCutoff(metadataURL)
            }
            if let audioURL { claimedAudio.insert(audioURL.lastPathComponent) }
            guard isOld else { continue }
            if let audioURL {
                // A long take keeps its WAV and the metadata beside it.
                guard isShortTake(audioURL) else { continue }
                do {
                    try fileManager.removeItem(at: audioURL)
                } catch {
                    continue
                }
            }
            // No WAV of ours is left behind this metadata, so it holds no audio.
            try? fileManager.removeItem(at: metadataURL)
            removed += 1
        }
        // A WAV without metadata: the app stopped between the two writes.
        // Its file date says which run it came from.
        for audioURL in contents where isOwnedFile(audioURL, extension: "wav")
            && !claimedAudio.contains(audioURL.lastPathComponent)
            && !fileManager.fileExists(atPath: metadataURL(for: audioURL).path)
            && modifiedBeforeCutoff(audioURL)
            && isShortTake(audioURL) {
            try? fileManager.removeItem(at: audioURL)
            removed += 1
        }
        return removed
    }

    /// How much audio a recovery WAV holds: the bytes on disk after its
    /// `data` chunk header over the `fmt ` chunk's sample rate and frame
    /// size. Nil when it can't tell (not a RIFF/WAVE file, or no `fmt ` and
    /// `data` chunk in the first 4 KB).
    static func recordedDuration(ofWAVAt url: URL) -> TimeInterval? {
        guard let fileSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4_096) else { return nil }
        let bytes = [UInt8](header)

        func uint16(at offset: Int) -> UInt16? {
            guard offset >= 0, offset + 2 <= bytes.count else { return nil }
            return UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
        }
        func uint32(at offset: Int) -> UInt32? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
        }
        func tag(at offset: Int) -> String? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
        }

        guard tag(at: 0) == "RIFF", tag(at: 8) == "WAVE" else { return nil }
        var sampleRate: UInt32?
        var blockAlign: UInt16?
        var offset = 12
        while let chunkID = tag(at: offset), let chunkSize = uint32(at: offset + 4) {
            let body = offset + 8
            if chunkID == "fmt " {
                sampleRate = uint32(at: body + 4)
                blockAlign = uint16(at: body + 12)
            } else if chunkID == "data" {
                guard let sampleRate, sampleRate > 0,
                      let blockAlign, blockAlign > 0 else { return nil }
                // Count what's on disk after the data header rather than the
                // header's own count: a count never filled in (0) or a chunk
                // after the audio can only make this longer, and longer keeps.
                let dataBytes = fileSize > body ? UInt64(fileSize - body) : 0
                return Double(dataBytes / UInt64(blockAlign)) / Double(sampleRate)
            }
            // Chunks are padded to an even length.
            offset = body + Int(chunkSize) + Int(chunkSize % 2)
        }
        return nil
    }

    private static func writeMetadata(
        for recovery: DictationStoppedAudioRecovery,
        retentionRequested: Bool,
        fileManager: FileManager
    ) throws {
        let metadata = Metadata(
            version: 1,
            sessionID: recovery.sessionID,
            createdAt: recovery.createdAt,
            audioFilename: recovery.url.lastPathComponent,
            retentionRequested: retentionRequested
        )
        try write(metadata, to: metadataURL(for: recovery.url), fileManager: fileManager)
    }

    private static func write(_ metadata: Metadata, to url: URL, fileManager: FileManager) throws {
        try JSONEncoder().encode(metadata).write(to: url, options: .atomic)
        fileManager.restrictFileToOwnerOnly(at: url)
        try synchronizeFileAndDirectory(url)
    }

    /// Check file and containing-directory persistence before a caller gives
    /// up another copy. Atomic replacement alone is not a power-loss fence.
    static func synchronizeFileAndDirectory(_ url: URL) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let descriptor = open(url.deletingLastPathComponent().path, O_RDONLY)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func metadataURL(for audioURL: URL) -> URL {
        audioURL.deletingPathExtension().appendingPathExtension("json")
    }

    private static func wavData(samples16k: [Float]) -> Data {
        let bytesPerSample: UInt16 = 2
        let channelCount: UInt16 = 1
        let dataByteCount = UInt32(samples16k.count) * UInt32(bytesPerSample)
        var data = Data(capacity: 44 + Int(dataByteCount))

        data.append(contentsOf: "RIFF".utf8)
        append(UInt32(36) + dataByteCount, to: &data)
        data.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16), to: &data)
        append(UInt16(1), to: &data)
        append(channelCount, to: &data)
        append(sampleRate, to: &data)
        append(sampleRate * UInt32(channelCount) * UInt32(bytesPerSample), to: &data)
        append(channelCount * bytesPerSample, to: &data)
        append(UInt16(16), to: &data)
        data.append(contentsOf: "data".utf8)
        append(dataByteCount, to: &data)

        // Convert into one contiguous Int16 block, then append it in a single
        // call. The per-sample `append(_:to:)` helper pays a `withUnsafeBytes`
        // closure plus a `Sequence` append for every sample, which dominated
        // this function: at a 5-minute take that is 4.8M round trips.
        // The arithmetic below is byte-for-byte the old expression — the NaN
        // guard, the clamp, `Float(Int16.max)`, and bare `.rounded()`
        // (schoolbook, half-away-from-zero) are all load-bearing for that.
        let pcm = [Int16](unsafeUninitializedCapacity: samples16k.count) { buffer, initializedCount in
            samples16k.withUnsafeBufferPointer { source in
                for index in 0..<source.count {
                    let sample = source[index]
                    let finiteSample = sample.isFinite ? sample : 0
                    let clamped = max(-1, min(1, finiteSample))
                    buffer[index] = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
                }
            }
            initializedCount = samples16k.count
        }
        pcm.withUnsafeBufferPointer { data.append($0) }
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
