import Foundation
import CryptoKit
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

extension Notification.Name {
    static let meetingArtifactRecoveryJournalUnavailable = Notification.Name(
        "Transcripted.meetingArtifactRecoveryJournalUnavailable"
    )
}

enum MeetingArtifactRecoveryStoreError: Error {
    case pending(MeetingArtifactRecoveryNotice)
    case invalidRecord
}

struct MeetingArtifactRecoveryTransaction {
    fileprivate let record: MeetingArtifactRecoveryStore.Record
    let notice: MeetingArtifactRecoveryNotice
}

enum MeetingArtifactRecoveryAlert: Equatable {
    case artifacts([MeetingArtifactRecoveryNotice])
    case journalUnavailable(URL)
}

/// Durable transaction journal for transcript/audio renames. A record is written
/// before either artifact moves and is removed only after the pair is coherent.
/// Unresolved records block later rename/restyle attempts across app launches.
enum MeetingArtifactRecoveryStore {
    fileprivate struct Record: Codable, Equatable {
        let version: Int
        let transactionID: UUID
        let captureID: UUID?
        let transcriptDigest: String
        let sourceTranscriptPath: String
        let targetTranscriptPath: String
        let hadSourceAudio: Bool

        var notice: MeetingArtifactRecoveryNotice {
            MeetingArtifactRecoveryNotice(
                sourceTranscriptURL: URL(fileURLWithPath: sourceTranscriptPath),
                targetTranscriptURL: URL(fileURLWithPath: targetTranscriptPath)
            )
        }
    }

    private static let currentVersion = 1
    private static let directoryName = "meeting_artifact_recovery"
    private static let lock = NSLock()

    static var defaultDirectory: URL {
        MeetingStoragePaths.stateFolder.appendingPathComponent(directoryName, isDirectory: true)
    }

    static func notifyUnavailable(directory: URL? = nil) {
        NotificationCenter.default.post(
            name: .meetingArtifactRecoveryJournalUnavailable,
            object: (directory ?? defaultDirectory).standardizedFileURL
        )
    }

    static func prepare(
        sourceTranscriptURL: URL,
        targetTranscriptURL: URL,
        hadSourceAudio: Bool,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> MeetingArtifactRecoveryTransaction {
        lock.lock()
        defer { lock.unlock() }

        let directory = directory ?? defaultDirectory
        let captureID = captureID(
            sourceTranscriptURL: sourceTranscriptURL,
            targetTranscriptURL: targetTranscriptURL
        )
        let sourcePath = sourceTranscriptURL.standardizedFileURL.path
        let targetPath = targetTranscriptURL.standardizedFileURL.path
        let transcriptDigest = try digest(of: sourceTranscriptURL)

        fileManager.ensurePrivateDirectory(at: directory, context: "meeting artifact recovery")
        for (recordURL, existing) in try records(in: directory, fileManager: fileManager) where matches(
            existing,
            captureID: captureID,
            transcriptPaths: [sourcePath, targetPath]
        ) {
            if isResolved(existing, fileManager: fileManager) {
                try? fileManager.removeItem(at: recordURL)
            } else {
                throw MeetingArtifactRecoveryStoreError.pending(existing.notice)
            }
        }

        let record = Record(
            version: currentVersion,
            transactionID: UUID(),
            captureID: captureID,
            transcriptDigest: transcriptDigest,
            sourceTranscriptPath: sourcePath,
            targetTranscriptPath: targetPath,
            hadSourceAudio: hadSourceAudio
        )
        let recordURL = recordURL(transactionID: record.transactionID, directory: directory)
        try writeRecord(record, to: recordURL, fileManager: fileManager)
        return MeetingArtifactRecoveryTransaction(record: record, notice: record.notice)
    }

    static func finish(
        _ transaction: MeetingArtifactRecoveryTransaction,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) {
        lock.lock()
        defer { lock.unlock() }

        let directory = directory ?? defaultDirectory
        let url = recordURL(transactionID: transaction.record.transactionID, directory: directory)
        guard let current = try? readRecord(at: url), current == transaction.record else { return }
        try? fileManager.removeItem(at: url)
    }

    static func pendingNotice(
        for transcriptURL: URL,
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> MeetingArtifactRecoveryNotice? {
        lock.lock()
        defer { lock.unlock() }

        let captureID = captureID(
            sourceTranscriptURL: transcriptURL,
            targetTranscriptURL: transcriptURL
        )
        let transcriptPath = transcriptURL.standardizedFileURL.path
        let directory = directory ?? defaultDirectory
        for (url, storedRecord) in try records(in: directory, fileManager: fileManager) where matches(
            storedRecord,
            captureID: captureID,
            transcriptPaths: [transcriptPath]
        ) {
            let record = try rebaseIfNeeded(
                storedRecord,
                around: transcriptURL,
                recordURL: url,
                fileManager: fileManager
            )
            if isResolved(record, fileManager: fileManager) {
                try? fileManager.removeItem(at: url)
                continue
            }
            return record.notice
        }
        return nil
    }

    static func pendingNotices(
        directory: URL? = nil,
        fileManager: FileManager = .default
    ) throws -> [MeetingArtifactRecoveryNotice] {
        lock.lock()
        defer { lock.unlock() }

        let shouldRebaseToActiveLibrary = directory == nil
        let directory = directory ?? defaultDirectory
        var notices: [MeetingArtifactRecoveryNotice] = []
        for (url, storedRecord) in try records(in: directory, fileManager: fileManager) {
            let record = shouldRebaseToActiveLibrary
                ? try rebaseToActiveLibraryIfNeeded(
                    storedRecord,
                    recordURL: url,
                    fileManager: fileManager
                )
                : storedRecord
            if isResolved(record, fileManager: fileManager) {
                try? fileManager.removeItem(at: url)
            } else {
                notices.append(record.notice)
            }
        }
        return notices.sorted {
            $0.sourceTranscriptURL.path < $1.sourceTranscriptURL.path
        }
    }

    static func transcriptBelongsToTransaction(
        at url: URL,
        transaction: MeetingArtifactRecoveryTransaction,
        fileManager: FileManager = .default
    ) -> Bool {
        transcriptMatchesPreparedContent(
            at: url,
            record: transaction.record,
            fileManager: fileManager
        )
    }

    private static func captureID(
        sourceTranscriptURL: URL,
        targetTranscriptURL: URL
    ) -> UUID? {
        for url in [sourceTranscriptURL, targetTranscriptURL] {
            guard let values = try? TranscriptFrontmatter.readValues(from: url),
                  let captureID = TranscriptFrontmatter.captureID(in: values) else { continue }
            return captureID
        }
        return nil
    }

    private static func recordURL(transactionID: UUID, directory: URL) -> URL {
        directory.appendingPathComponent("\(transactionID.uuidString).json", isDirectory: false)
    }

    private static func records(
        in directory: URL,
        fileManager: FileManager
    ) throws -> [(URL, Record)] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let urls = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return try urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url in
                (url, try readRecord(at: url))
            }
    }

    private static func matches(
        _ record: Record,
        captureID: UUID?,
        transcriptPaths: Set<String>
    ) -> Bool {
        if let captureID, record.captureID == captureID {
            return true
        }
        return transcriptPaths.contains(record.sourceTranscriptPath)
            || transcriptPaths.contains(record.targetTranscriptPath)
    }

    private static func rebaseIfNeeded(
        _ record: Record,
        around transcriptURL: URL,
        recordURL: URL,
        fileManager: FileManager
    ) throws -> Record {
        let currentDirectory = transcriptURL.deletingLastPathComponent().standardizedFileURL
        let recordedDirectory = record.notice.sourceTranscriptURL
            .deletingLastPathComponent()
            .standardizedFileURL
        guard currentDirectory != recordedDirectory,
              transcriptBelongs(at: transcriptURL, to: record, fileManager: fileManager) else {
            return record
        }

        let rebased = Record(
            version: record.version,
            transactionID: record.transactionID,
            captureID: record.captureID,
            transcriptDigest: record.transcriptDigest,
            sourceTranscriptPath: currentDirectory
                .appendingPathComponent(record.notice.sourceTranscriptURL.lastPathComponent)
                .path,
            targetTranscriptPath: currentDirectory
                .appendingPathComponent(record.notice.targetTranscriptURL.lastPathComponent)
                .path,
            hadSourceAudio: record.hadSourceAudio
        )
        try writeRecord(rebased, to: recordURL, fileManager: fileManager)
        return rebased
    }

    private static func rebaseToActiveLibraryIfNeeded(
        _ record: Record,
        recordURL: URL,
        fileManager: FileManager
    ) throws -> Record {
        let activeDirectory = MeetingStoragePaths.transcriptsFolder.standardizedFileURL
        let candidateURLs = [
            activeDirectory.appendingPathComponent(record.notice.sourceTranscriptURL.lastPathComponent),
            activeDirectory.appendingPathComponent(record.notice.targetTranscriptURL.lastPathComponent),
        ]
        guard let matchingURL = candidateURLs.first(where: {
            transcriptBelongs(at: $0, to: record, fileManager: fileManager)
        }) else { return record }
        return try rebaseIfNeeded(
            record,
            around: matchingURL,
            recordURL: recordURL,
            fileManager: fileManager
        )
    }

    private static func readRecord(at url: URL) throws -> Record {
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        guard record.version == currentVersion else {
            throw MeetingArtifactRecoveryStoreError.invalidRecord
        }
        return record
    }

    private static func digest(of url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func transcriptBelongs(
        at url: URL,
        to record: Record,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path) else { return false }
        if let expectedCaptureID = record.captureID {
            guard let values = try? TranscriptFrontmatter.readValues(from: url),
                  let actualCaptureID = TranscriptFrontmatter.captureID(in: values) else { return false }
            return actualCaptureID == expectedCaptureID
        }
        return (try? digest(of: url)) == record.transcriptDigest
    }

    private static func transcriptMatchesPreparedContent(
        at url: URL,
        record: Record,
        fileManager: FileManager
    ) -> Bool {
        guard fileManager.fileExists(atPath: url.path),
              (try? digest(of: url)) == record.transcriptDigest else { return false }
        guard let expectedCaptureID = record.captureID else { return true }
        guard let values = try? TranscriptFrontmatter.readValues(from: url),
              let actualCaptureID = TranscriptFrontmatter.captureID(in: values) else { return false }
        return actualCaptureID == expectedCaptureID
    }

    private static func writeRecord(
        _ record: Record,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(record).write(to: url, options: [.atomic])
        fileManager.restrictFileToOwnerOnly(at: url)

        // The journal must reach stable storage before either artifact moves.
        // Atomic replacement prevents torn JSON; synchronize establishes the
        // write-before-move ordering for process and machine failures.
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
    }

    private static func isResolved(_ record: Record, fileManager: FileManager) -> Bool {
        let notice = record.notice
        let sourceTranscriptExists = transcriptBelongs(
            at: notice.sourceTranscriptURL,
            to: record,
            fileManager: fileManager
        )
        let targetTranscriptExists = transcriptMatchesPreparedContent(
            at: notice.targetTranscriptURL,
            record: record,
            fileManager: fileManager
        )
        if !record.hadSourceAudio {
            return (sourceTranscriptExists && !targetTranscriptExists)
                || (!sourceTranscriptExists && targetTranscriptExists)
        }

        let sourceAudioExists = fileManager.fileExists(
            atPath: MeetingArtifactRenamer.audioDirectoryURL(for: notice.sourceTranscriptURL).path
        )
        let targetAudioExists = fileManager.fileExists(
            atPath: MeetingArtifactRenamer.audioDirectoryURL(for: notice.targetTranscriptURL).path
        )
        let sourcePairIsCoherent = sourceTranscriptExists
            && sourceAudioExists
            && !targetTranscriptExists
            && !targetAudioExists
        let targetPairIsCoherent = !sourceTranscriptExists
            && !sourceAudioExists
            && targetTranscriptExists
            && targetAudioExists
        return sourcePairIsCoherent || targetPairIsCoherent
    }
}
