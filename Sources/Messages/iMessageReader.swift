// iMessageReader.swift
// Reads the user's sent iMessages from ~/Library/Messages/chat.db for style analysis.
// Requires Full Disk Access (FDA) permission since ~/Library/Messages/ is SIP-protected.

import Foundation
import SQLite3

actor iMessageReader {

    // MARK: - Types

    enum ReaderError: LocalizedError {
        case databaseNotFound
        case databaseEmpty
        case accessDenied
        case queryFailed(String)

        var errorDescription: String? {
            switch self {
            case .databaseNotFound:
                return "iMessage database not found. You may not have iMessage set up on this Mac."
            case .databaseEmpty:
                return "We couldn't find enough substantive messages in your recent history."
            case .accessDenied:
                return "Draft needs Full Disk Access to read your iMessages."
            case .queryFailed(let msg):
                return "Failed to read messages: \(msg)"
            }
        }
    }

    struct ImportedMessage {
        let text: String
        let date: Date
        let handleId: String
    }

    // MARK: - Database Path

    private let dbPath = NSHomeDirectory() + "/Library/Messages/chat.db"

    /// Check if the database file exists (does NOT check FDA — that requires opening)
    func databaseExists() -> Bool {
        FileManager.default.fileExists(atPath: dbPath)
    }

    // MARK: - Read Messages

    /// Read the user's sent messages, filtered for quality.
    func readMessages(limit: Int = 2000) throws -> [ImportedMessage] {
        guard FileManager.default.fileExists(atPath: dbPath) else {
            throw ReaderError.databaseNotFound
        }

        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK, let db = db else {
            let errMsg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            if errMsg.contains("unable to open") || errMsg.contains("permission") || errMsg.contains("not authorized") || errMsg.contains("authorization") {
                Task { @MainActor in
                    EventReporter.shared.capture(level: .error, engine: "imessage", event: "imessage_db_open_failed",
                        message: "Access denied: \(errMsg)")
                }
                throw ReaderError.accessDenied
            }
            Task { @MainActor in
                EventReporter.shared.capture(level: .error, engine: "imessage", event: "imessage_db_open_failed",
                    message: errMsg)
            }
            throw ReaderError.queryFailed(errMsg)
        }
        defer { sqlite3_close(db) }

        let query = """
            SELECT m.text, m.date, h.id
            FROM message m
            LEFT JOIN handle h ON m.handle_id = h.ROWID
            WHERE m.is_from_me = 1
              AND m.text IS NOT NULL
              AND m.text != ''
            ORDER BY m.date DESC
            LIMIT ?
            """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            let errMsg = String(cString: sqlite3_errmsg(db))
            Task { @MainActor in
                EventReporter.shared.capture(level: .error, engine: "imessage", event: "imessage_query_failed",
                    message: errMsg)
            }
            throw ReaderError.queryFailed(errMsg)
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var messages: [ImportedMessage] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let textPtr = sqlite3_column_text(stmt, 0) else { continue }
            let text = String(cString: textPtr)

            if shouldSkip(text) { continue }

            let dateNanos = sqlite3_column_int64(stmt, 1)
            let date = Date(timeIntervalSinceReferenceDate: Double(dateNanos) / 1_000_000_000)

            let handleId: String
            if let handlePtr = sqlite3_column_text(stmt, 2) {
                handleId = String(cString: handlePtr)
            } else {
                handleId = "unknown"
            }

            messages.append(ImportedMessage(text: text, date: date, handleId: handleId))
        }

        if messages.isEmpty {
            throw ReaderError.databaseEmpty
        }

        return messages
    }

    private func shouldSkip(_ text: String) -> Bool {
        MessageFilter.shouldSkip(text)
    }

    // MARK: - Format for Analysis

    /// Join messages into a single text block for Sonnet style analysis.
    func formatForAnalysis(_ messages: [ImportedMessage], maxMessages: Int = 500) -> String {
        let selected = Array(messages.prefix(maxMessages))
        return selected.map { $0.text }.joined(separator: "\n\n---\n\n")
    }
}
