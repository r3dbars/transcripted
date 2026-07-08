// RecentMeetingMetadataCache.swift
// A small SQLite-backed index for the Home capture list.
//
// The Home list used to re-read and re-parse every meeting transcript (full
// Markdown read + frontmatter parse + speaker-label regex + summary parse) on
// every refresh, which does not scale to a large library. This cache stores the
// already-derived row metadata keyed by transcript path and validated by the
// transcript + summary-sidecar modification time and size. On a warm refresh the
// scanner reads the row straight from SQLite (a few cheap `stat`s, no file
// content reads); on a miss or when the on-disk file changed it falls back to the
// normal parse and repopulates the row.
//
// The cache stores only the content-derived fields. Retained-audio attachments
// are still resolved live by `MeetingAudioArchiveResolver` on every refresh —
// that is a cheap directory probe, and it already has its own invalidation path
// (`HomeCaptureRefreshObserver`) for background WAV→M4A recompression and renames.

import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// File-identity stamp used to decide whether a cached row is still valid.
/// All four values come from `stat`-level metadata, never from reading content.
struct RecentMeetingCacheStamp: Equatable, Sendable {
    let transcriptModified: Double
    let transcriptSize: Int64
    /// `summaryModified`/`summarySize` are `0`/`-1` when no summary sidecar exists.
    let summaryModified: Double
    let summarySize: Int64
}

/// The exact content-derived fields a Home meeting row needs, minus the live
/// audio attachment. Persisted as a JSON payload so nested summary sections
/// round-trip without a relational schema.
struct CachedRecentMeetingMetadata: Codable, Sendable {
    let title: String
    let displayDate: Date
    let startDate: Date?
    let endDate: Date?
    /// `nil` means speakers are ready; otherwise the needs-review label count.
    let speakerNeedsReviewCount: Int?
    let summaryPreview: CachedSummaryPreview?
    let hasAudioHealth: Bool
    let audioHealthMicBoostOutcome: String?

    struct CachedSummaryPreview: Codable, Sendable {
        let title: String?
        let summary: String
        let sections: [CachedSection]
        let urlPath: String
    }

    struct CachedSection: Codable, Sendable {
        let title: String
        let text: String
    }
}

extension CachedRecentMeetingMetadata {
    /// Build a cache payload from a freshly parsed Home row.
    init(item: RecentMeetingItem) {
        self.title = item.title
        self.displayDate = item.date
        self.startDate = item.startDate
        self.endDate = item.endDate
        if case .needsReview(let count) = item.speakerStatus {
            self.speakerNeedsReviewCount = count
        } else {
            self.speakerNeedsReviewCount = nil
        }
        self.summaryPreview = item.summaryPreview.map { preview in
            CachedSummaryPreview(
                title: preview.title,
                summary: preview.summary,
                sections: preview.sections.map { CachedSection(title: $0.title, text: $0.text) },
                urlPath: preview.url.path
            )
        }
        self.hasAudioHealth = item.audioHealth != nil
        self.audioHealthMicBoostOutcome = item.audioHealth?.micBoostPromptOutcome
    }

    /// Rebuild a Home row from a cached payload. The audio attachment is resolved
    /// live by the caller so it stays correct across background recompression.
    func makeItem(transcriptURL: URL, audio: MeetingAudioAttachment?) -> RecentMeetingItem {
        RecentMeetingItem(
            title: title,
            date: displayDate,
            startDate: startDate,
            endDate: endDate,
            transcriptURL: transcriptURL,
            audio: audio,
            speakerStatus: speakerNeedsReviewCount.map { .needsReview($0) } ?? .ready,
            summaryPreview: summaryPreview.map { preview in
                RecentMeetingSummaryPreview(
                    title: preview.title,
                    summary: preview.summary,
                    sections: preview.sections.map {
                        RecentMeetingSummarySection(title: $0.title, text: $0.text)
                    },
                    url: URL(fileURLWithPath: preview.urlPath)
                )
            },
            audioHealth: hasAudioHealth
                ? RecentMeetingAudioHealth(micBoostPromptOutcome: audioHealthMicBoostOutcome)
                : nil
        )
    }
}

/// Thread-safe SQLite cache. Reads and writes are serialized through a lock so it
/// is safe to share the singleton across the background scan task and any future
/// concurrent caller.
final class RecentMeetingMetadataCache: @unchecked Sendable {
    /// App-wide cache, persisted under the app cache directory. Safe to delete;
    /// it is rebuilt lazily from disk on the next refresh.
    static let shared = RecentMeetingMetadataCache(
        databaseURL: MeetingStoragePaths.cacheFolder
            .appendingPathComponent("home_meeting_metadata.sqlite", isDirectory: false)
    )

    private let lock = NSLock()
    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// - Parameter databaseURL: pass `nil` for a private in-memory cache (tests).
    init(databaseURL: URL?) {
        if let databaseURL {
            try? FileManager.default.createDirectory(
                at: databaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            guard sqlite3_open(databaseURL.path, &db) == SQLITE_OK else {
                db = nil
                return
            }
            // Owner-only: this is a derived cache of meeting metadata, keep it off
            // broader default permissions on multi-user systems.
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: databaseURL.path
            )
        } else {
            guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
                db = nil
                return
            }
        }
        createTable()
    }

    deinit {
        if let db { sqlite3_close(db) }
    }

    private func createTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS meeting_metadata (
            path TEXT PRIMARY KEY,
            transcript_modified REAL NOT NULL,
            transcript_size INTEGER NOT NULL,
            summary_modified REAL NOT NULL,
            summary_size INTEGER NOT NULL,
            payload TEXT NOT NULL
        );
        """
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    /// Return the cached metadata for `path` only when the stored stamp matches
    /// the on-disk stamp exactly. Any change to the transcript or summary sidecar
    /// is a miss, so the caller re-parses and the row stays correct.
    func lookup(path: String, stamp: RecentMeetingCacheStamp) -> CachedRecentMeetingMetadata? {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return nil }

        let sql = """
        SELECT payload FROM meeting_metadata
        WHERE path = ? AND transcript_modified = ? AND transcript_size = ?
          AND summary_modified = ? AND summary_size = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, stamp.transcriptModified)
        sqlite3_bind_int64(stmt, 3, stamp.transcriptSize)
        sqlite3_bind_double(stmt, 4, stamp.summaryModified)
        sqlite3_bind_int64(stmt, 5, stamp.summarySize)

        guard sqlite3_step(stmt) == SQLITE_ROW,
              let cString = sqlite3_column_text(stmt, 0) else { return nil }
        let json = String(cString: cString)
        guard let data = json.data(using: .utf8),
              let payload = try? decoder.decode(CachedRecentMeetingMetadata.self, from: data) else {
            return nil
        }
        return payload
    }

    /// Insert or replace the cached row for `path`.
    func store(path: String, stamp: RecentMeetingCacheStamp, metadata: CachedRecentMeetingMetadata) {
        guard let json = try? encoder.encode(metadata),
              let jsonString = String(data: json, encoding: .utf8) else { return }

        lock.lock()
        defer { lock.unlock() }
        guard let db else { return }

        let sql = """
        INSERT OR REPLACE INTO meeting_metadata
            (path, transcript_modified, transcript_size, summary_modified, summary_size, payload)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_double(stmt, 2, stamp.transcriptModified)
        sqlite3_bind_int64(stmt, 3, stamp.transcriptSize)
        sqlite3_bind_double(stmt, 4, stamp.summaryModified)
        sqlite3_bind_int64(stmt, 5, stamp.summarySize)
        sqlite3_bind_text(stmt, 6, jsonString, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Drop cached rows whose transcript file no longer exists on disk, and report
    /// how many were removed. Stale rows accumulate whenever a meeting is deleted
    /// or moved (and, historically, when tests wrote fixture rows into the shared
    /// cache). A missing file is already a lookup miss, so these rows are harmless
    /// for correctness, but left unbounded they bloat the table — and if the whole
    /// cached set points at now-gone paths the Home view can strand at "No meetings
    /// yet". Pruning makes the cache self-healing.
    ///
    /// Kept cheap: one table scan to read the paths, a `stat` per row done outside
    /// the SQL step loop, then the missing rows deleted in a single transaction.
    /// Call it from the background refresh path only — never the main thread.
    @discardableResult
    func pruneMissingPaths(fileManager: FileManager = .default) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let db else { return 0 }

        var paths: [String] = []
        var selectStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT path FROM meeting_metadata;", -1, &selectStmt, nil) == SQLITE_OK {
            while sqlite3_step(selectStmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(selectStmt, 0) {
                    paths.append(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(selectStmt)

        let missing = paths.filter { !fileManager.fileExists(atPath: $0) }
        guard !missing.isEmpty else { return 0 }

        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        var deleteStmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM meeting_metadata WHERE path = ?;", -1, &deleteStmt, nil) == SQLITE_OK {
            for path in missing {
                sqlite3_bind_text(deleteStmt, 1, path, -1, SQLITE_TRANSIENT)
                sqlite3_step(deleteStmt)
                sqlite3_reset(deleteStmt)
            }
        }
        sqlite3_finalize(deleteStmt)
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
        return missing.count
    }
}
