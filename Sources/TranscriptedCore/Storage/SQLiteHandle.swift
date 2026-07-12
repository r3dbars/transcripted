// SQLiteHandle.swift
// Shared SQLite bootstrap: open, owner-only permission hardening, and pragma
// configuration. Consolidates boilerplate that was duplicated (with drift) across
// SpeakerDatabase, StatsDatabase, TimelineDatabase, and RecentMeetingMetadataCache.
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
    /// normally, the remaining pragmas are still attempted (log-and-continue callers). This
    /// mirrors the two behaviors that existed pre-extraction: TimelineDatabase aborted on
    /// the first failing pragma, while SpeakerDatabase/StatsDatabase logged and continued.
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
            onOpenFailure(message)
            return nil
        }
        try configure(db, at: url, pragmas: pragmas, ownerOnly: ownerOnly, onPragmaFailure: onPragmaFailure)
        return db
    }

    /// Open a private in-memory database (no file, no permissions, no pragmas — matches
    /// the ":memory:" fast path used by ephemeral/test callers).
    public static func openInMemory() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            return nil
        }
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
}
