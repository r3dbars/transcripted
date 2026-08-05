import Foundation
import SQLite3

// MARK: - Schema / Migration DDL
//
// Table, FTS5 virtual table, trigger, and index definitions for the local
// TranscriptIndex sqlite database. Split out of TranscriptIndex.swift because
// this block is pure declarative DDL with no query logic — moving it here
// keeps the query/reconciliation code in the main file free of ~190 lines of
// SQL string literals. `exec` is `internal` (not `private`) on TranscriptIndex
// specifically so this cross-file extension can call it.

extension TranscriptIndex {
    func createTables() {
        exec("""
            CREATE TABLE IF NOT EXISTS meetings (
                filename TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                datetime TEXT NOT NULL,
                duration_seconds INTEGER NOT NULL,
                speaker_count INTEGER NOT NULL,
                word_count INTEGER NOT NULL,
                json_modified_at REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS meeting_speakers (
                filename TEXT NOT NULL,
                speaker_name TEXT NOT NULL,
                persistent_speaker_id TEXT,
                word_count INTEGER NOT NULL DEFAULT 0,
                speaking_seconds REAL NOT NULL DEFAULT 0,
                PRIMARY KEY (filename, speaker_name)
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS utterances (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL,
                speaker_name TEXT NOT NULL,
                utterance_start REAL NOT NULL,
                utterance_end REAL NOT NULL,
                text TEXT NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS dictation_days (
                filename TEXT PRIMARY KEY,
                date TEXT NOT NULL,
                datetime TEXT NOT NULL,
                markdown_filename TEXT NOT NULL,
                entry_count INTEGER NOT NULL,
                word_count INTEGER NOT NULL,
                json_modified_at REAL NOT NULL
            )
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS dictation_entries (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL,
                entry_id TEXT NOT NULL,
                title TEXT NOT NULL,
                created_at TEXT NOT NULL,
                source_app_name TEXT NOT NULL,
                source_app_bundle_id TEXT,
                delivery TEXT NOT NULL,
                word_count INTEGER NOT NULL,
                character_count INTEGER NOT NULL,
                text TEXT NOT NULL
            )
        """)

        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS dictation_entries_fts USING fts5(
                text, title, source_app_name,
                content='dictation_entries', content_rowid='rowid',
                tokenize='porter unicode61'
            )
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS dictation_entries_ai AFTER INSERT ON dictation_entries BEGIN
                INSERT INTO dictation_entries_fts(rowid, text, title, source_app_name)
                VALUES (new.rowid, new.text, new.title, new.source_app_name);
            END
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS dictation_entries_ad AFTER DELETE ON dictation_entries BEGIN
                INSERT INTO dictation_entries_fts(dictation_entries_fts, rowid, text, title, source_app_name)
                VALUES ('delete', old.rowid, old.text, old.title, old.source_app_name);
            END
        """)

        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS utterances_fts USING fts5(
                text, speaker_name,
                content='utterances', content_rowid='rowid',
                tokenize='porter unicode61'
            )
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS utterances_ai AFTER INSERT ON utterances BEGIN
                INSERT INTO utterances_fts(rowid, text, speaker_name)
                VALUES (new.rowid, new.text, new.speaker_name);
            END
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS utterances_ad AFTER DELETE ON utterances BEGIN
                INSERT INTO utterances_fts(utterances_fts, rowid, text, speaker_name)
                VALUES ('delete', old.rowid, old.text, old.speaker_name);
            END
        """)

        // Structured summary fields (Decisions / Action Items / Open Questions)
        // parsed from each meeting's legacy summary fields. One row per bullet, keyed to
        // the meeting filename, with a `kind` discriminator so cross-meeting tools
        // (list_action_items, open_questions roll-ups) can aggregate over all
        // meetings without a per-category table. Mirrors the utterances + FTS5 +
        // triggers pattern above.
        exec("""
            CREATE TABLE IF NOT EXISTS meeting_summary_items (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL,
                kind TEXT NOT NULL,
                position INTEGER NOT NULL,
                owner TEXT,
                text TEXT NOT NULL,
                status TEXT,
                due TEXT
            )
        """)

        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS meeting_summary_items_fts USING fts5(
                text, owner, status, due,
                content='meeting_summary_items', content_rowid='rowid',
                tokenize='porter unicode61'
            )
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS meeting_summary_items_ai AFTER INSERT ON meeting_summary_items BEGIN
                INSERT INTO meeting_summary_items_fts(rowid, text, owner, status, due)
                VALUES (new.rowid, new.text, new.owner, new.status, new.due);
            END
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS meeting_summary_items_ad AFTER DELETE ON meeting_summary_items BEGIN
                INSERT INTO meeting_summary_items_fts(meeting_summary_items_fts, rowid, text, owner, status, due)
                VALUES ('delete', old.rowid, old.text, old.owner, old.status, old.due);
            END
        """)

        exec("""
            CREATE TABLE IF NOT EXISTS meeting_summary_documents (
                rowid INTEGER PRIMARY KEY AUTOINCREMENT,
                filename TEXT NOT NULL UNIQUE,
                title TEXT NOT NULL DEFAULT '',
                attendees TEXT NOT NULL DEFAULT '',
                decisions TEXT NOT NULL DEFAULT '',
                action_items TEXT NOT NULL DEFAULT '',
                open_questions TEXT NOT NULL DEFAULT ''
            )
        """)

        exec("""
            CREATE VIRTUAL TABLE IF NOT EXISTS meeting_summary_documents_fts USING fts5(
                title, attendees, decisions, action_items, open_questions,
                content='meeting_summary_documents', content_rowid='rowid',
                tokenize='porter unicode61'
            )
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS meeting_summary_documents_ai AFTER INSERT ON meeting_summary_documents BEGIN
                INSERT INTO meeting_summary_documents_fts(rowid, title, attendees, decisions, action_items, open_questions)
                VALUES (new.rowid, new.title, new.attendees, new.decisions, new.action_items, new.open_questions);
            END
        """)

        exec("""
            CREATE TRIGGER IF NOT EXISTS meeting_summary_documents_ad AFTER DELETE ON meeting_summary_documents BEGIN
                INSERT INTO meeting_summary_documents_fts(meeting_summary_documents_fts, rowid, title, attendees, decisions, action_items, open_questions)
                VALUES ('delete', old.rowid, old.title, old.attendees, old.decisions, old.action_items, old.open_questions);
            END
        """)

        exec("CREATE INDEX IF NOT EXISTS idx_meetings_date ON meetings(date)")
        exec("CREATE INDEX IF NOT EXISTS idx_meeting_speakers_name ON meeting_speakers(speaker_name COLLATE NOCASE)")
        exec("CREATE INDEX IF NOT EXISTS idx_meeting_speakers_persistent_id ON meeting_speakers(persistent_speaker_id)")
        exec("CREATE INDEX IF NOT EXISTS idx_utterances_filename ON utterances(filename)")
        exec("CREATE INDEX IF NOT EXISTS idx_dictation_days_date ON dictation_days(date)")
        exec("CREATE INDEX IF NOT EXISTS idx_dictation_entries_filename ON dictation_entries(filename)")
        exec("CREATE INDEX IF NOT EXISTS idx_dictation_entries_created_at ON dictation_entries(created_at)")
        exec("CREATE INDEX IF NOT EXISTS idx_summary_items_filename ON meeting_summary_items(filename)")
        exec("CREATE INDEX IF NOT EXISTS idx_summary_items_kind ON meeting_summary_items(kind)")
        exec("CREATE INDEX IF NOT EXISTS idx_summary_items_owner ON meeting_summary_items(owner COLLATE NOCASE)")
        exec("CREATE INDEX IF NOT EXISTS idx_summary_documents_filename ON meeting_summary_documents(filename)")
    }
}
