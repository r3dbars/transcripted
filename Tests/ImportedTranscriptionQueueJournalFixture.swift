import Foundation
import Darwin

/// Seeds an unleased queued record for recovery tests, not durable runtime publication.
enum ImportedTranscriptionQueueJournalFixture {
    static func seedUnleasedQueuedRecord(
        id: UUID,
        audioURL: URL,
        recordingDate: Date,
        enqueuedAt: Date = Date(),
        sttModelRawValue: String,
        languageRawValue: String = "auto",
        journalDirectory: URL,
        scratchDirectory: URL
    ) throws {
        let manager = FileManager.default
        let scratch = scratchDirectory.standardizedFileURL
        let root = scratch.deletingLastPathComponent()
        let prefix = "MeetingImportedAudioPreparerTests-"
        let leaf = root.lastPathComponent
        let suffix = String(leaf.dropFirst(prefix.count))
        guard leaf.hasPrefix(prefix),
              let uuid = UUID(uuidString: suffix), uuid.uuidString == suffix.uppercased(),
              root.deletingLastPathComponent().resolvingSymlinksInPath()
                == manager.temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath(),
              root == root.resolvingSymlinksInPath(),
              scratch == root.appendingPathComponent("scratch", isDirectory: true),
              journalDirectory.standardizedFileURL
                == root.appendingPathComponent("state/queue", isDirectory: true),
              audioURL.standardizedFileURL.deletingLastPathComponent() == scratch else {
            throw FixtureError.unowned
        }
        try requireOwnedDirectory(root)
        try requireOwnedDirectory(scratch)
        let audio = audioURL.standardizedFileURL
        let properties = try audio.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw FixtureError.unowned
        }

        let state = root.appendingPathComponent("state", isDirectory: true)
        for directory in [state, journalDirectory.standardizedFileURL] {
            if !manager.fileExists(atPath: directory.path) {
                try manager.createDirectory(
                    at: directory, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
            }
            try requireOwnedDirectory(directory)
        }
        let destination = journalDirectory.standardizedFileURL
            .appendingPathComponent("import-job-\(id.uuidString).json")
        var status = stat()
        guard lstat(destination.path, &status) != 0, errno == ENOENT else {
            throw FixtureError.destinationExists
        }
        let record = ImportedTranscriptionQueueJournalRecord(
            id: id, audioFilename: audio.lastPathComponent,
            recordingDate: recordingDate, enqueuedAt: enqueuedAt,
            sttModelRawValue: sttModelRawValue, languageRawValue: languageRawValue
        )
        try JSONEncoder().encode(record).write(to: destination, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }

    private static func requireOwnedDirectory(_ directory: URL) throws {
        var status = stat()
        guard lstat(directory.path, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid() else { throw FixtureError.unowned }
    }

    private enum FixtureError: Error {
        case unowned
        case destinationExists
    }
}
