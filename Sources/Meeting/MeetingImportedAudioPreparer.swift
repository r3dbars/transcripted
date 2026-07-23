import Foundation
import AVFoundation
import Darwin
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif
import UniformTypeIdentifiers

struct PreparedImportedMeetingAudio: Sendable {
    let copiedAudioURL: URL
    let suggestedTitle: String
    let recordingDate: Date
}

enum ImportedTranscriptionQueueJournal {
    private static let filenamePrefix = "import-job-"
    private static let filenameExtension = "json"
    private static let lockFilenameExtension = "lock"
    private static let maximumRecordBytes = 64 * 1024

    enum RecoveryAudioStatus: Equatable {
        case regularFile
        case missing
        case unsafeEntry
    }

    static func persist(
        id: UUID,
        audioURL: URL,
        recordingDate: Date,
        enqueuedAt: Date = Date(),
        sttModelRawValue: String,
        journalDirectory: URL,
        scratchDirectory: URL,
        fileManager: FileManager = .default
    ) throws {
        let normalizedAudioURL = audioURL.standardizedFileURL
        let normalizedScratchDirectory = scratchDirectory.standardizedFileURL
        guard normalizedAudioURL.deletingLastPathComponent() == normalizedScratchDirectory else {
            throw ImportedTranscriptionQueueJournalError.audioOutsideScratchDirectory
        }

        fileManager.ensurePrivateDirectory(
            at: journalDirectory,
            context: "imported transcription queue journal"
        )
        let record = ImportedTranscriptionQueueJournalRecord(
            id: id,
            audioFilename: normalizedAudioURL.lastPathComponent,
            recordingDate: recordingDate,
            enqueuedAt: enqueuedAt,
            sttModelRawValue: sttModelRawValue
        )
        try write(record, journalDirectory: journalDirectory, fileManager: fileManager)
    }

    /// Creates the initial record only after taking its process lease, so no
    /// other process can observe recoverable work before its owner is live.
    static func createClaimed(
        id: UUID,
        audioURL: URL,
        recordingDate: Date,
        enqueuedAt: Date = Date(),
        sttModelRawValue: String,
        journalDirectory: URL,
        scratchDirectory: URL,
        processIdentifier: Int32 = getpid(),
        claimedAt: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> ImportedTranscriptionQueueJournalSession {
        let normalizedAudioURL = audioURL.standardizedFileURL
        guard normalizedAudioURL.deletingLastPathComponent() == scratchDirectory.standardizedFileURL else {
            throw ImportedTranscriptionQueueJournalError.audioOutsideScratchDirectory
        }
        let record = ImportedTranscriptionQueueJournalRecord(
            id: id,
            audioFilename: normalizedAudioURL.lastPathComponent,
            recordingDate: recordingDate,
            enqueuedAt: enqueuedAt,
            sttModelRawValue: sttModelRawValue
        )
        guard let session = try claim(
            id: id,
            journalDirectory: journalDirectory,
            processIdentifier: processIdentifier,
            claimedAt: claimedAt,
            fileManager: fileManager,
            recordToPublish: record
        ) else {
            throw ImportedTranscriptionQueueJournalError.claimFailed
        }
        return session
    }

    static func load(
        journalDirectory: URL,
        fileManager: FileManager = .default
    ) -> [ImportedTranscriptionQueueJournalRecord] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: journalDirectory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls
            .filter {
                $0.pathExtension == filenameExtension
                    && $0.deletingPathExtension().lastPathComponent.hasPrefix(filenamePrefix)
            }
            .compactMap { url in
                guard let record = readRecord(from: url),
                      !record.audioFilename.isEmpty,
                      URL(fileURLWithPath: record.audioFilename).lastPathComponent == record.audioFilename
                else { return nil }
                return record
            }
            .sorted { lhs, rhs in
                if lhs.enqueuedAt == rhs.enqueuedAt {
                    return lhs.id.uuidString < rhs.id.uuidString
                }
                return lhs.enqueuedAt < rhs.enqueuedAt
            }
    }

    @discardableResult
    static func remove(
        id: UUID,
        journalDirectory: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            try fileManager.removeItem(at: journalURL(for: id, in: journalDirectory))
            synchronizeDirectory(journalDirectory)
            return true
        } catch {
            if (error as NSError).code == NSFileNoSuchFileError {
                return true
            }
            return false
        }
    }

    /// Claims one journal with an advisory lock held for the lifetime of the
    /// returned session. A second process receives `nil`; a crashed owner loses
    /// the kernel lock automatically and the next process can recover the work.
    static func claim(
        id: UUID,
        journalDirectory: URL,
        processIdentifier: Int32 = getpid(),
        claimedAt: Date = Date(),
        fileManager: FileManager = .default,
        recordToPublish: ImportedTranscriptionQueueJournalRecord? = nil
    ) throws -> ImportedTranscriptionQueueJournalSession? {
        fileManager.ensurePrivateDirectory(
            at: journalDirectory,
            context: "imported transcription queue journal"
        )
        let lockURL = lockURL(for: id, in: journalDirectory)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw ImportedTranscriptionQueueJournalError.claimFailed
        }

        var lockStatus = stat()
        guard fstat(descriptor, &lockStatus) == 0,
              (lockStatus.st_mode & S_IFMT) == S_IFREG else {
            Darwin.close(descriptor)
            throw ImportedTranscriptionQueueJournalError.claimFailed
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            if errno == EWOULDBLOCK || errno == EAGAIN {
                return nil
            }
            throw ImportedTranscriptionQueueJournalError.claimFailed
        }

        do {
            var record: ImportedTranscriptionQueueJournalRecord
            if let recordToPublish {
                var journalStatus = stat()
                guard lstat(journalURL(for: id, in: journalDirectory).path, &journalStatus) != 0,
                      errno == ENOENT else {
                    throw ImportedTranscriptionQueueJournalError.claimFailed
                }
                record = recordToPublish
            } else {
                guard let loaded = load(
                    id: id,
                    journalDirectory: journalDirectory,
                    fileManager: fileManager
                ) else {
                    throw ImportedTranscriptionQueueJournalError.journalMissing
                }
                record = loaded
            }
            if record.phase == .queued || record.phase == .active {
                record.phase = .active
            }
            record.owner = ImportedTranscriptionQueueJournalOwner(
                processIdentifier: processIdentifier,
                claimedAt: claimedAt
            )
            try write(record, journalDirectory: journalDirectory, fileManager: fileManager)
            fileManager.restrictFileToOwnerOnly(at: lockURL)
            return ImportedTranscriptionQueueJournalSession(
                record: record,
                journalDirectory: journalDirectory,
                lockDescriptor: descriptor,
                fileManager: fileManager
            )
        } catch {
            unlink(lockURL.path)
            flock(descriptor, LOCK_UN)
            Darwin.close(descriptor)
            throw error
        }
    }

    static func audioURL(
        for record: ImportedTranscriptionQueueJournalRecord,
        scratchDirectory: URL
    ) -> URL? {
        guard !record.audioFilename.isEmpty,
              URL(fileURLWithPath: record.audioFilename).lastPathComponent == record.audioFilename
        else { return nil }
        return scratchDirectory.appendingPathComponent(record.audioFilename, isDirectory: false)
    }

    static func recoveryAudioStatus(
        at audioURL: URL,
        scratchDirectory: URL
    ) -> RecoveryAudioStatus {
        let normalizedURL = audioURL.standardizedFileURL
        guard normalizedURL.deletingLastPathComponent() == scratchDirectory.standardizedFileURL else {
            return .unsafeEntry
        }

        var fileStatus = stat()
        guard lstat(normalizedURL.path, &fileStatus) == 0 else {
            return errno == ENOENT ? .missing : .unsafeEntry
        }
        return (fileStatus.st_mode & S_IFMT) == S_IFREG ? .regularFile : .unsafeEntry
    }

    static func isDuplicate(
        record: ImportedTranscriptionQueueJournalRecord,
        audioURL: URL,
        existingJobIDs: Set<UUID>,
        existingAudioURLs: Set<URL>
    ) -> Bool {
        existingJobIDs.contains(record.id)
            || existingAudioURLs.contains(audioURL.standardizedFileURL)
    }

    static func recoveryAction(
        phase: ImportedTranscriptionQueueJournalPhase,
        stableTranscriptExists: Bool
    ) -> ImportedTranscriptionQueueJournalRecoveryAction {
        if phase == .scratchCleanupPending {
            return .cleanScratch
        }
        if phase == .transcriptCommitted || stableTranscriptExists {
            return .handOffScratch
        }
        return .replayTranscription
    }

    private static func journalURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(filenamePrefix)\(id.uuidString).\(filenameExtension)",
            isDirectory: false
        )
    }

    fileprivate static func lockURL(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent(
            "\(filenamePrefix)\(id.uuidString).\(lockFilenameExtension)",
            isDirectory: false
        )
    }

    fileprivate static func load(
        id: UUID,
        journalDirectory: URL,
        fileManager: FileManager
    ) -> ImportedTranscriptionQueueJournalRecord? {
        let url = journalURL(for: id, in: journalDirectory)
        guard let record = readRecord(from: url),
              record.id == id,
              !record.audioFilename.isEmpty,
              URL(fileURLWithPath: record.audioFilename).lastPathComponent == record.audioFilename
        else { return nil }
        return record
    }

    fileprivate static func write(
        _ record: ImportedTranscriptionQueueJournalRecord,
        journalDirectory: URL,
        fileManager: FileManager
    ) throws {
        let data = try JSONEncoder().encode(record)
        let destination = journalURL(for: record.id, in: journalDirectory)
        let temporary = journalDirectory.appendingPathComponent(
            ".\(filenamePrefix)\(record.id.uuidString)-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            temporary.path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else { throw posixError() }

        do {
            try data.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                var offset = 0
                while offset < bytes.count {
                    let written = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        bytes.count - offset
                    )
                    guard written > 0 else { throw posixError() }
                    offset += written
                }
            }
            guard fsync(descriptor) == 0 else { throw posixError() }
            guard rename(temporary.path, destination.path) == 0 else { throw posixError() }
            synchronizeDirectory(journalDirectory)
            Darwin.close(descriptor)
        } catch {
            Darwin.close(descriptor)
            unlink(temporary.path)
            throw error
        }
        fileManager.restrictFileToOwnerOnly(at: destination)
    }

    private static func readRecord(from url: URL) -> ImportedTranscriptionQueueJournalRecord? {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { Darwin.close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG,
              status.st_size >= 0,
              status.st_size <= maximumRecordBytes else {
            return nil
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let data = try? handle.read(upToCount: maximumRecordBytes + 1),
              data.count <= maximumRecordBytes else {
            return nil
        }
        return try? JSONDecoder().decode(
            ImportedTranscriptionQueueJournalRecord.self,
            from: data
        )
    }

    private static func synchronizeDirectory(_ directory: URL) {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        Darwin.close(descriptor)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

final class ImportedTranscriptionQueueJournalSession: ImportedTranscriptionRecoverySession, @unchecked Sendable {
    let jobID: UUID

    private let journalDirectory: URL
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private var record: ImportedTranscriptionQueueJournalRecord
    private var lockDescriptor: Int32

    fileprivate init(
        record: ImportedTranscriptionQueueJournalRecord,
        journalDirectory: URL,
        lockDescriptor: Int32,
        fileManager: FileManager
    ) {
        jobID = record.id
        self.record = record
        self.journalDirectory = journalDirectory
        self.lockDescriptor = lockDescriptor
        self.fileManager = fileManager
    }

    deinit {
        releaseLock()
    }

    func transcriptCommitConfirmed() {
        stateLock.withLock {
            guard lockDescriptor >= 0 else { return }
            guard record.phase != .scratchCleanupPending else { return }
            var updatedRecord = record
            updatedRecord.phase = .transcriptCommitted
            do {
                try ImportedTranscriptionQueueJournal.write(
                    updatedRecord,
                    journalDirectory: journalDirectory,
                    fileManager: fileManager
                )
                record = updatedRecord
            } catch {
                return
            }
        }
    }

    func prepareForScratchCleanup() -> Bool {
        stateLock.withLock {
            guard lockDescriptor >= 0 else { return false }
            guard record.phase != .scratchCleanupPending else { return true }
            var updatedRecord = record
            updatedRecord.phase = .scratchCleanupPending
            do {
                try ImportedTranscriptionQueueJournal.write(
                    updatedRecord,
                    journalDirectory: journalDirectory,
                    fileManager: fileManager
                )
                record = updatedRecord
                return true
            } catch {
                return false
            }
        }
    }

    func scratchCleanupConfirmed() {
        finish()
    }

    func failedQueueHandoffConfirmed() {
        finish()
    }

    func supersededRecoveryConfirmed() {
        finish()
    }

    var phase: ImportedTranscriptionQueueJournalPhase {
        stateLock.withLock { record.phase }
    }

    private func finish() {
        stateLock.withLock {
            guard lockDescriptor >= 0 else { return }
            let didRemoveJournal = ImportedTranscriptionQueueJournal.remove(
                id: jobID,
                journalDirectory: journalDirectory,
                fileManager: fileManager
            )
            if didRemoveJournal {
                unlink(ImportedTranscriptionQueueJournal.lockURL(for: jobID, in: journalDirectory).path)
            }
            releaseLockWhileStateLocked()
        }
    }

    private func releaseLock() {
        stateLock.withLock {
            releaseLockWhileStateLocked()
        }
    }

    private func releaseLockWhileStateLocked() {
        guard lockDescriptor >= 0 else { return }
        flock(lockDescriptor, LOCK_UN)
        Darwin.close(lockDescriptor)
        lockDescriptor = -1
    }
}

enum MeetingImportedAudioPreparationError: LocalizedError, Equatable {
    case fileMissing
    case cannotInspect
    case notRegularFile
    case unsupportedAudioType
    case unreadable
    case copyFailed

    var diagnosticKind: String {
        switch self {
        case .fileMissing:
            return MeetingFailureKind.importFileMissing.rawValue
        case .cannotInspect,
             .unreadable:
            return MeetingFailureKind.importFileUnreadable.rawValue
        case .notRegularFile,
             .unsupportedAudioType:
            return MeetingFailureKind.importUnsupportedFile.rawValue
        case .copyFailed:
            return MeetingFailureKind.importCopyFailed.rawValue
        }
    }

    var errorDescription: String? {
        switch self {
        case .fileMissing:
            return "The selected audio file could not be found. It may have been moved or deleted."
        case .cannotInspect:
            return "Transcripted couldn't inspect that audio file. Check Finder permissions and try again."
        case .notRegularFile:
            return "Choose an audio or video recording file, not a folder or app package."
        case .unsupportedAudioType:
            return "That file does not include a readable audio track. Choose a WAV, MP3, M4A, AAC, AIFF, MP4, or MOV file."
        case .unreadable:
            return "Transcripted couldn't read that audio file. Try moving it to a folder you can access."
        case .copyFailed:
            return "Transcripted couldn't copy or extract that recording into its working area. Check disk space and try again."
        }
    }
}

enum ImportedMeetingMediaKind: Equatable {
    case audio
    case audiovisual
}

enum MeetingImportedAudioPreparer {
    /// A source timestamp within this window of the import is treated as the copy
    /// or download act rather than the original recording time (issue #850).
    static let copyDetectionWindow: TimeInterval = 120

    /// Embedded dates before this are treated as malformed/sentinel values — e.g.
    /// the 1904 QuickTime epoch or the 1970 Unix epoch written by buggy encoders —
    /// rather than real recording times (issue #850). 1990-01-01 UTC predates any
    /// consumer digital recorder that embeds creation metadata.
    static let earliestPlausibleRecordingDate = Date(timeIntervalSince1970: 631_152_000)

    static func prepareImportedAudio(
        from sourceURL: URL,
        scratchDirectory: URL = MeetingStoragePaths.recordingsScratch
    ) async throws -> PreparedImportedMeetingAudio {
        // Bail before doing any work if the import was already cancelled, so an
        // explicit cancel never even starts copying.
        try Task.checkCancellation()

        let fileManager = FileManager.default
        fileManager.ensurePrivateDirectory(
            at: scratchDirectory,
            context: "meeting imported audio scratch"
        )

        let resolvedSourceURL = sourceURL.standardizedFileURL
        guard fileManager.fileExists(atPath: resolvedSourceURL.path) else {
            throw MeetingImportedAudioPreparationError.fileMissing
        }

        let didStartSecurityScope = resolvedSourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartSecurityScope {
                resolvedSourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let sourceAttributes: [FileAttributeKey: Any]
        do {
            sourceAttributes = try fileManager.attributesOfItem(atPath: resolvedSourceURL.path)
        } catch {
            throw MeetingImportedAudioPreparationError.cannotInspect
        }

        guard sourceAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw MeetingImportedAudioPreparationError.notRegularFile
        }

        let resourceValues: URLResourceValues
        do {
            resourceValues = try resolvedSourceURL.resourceValues(forKeys: [
                .contentTypeKey,
                .isReadableKey
            ])
        } catch {
            throw MeetingImportedAudioPreparationError.cannotInspect
        }

        if resourceValues.isReadable == false {
            throw MeetingImportedAudioPreparationError.unreadable
        }

        let mediaKind = try importMediaKind(for: resourceValues.contentType)

        let destinationURL = uniqueScratchURL(
            for: resolvedSourceURL,
            in: scratchDirectory,
            fileManager: fileManager,
            preferredExtension: mediaKind == .audiovisual ? "m4a" : nil
        )

        do {
            switch mediaKind {
            case .audio:
                try copyInterruptibly(
                    from: resolvedSourceURL,
                    to: destinationURL,
                    fileManager: fileManager
                )
            case .audiovisual:
                try await extractAudioTrack(
                    from: resolvedSourceURL,
                    to: destinationURL
                )
            }
            fileManager.restrictFileToOwnerOnly(at: destinationURL)
        } catch is CancellationError {
            try? fileManager.removeItem(at: destinationURL)
            throw CancellationError()
        } catch let error as MeetingImportedAudioPreparationError {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw MeetingImportedAudioPreparationError.copyFailed
        }

        return PreparedImportedMeetingAudio(
            copiedAudioURL: destinationURL,
            suggestedTitle: suggestedTitle(from: resolvedSourceURL),
            recordingDate: await recordingDate(
                from: resolvedSourceURL,
                sourceAttributes: sourceAttributes
            )
        )
    }

    static func importMediaKind(for contentType: UTType?) throws -> ImportedMeetingMediaKind {
        guard let contentType else { return .audio }
        if contentType.conforms(to: .audio) {
            return .audio
        }
        if contentType.conforms(to: .audiovisualContent) || contentType.conforms(to: .movie) {
            return .audiovisual
        }
        throw MeetingImportedAudioPreparationError.unsupportedAudioType
    }

    static func extractAudioTrack(
        from sourceURL: URL,
        to destinationURL: URL
    ) async throws {
        try Task.checkCancellation()

        let asset = AVURLAsset(url: sourceURL)
        let audioTracks: [AVAssetTrack]
        do {
            audioTracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw MeetingImportedAudioPreparationError.unsupportedAudioType
        }

        guard !audioTracks.isEmpty else {
            throw MeetingImportedAudioPreparationError.unsupportedAudioType
        }
        guard let exportSession = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw MeetingImportedAudioPreparationError.unsupportedAudioType
        }

        exportSession.shouldOptimizeForNetworkUse = false

        try await exportSession.export(to: destinationURL, as: .m4a)
        try Task.checkCancellation()
    }

    private static func recordingDate(
        from sourceURL: URL,
        sourceAttributes: [FileAttributeKey: Any],
        now: Date = Date()
    ) async -> Date {
        // Prefer a date the recorder embedded in the file: it describes when the
        // audio was actually captured, which is what an imported note should show.
        // Ignore implausible dates (future, or sentinel/zero values) so a bogus tag
        // never becomes the note date — fall through to the file system instead.
        if let embeddedDate = await embeddedRecordingDate(from: sourceURL),
           isPlausibleEmbeddedDate(embeddedDate, now: now) {
            return embeddedDate
        }

        // Otherwise fall back to the source file's own timestamps, but only when
        // they look like the original recording rather than a copy or download.
        if let filesystemDate = reliableFilesystemDate(
            from: sourceURL,
            sourceAttributes: sourceAttributes,
            now: now
        ) {
            return filesystemDate
        }

        // Last resort (issue #850): creation date unavailable or unreliable, so
        // use the import time.
        return now
    }

    /// Whether an embedded recording date looks like a real capture time. Rejects
    /// sentinel/zero dates written by buggy encoders and anything in the future, so
    /// the resolver falls through to the file system rather than stamping the note
    /// with a bogus date (issue #850).
    static func isPlausibleEmbeddedDate(_ date: Date, now: Date) -> Bool {
        date >= earliestPlausibleRecordingDate
            && date.timeIntervalSince(now) <= copyDetectionWindow
    }

    /// Best file-system estimate of when the source audio was recorded. Copies,
    /// downloads, and AirDrops only ever push a file's timestamps forward, so the
    /// earliest timestamp is the closest lower bound on the original recording.
    /// Any timestamp inside the import window is the copy act itself and is
    /// discarded as unreliable (issue #850).
    static func reliableFilesystemDate(
        from sourceURL: URL,
        sourceAttributes: [FileAttributeKey: Any],
        now: Date
    ) -> Date? {
        var candidates: [Date] = []
        if let creationDate = sourceAttributes[.creationDate] as? Date {
            candidates.append(creationDate)
        } else if let resourceDate = try? sourceURL
            .resourceValues(forKeys: [.creationDateKey]).creationDate {
            candidates.append(resourceDate)
        }
        if let modificationDate = sourceAttributes[.modificationDate] as? Date {
            candidates.append(modificationDate)
        }

        return candidates
            .filter { now.timeIntervalSince($0) >= copyDetectionWindow }
            .min()
    }

    private static func embeddedRecordingDate(from sourceURL: URL) async -> Date? {
        let asset = AVURLAsset(url: sourceURL)
        return await embeddedRecordingDate(from: asset)
    }

    static func embeddedRecordingDate(from asset: AVURLAsset) async -> Date? {
        if let creationDate = try? await asset.load(.creationDate),
           let date = await metadataDate(creationDate) {
            return date
        }

        let metadata = (try? await asset.load(.metadata)) ?? []
        var best: (priority: Int, date: Date)?
        for item in metadata {
            let keyString = metadataKeyString(for: item)
            guard isRecordingDateMetadata(keyString: keyString),
                  let date = await metadataDate(item) else { continue }
            let priority = recordingDatePriority(forKeyString: keyString)
            // Prefer the most explicit creation/recording tag. Earlier code took
            // the globally earliest matched date, which let a stray tag win.
            if let current = best {
                if priority < current.priority
                    || (priority == current.priority && date < current.date) {
                    best = (priority, date)
                }
            } else {
                best = (priority, date)
            }
        }
        return best?.date
    }

    /// Lowercased identifier/key text used to classify a metadata item.
    static func metadataKeyString(for item: AVMetadataItem) -> String {
        [
            item.identifier?.rawValue,
            item.commonKey?.rawValue,
            item.keySpace?.rawValue,
            item.key.map { String(describing: $0) }
        ]
        .compactMap { $0 }
        .joined(separator: " ")
        .lowercased()
    }

    static func isRecordingDateMetadata(_ item: AVMetadataItem) -> Bool {
        isRecordingDateMetadata(keyString: metadataKeyString(for: item))
    }

    /// True only for metadata that records when the audio was captured. Dates that
    /// describe something else — store purchase, encode/tagging time, release or
    /// album date — are rejected so they can never become the note date (#850).
    static func isRecordingDateMetadata(keyString: String) -> Bool {
        let nonRecordingMarkers = [
            "purchase",   // iTunes purchaseDate
            "encod",      // encodedBy / encodingTime / TENC / TSSE
            "tagging",    // TDTG tagging time
            "release",    // TDRL / TDOR / originalReleaseTime / albumReleaseDate
            "publish",
            "album",
            "modif"       // modification date
        ]
        if nonRecordingMarkers.contains(where: keyString.contains) {
            return false
        }

        let recordingMarkers = [
            "creationdate",
            "creation",
            "created",
            "recordingdate",
            "recordingtime",
            "recorded",
            "tdrc"        // ID3v2.4 recording time
        ]
        return recordingMarkers.contains(where: keyString.contains)
    }

    /// Ranks recording-date metadata so an explicit creation tag wins over a looser
    /// recording tag, and both win over anything generic. Lower is better.
    static func recordingDatePriority(forKeyString keyString: String) -> Int {
        if keyString.contains("creation") || keyString.contains("created") {
            return 0
        }
        if keyString.contains("recording") || keyString.contains("recorded")
            || keyString.contains("tdrc") {
            return 1
        }
        return 2
    }

    static func metadataDate(
        _ item: AVMetadataItem,
        defaultTimeZone: TimeZone = .current
    ) async -> Date? {
        if let string = try? await item.load(.stringValue),
           let date = parseMetadataDate(string, defaultTimeZone: defaultTimeZone) {
            return date
        }

        if let value = try? await item.load(.value) {
            if let date = value as? Date {
                return date
            }
            if let string = value as? String,
               let date = parseMetadataDate(string, defaultTimeZone: defaultTimeZone) {
                return date
            }
            if let string = value as? NSString,
               let date = parseMetadataDate(String(string), defaultTimeZone: defaultTimeZone) {
                return date
            }
        }

        if let date = try? await item.load(.dateValue) {
            return date
        }

        return nil
    }

    static func parseMetadataDate(
        _ value: String,
        defaultTimeZone: TimeZone = .current
    ) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let isoFormatter = ISO8601DateFormatter()
        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        isoFormatter.formatOptions = [.withInternetDateTime]
        if let date = isoFormatter.date(from: trimmed) {
            return date
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in [
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ssZ",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        formatter.timeZone = defaultTimeZone
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd"
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    /// Streams the source file into scratch in chunks so an explicit cancel can
    /// interrupt a large import between chunks instead of blocking inside one
    /// atomic `copyItem` call. Any partial destination is removed before this
    /// throws — on cancellation or on a copy error — so a cancelled or failed
    /// import never leaves an ambiguous half-written file behind.
    static func copyInterruptibly(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager,
        chunkSize: Int = 1 << 20
    ) throws {
        let readHandle = try FileHandle(forReadingFrom: sourceURL)
        defer { try? readHandle.close() }

        guard fileManager.createFile(
            atPath: destinationURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw MeetingImportedAudioPreparationError.copyFailed
        }

        let writeHandle: FileHandle
        do {
            writeHandle = try FileHandle(forWritingTo: destinationURL)
        } catch {
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }

        do {
            while true {
                try Task.checkCancellation()
                let chunk = try readHandle.read(upToCount: chunkSize) ?? Data()
                if chunk.isEmpty { break }
                try writeHandle.write(contentsOf: chunk)
            }
            try writeHandle.close()
        } catch {
            try? writeHandle.close()
            try? fileManager.removeItem(at: destinationURL)
            throw error
        }
    }

    private static func uniqueScratchURL(
        for sourceURL: URL,
        in directory: URL,
        fileManager: FileManager,
        preferredExtension: String? = nil
    ) -> URL {
        let originalExtension = sourceURL.pathExtension
        let safeExtension = preferredExtension ?? (originalExtension.isEmpty ? "m4a" : originalExtension)
        let stem = "imported-\(UUID().uuidString)"
        var candidate = directory
            .appendingPathComponent(stem, isDirectory: false)
            .appendingPathExtension(safeExtension)
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(stem)-\(suffix)", isDirectory: false)
                .appendingPathExtension(safeExtension)
            suffix += 1
        }

        return candidate
    }

    private static func suggestedTitle(from sourceURL: URL) -> String {
        let raw = sourceURL
            .deletingPathExtension()
            .lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return raw.isEmpty ? "Imported audio" : raw
    }
}
