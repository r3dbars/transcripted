import Darwin
import Foundation
import SQLite3

/// Makes a consistent, private copy for speaker matching without opening the
/// app's database through its writable, self-repairing `SpeakerDatabase` wrapper.
/// SQLite's backup API includes committed WAL rows; copying just the .sqlite
/// file can silently omit the newest speaker names and embeddings.
enum SpeakerDatabaseSnapshot {
    enum SnapshotError: LocalizedError, Equatable {
        case invalidSource
        case sourceUnavailable(Int32)
        case destinationExists
        case destinationUnavailable(Int32)
        case databaseFailure(operation: String, code: Int32)
        case invalidDatabase
        case busy

        var errorDescription: String? {
            switch self {
            case .invalidSource:
                return "The speaker database must be a nonempty regular file, not a directory or symbolic link."
            case .sourceUnavailable(let code):
                return "Cannot read the speaker database (system error \(code)). Check the path and read access, or disable speaker identification."
            case .destinationExists:
                return "The private speaker snapshot already exists; refusing to overwrite it."
            case .destinationUnavailable(let code):
                return "Cannot create the private speaker snapshot (system error \(code)). Check temporary-folder access and free space."
            case .databaseFailure(let operation, let code):
                return "Cannot \(operation) the speaker database (SQLite error \(code)). Retry or disable speaker identification; the original database has not been repaired or changed."
            case .invalidDatabase:
                return "The speaker database failed its integrity check. Disable speaker identification or repair the database in Transcripted; the CLI has not changed it."
            case .busy:
                return "The speaker database stayed busy for too long. Retry when Transcripted finishes updating speakers, or disable speaker identification."
            }
        }
    }

    /// `destinationURL` must be a new path in the caller's private job directory.
    /// No parent folders are created and no existing destination is replaced.
    /// The source is opened read-only, with an explicit read transaction; only
    /// SQLite's normal shared-memory reader coordination can touch its sidecars.
    static func create(
        sourceURL: URL,
        destinationURL: URL,
        busyTimeout: TimeInterval = 5
    ) throws {
        guard sourceURL.isFileURL, !sourceURL.path.utf8.contains(0) else {
            throw SnapshotError.invalidSource
        }
        var sourceInfo = stat()
        guard lstat(sourceURL.path, &sourceInfo) == 0 else {
            throw SnapshotError.sourceUnavailable(errno)
        }
        guard sourceInfo.st_mode & S_IFMT == S_IFREG, sourceInfo.st_size > 0 else {
            throw SnapshotError.invalidSource
        }
        guard destinationURL.isFileURL, !destinationURL.path.utf8.contains(0) else {
            throw SnapshotError.destinationUnavailable(EINVAL)
        }

        // O_EXCL also rejects an existing symlink. Keep the descriptor alive so
        // cleanup can check ownership before removing an incomplete snapshot.
        let destinationFD = open(destinationURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard destinationFD >= 0 else {
            if errno == EEXIST { throw SnapshotError.destinationExists }
            throw SnapshotError.destinationUnavailable(errno)
        }
        var destinationInfo = stat()
        guard fstat(destinationFD, &destinationInfo) == 0 else {
            let code = errno
            close(destinationFD)
            throw SnapshotError.destinationUnavailable(code)
        }
        var completed = false
        defer {
            close(destinationFD)
            if !completed {
                var currentInfo = stat()
                if lstat(destinationURL.path, &currentInfo) == 0,
                   currentInfo.st_dev == destinationInfo.st_dev,
                   currentInfo.st_ino == destinationInfo.st_ino {
                    // SQLite closes its own journal files before this defer.
                    // Do not glob sidecars or remove a caller-owned directory.
                    unlink(destinationURL.path)
                }
            }
        }

        let deadline = BusyDeadline(timeout: busyTimeout)
        // SQLite retains the callback context as an unowned pointer. Keep its
        // Swift object alive until both database handles have been closed.
        defer { withExtendedLifetime(deadline) {} }
        var source: OpaquePointer?
        let sourceCode = sqlite3_open_v2(sourceURL.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let source { sqlite3_close(source) } }
        guard sourceCode == SQLITE_OK, let source else {
            throw databaseError("open", code: sourceCode)
        }
        configureBusyHandler(source, deadline: deadline)
        try execute("PRAGMA query_only=ON", database: source, operation: "protect")
        try execute("BEGIN", database: source, operation: "read")
        defer { sqlite3_exec(source, "ROLLBACK", nil, nil, nil) }
        // BEGIN is deferred until the first read. Pin a single snapshot before
        // starting the backup, even while the app commits newer WAL changes.
        try execute("SELECT count(*) FROM sqlite_schema", database: source, operation: "read")

        var destination: OpaquePointer?
        let destinationCode = sqlite3_open_v2(destinationURL.path, &destination, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        defer { if let destination { sqlite3_close(destination) } }
        guard destinationCode == SQLITE_OK, let destination else {
            throw databaseError("open the private copy of", code: destinationCode)
        }
        configureBusyHandler(destination, deadline: deadline)
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw databaseError("snapshot", code: sqlite3_errcode(destination))
        }
        var backupFinished = false
        defer { if !backupFinished { sqlite3_backup_finish(backup) } }
        while true {
            let code = sqlite3_backup_step(backup, 128)
            if code == SQLITE_DONE { break }
            if code == SQLITE_BUSY || code == SQLITE_LOCKED {
                guard deadline.waitIfAvailable() else { throw SnapshotError.busy }
            } else if code != SQLITE_OK {
                throw databaseError("snapshot", code: code)
            }
        }
        let finishCode = sqlite3_backup_finish(backup)
        backupFinished = true
        guard finishCode == SQLITE_OK else { throw databaseError("finish the snapshot of", code: finishCode) }

        // Keep the successful snapshot self-contained before returning it to
        // the caller, who can then open and mutate only this private copy.
        try execute("PRAGMA journal_mode=DELETE", database: destination, operation: "finalize the snapshot of")
        try validateIntegrity(destination)
        guard fchmod(destinationFD, 0o600) == 0 else {
            throw SnapshotError.destinationUnavailable(errno)
        }
        completed = true
    }

    private static func execute(_ sql: String, database: OpaquePointer, operation: String) throws {
        let code = sqlite3_exec(database, sql, nil, nil, nil)
        guard code == SQLITE_OK else { throw databaseError(operation, code: code) }
    }

    private static func validateIntegrity(_ database: OpaquePointer) throws {
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(database, "PRAGMA quick_check", -1, &statement, nil)
        defer { sqlite3_finalize(statement) }
        guard prepareCode == SQLITE_OK, let statement else {
            throw databaseError("check the snapshot of", code: prepareCode)
        }
        let firstCode = sqlite3_step(statement)
        guard firstCode == SQLITE_ROW,
              let result = sqlite3_column_text(statement, 0),
              String(cString: result) == "ok" else {
            if firstCode == SQLITE_BUSY || firstCode == SQLITE_LOCKED { throw SnapshotError.busy }
            throw SnapshotError.invalidDatabase
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SnapshotError.invalidDatabase }
    }

    private static func databaseError(_ operation: String, code: Int32) -> SnapshotError {
        if code == SQLITE_BUSY || code == SQLITE_LOCKED { return .busy }
        if code == SQLITE_CORRUPT || code == SQLITE_NOTADB { return .invalidDatabase }
        return .databaseFailure(operation: operation, code: code)
    }

    private static func configureBusyHandler(_ database: OpaquePointer, deadline: BusyDeadline) {
        sqlite3_busy_handler(database, { context, _ in
            guard let context else { return 0 }
            let deadline = Unmanaged<BusyDeadline>.fromOpaque(context).takeUnretainedValue()
            return deadline.waitIfAvailable() ? 1 : 0
        }, Unmanaged.passUnretained(deadline).toOpaque())
    }

    private final class BusyDeadline {
        private let end: TimeInterval

        init(timeout: TimeInterval) {
            end = ProcessInfo.processInfo.systemUptime + min(max(timeout.isFinite ? timeout : 5, 0), 5)
        }

        func waitIfAvailable() -> Bool {
            let remaining = end - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return false }
            Thread.sleep(forTimeInterval: min(remaining, 0.01))
            return ProcessInfo.processInfo.systemUptime < end
        }
    }
}
