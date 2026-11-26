// SQLiteHandle.swift
// Shared SQLite bootstrap: open, owner-only permission hardening, and pragma
// configuration. Consolidates boilerplate that was duplicated (with drift) across
// SpeakerDatabase, StatsDatabase, and RecentMeetingMetadataCache.
// Schema, queries, and locking stay with each wrapper — this only owns "how do we get
// an open, correctly-configured `sqlite3*` handle."

import Foundation
import SQLite3

public enum SQLiteHandle {

    /// One `PRAGMA <clause>;` to apply on open, with a short `name` used for error logging.
    public typealias Pragma = (pragma: String, name: String)

    /// WAL for crash safety, a busy timeout to avoid SQLITE_BUSY under contention, NORMAL
    /// sync for performance. The pragma set shared by the file-backed database wrappers.
    public static let standardPragmas: [Pragma] = [
        ("journal_mode=WAL", "journal_mode"),
        ("busy_timeout=5000", "busy_timeout"),
        ("synchronous=NORMAL", "synchronous"),
    ]

    /// Open a file-backed database at `url` and apply `pragmas` + owner-only permissions.
    ///
    /// Does NOT create the parent directory — callers manage that themselves, since some
    /// need directory-level permission hardening (e.g. 0o700) that differs from the
    /// database file's own 0o600 and predates this helper.
    ///
    /// `onPragmaFailure` is invoked once per failing pragma with `(name, detail)`. If it
    /// throws, pragma application stops at that pragma (fail-fast callers); if it returns
    /// normally, the remaining pragmas are still attempted (log-and-continue callers).
    ///
    /// Returns nil if `sqlite3_open` itself fails, in which case `onOpenFailure` receives
    /// the sqlite error message.
    @discardableResult
    public static func open(
        at url: URL,
        pragmas: [Pragma] = standardPragmas,
        ownerOnly: Bool = true,
        onOpenFailure: (String) -> Void = { _ in },
        onPragmaFailure: (String, String) throws -> Void = { _, _ in }
    ) rethrows -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            // SQLite usually hands back a handle even when the open fails, and
            // it must still be closed (closing nil is a no-op).
            sqlite3_close(db)
            onOpenFailure(message)
            return nil
        }
        try configure(db, at: url, pragmas: pragmas, ownerOnly: ownerOnly, onPragmaFailure: onPragmaFailure)
        return db
    }

    /// Apply owner-only permissions + pragmas to an already-open handle. Exposed separately
    /// so callers that manage `sqlite3_open` themselves (e.g. corruption-recovery re-open)
    /// can still share the configuration step.
    public static func configure(
        _ db: OpaquePointer?,
        at url: URL,
        pragmas: [Pragma] = standardPragmas,
        ownerOnly: Bool = true,
        onPragmaFailure: (String, String) throws -> Void = { _, _ in }
    ) rethrows {
        if ownerOnly {
            FileManager.default.restrictSQLiteArtifactsToOwnerOnly(atPath: url.path)
        }
        for (pragma, name) in pragmas {
            var errorMessage: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, "PRAGMA \(pragma);", nil, nil, &errorMessage) != SQLITE_OK {
                let detail = errorMessage.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(errorMessage)
                try onPragmaFailure(name, detail)
            }
        }
    }

    /// Move a corrupt SQLite file together with its `-wal` and `-shm` sidecars to `backupURL`
    /// so the backup keeps any uncheckpointed frames and a freshly created database at `dbURL`
    /// can never replay stale WAL frames.
    ///
    /// Call BEFORE closing the last handle on `dbURL` (closing truncates `-wal` in place).
    /// If `backupURL` (or one of its sidecars) already exists, appends a unique suffix so
    /// back-to-back recoveries never collide. If a `-wal` or `-shm` sidecar cannot be moved,
    /// it is removed so it cannot contaminate the recreated database.
    ///
    /// Returns `true` when the main database file was moved aside (or was already absent),
    /// and `false` if moving the main file failed (in which case `-wal` and `-shm` are
    /// left untouched so uncheckpointed frames are never stripped from the unmoved file).
    @discardableResult
    public static func quarantineCorruptArtifacts(
        at dbURL: URL,
        to backupURL: URL,
        onMoveFailure: (String, Error) -> Void = { _, _ in }
    ) -> Bool {
        let fm = FileManager.default
        let resolvedBackup = uniqueBackupURL(startingAt: backupURL, fileManager: fm)

        for suffix in ["", "-wal", "-shm"] {
            let source = URL(fileURLWithPath: dbURL.path + suffix)
            guard fm.fileExists(atPath: source.path) else { continue }
            let destination = URL(fileURLWithPath: resolvedBackup.path + suffix)
            do {
                try fm.moveItem(at: source, to: destination)
            } catch {
                onMoveFailure(suffix, error)
                if suffix.isEmpty {
                    // Stop immediately: never move or delete -wal/-shm while the main
                    // database file remains in place.
                    return false
                }
                // The -shm is a rebuildable index; a stale -wal must never stay next to the new file.
                try? fm.removeItem(at: source)
            }
        }

        return true
    }

    /// Remove any lingering `-wal` or `-shm` sidecars next to `dbURL` (for example after
    /// closing a corrupt handle and before opening a fresh database file).
    public static func removeSidecars(at dbURL: URL) {
        let fm = FileManager.default
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: dbURL.path + suffix)
            guard fm.fileExists(atPath: sidecar.path) else { continue }
            try? fm.removeItem(at: sidecar)
        }
    }

    private static func uniqueBackupURL(startingAt base: URL, fileManager fm: FileManager) -> URL {
        let suffixes = ["", "-wal", "-shm"]
        let collides = suffixes.contains { fm.fileExists(atPath: base.path + $0) }
        guard collides else { return base }

        let dir = base.deletingLastPathComponent()
        let ext = base.pathExtension
        let stem = ext.isEmpty
            ? base.lastPathComponent
            : String(base.lastPathComponent.dropLast(ext.count + 1))
        let uniqueName = ext.isEmpty
            ? "\(stem)_\(UUID().uuidString.prefix(8))"
            : "\(stem)_\(UUID().uuidString.prefix(8)).\(ext)"
        return dir.appendingPathComponent(uniqueName)
    }
}
