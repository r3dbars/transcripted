import Foundation
import AVFoundation
import Darwin
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif
import UniformTypeIdentifiers

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
        languageRawValue: String = "auto",
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
            sttModelRawValue: sttModelRawValue,
            languageRawValue: languageRawValue
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
        languageRawValue: String = "auto",
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
            sttModelRawValue: sttModelRawValue,
            languageRawValue: languageRawValue
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

    /// Resolves recovery from the journal's `phase` alone. This is the primary,
    /// durable decision: `claim()` and the transcript-save completion path
    /// (`TranscriptionTaskManager.markTaskTranscriptCommitted` →
    /// `transcriptCommitConfirmed()`) both write `phase` as part of a single
    /// atomic (temp-file + rename) journal write, so once a journal reports
    /// `.transcriptCommitted` or `.scratchCleanupPending` that fact is
    /// authoritative on its own — no other signal needs reconciling.
    static func recoveryAction(
        phase: ImportedTranscriptionQueueJournalPhase
    ) -> ImportedTranscriptionQueueJournalRecoveryAction {
        switch phase {
        case .scratchCleanupPending:
            return .cleanScratch
        case .transcriptCommitted:
            return .handOffScratch
        case .queued, .active:
            return .replayTranscription
        }
    }

    /// Legacy/crash-window migration fallback — the one remaining place
    /// recovery still consults live filesystem state instead of the journal
    /// alone.
    ///
    /// `recoveryAction(phase:)` is authoritative whenever the journal already
    /// claims an outcome. This function only runs when it does not (`.queued`
    /// or `.active`, i.e. no commit marker yet), which happens for two
    /// distinct reasons:
    ///
    /// 1. A journal written by an app version that predates the
    ///    transcript-commit phase transition. `ImportedTranscriptionQueueJournalRecord`
    ///    decodes a missing `phase` key as `.queued`, so an old in-flight
    ///    journal always looks unstarted even when its transcript was already
    ///    saved before the app updated.
    /// 2. The crash window between the transcript Markdown file being durably
    ///    written and the `.transcriptCommitted` journal write that follows it
    ///    immediately after. Those are two different files on two different
    ///    fsync/rename operations, so no single atomic write can cover both —
    ///    a crash in that exact window is a real possibility on every launch,
    ///    not just a migration concern for old installs.
    ///
    /// In both cases the filesystem is searched once, at startup recovery, for
    /// a transcript stamped with the journal's job id
    /// (`TranscriptSaver.existingTranscriptURLs`). Finding one hands the
    /// scratch audio off (recorded work is not lost) and the caller durably
    /// upgrades the journal to `.transcriptCommitted` via
    /// `transcriptCommitConfirmed()`, so the *next* recovery pass for the same
    /// journal never needs this fallback again — the migration self-heals.
    static func legacyRecoveryAction(
        phase: ImportedTranscriptionQueueJournalPhase,
        stableTranscriptExists: Bool
    ) -> ImportedTranscriptionQueueJournalRecoveryAction {
        let journalOnlyAction = recoveryAction(phase: phase)
        guard journalOnlyAction == .replayTranscription else { return journalOnlyAction }
        return stableTranscriptExists ? .handOffScratch : .replayTranscription
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
