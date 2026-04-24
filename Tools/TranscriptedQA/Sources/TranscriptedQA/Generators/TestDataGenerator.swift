import Foundation
import SQLite3

/// Generates valid Transcripted test data that passes all validators.
struct TestDataGenerator {
    let outputDir: URL

    /// Generate a complete test data set: 3 transcripts, databases, index, and log.
    func generateAll() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let transcripts: [(name: String, utterances: Int, speakers: Int, duration: Int)] = [
            ("Call_2026-03-26_00-00-00", 1, 1, 6),       // minimal valid artifact
            ("Call_2026-03-26_10-30-00", 5, 2, 120),      // small
            ("Call_2026-03-26_14-00-00", 50, 5, 3600),    // large
        ]

        for t in transcripts {
            try generateTranscript(name: t.name, utteranceCount: t.utterances, speakerCount: t.speakers)
            try generateSidecar(name: t.name, utteranceCount: t.utterances, speakerCount: t.speakers, durationSeconds: t.duration)
        }

        let speakerCount = 5
        try generateSpeakerDB(speakerCount: speakerCount)
        try generateStatsDB(recordingCount: transcripts.count)
        try generateIndex(transcriptNames: transcripts.map { $0.name })
        try generateLogFile(entryCount: 20, errorRate: 0.0)
    }

    // MARK: - Transcript (.md)

    func generateTranscript(name: String, utteranceCount: Int, speakerCount: Int) throws {
        let micUtterances = utteranceCount / 2
        let systemUtterances = utteranceCount - micUtterances
        let wordCount = utteranceCount * 12 // ~12 words per utterance

        let durationFormatted = utteranceCount > 0 ? "5:00" : "0:00"
        var md = """
        ---
        date: 2026-03-26
        time: 10:30:00
        duration: "\(durationFormatted)"
        processing_time: "0.2s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: \(micUtterances)
        system_utterances: \(systemUtterances)
        mic_speakers: \(speakerCount > 0 ? 1 : 0)
        system_speakers: \(speakerCount > 0 ? speakerCount - 1 : 0)
        total_word_count: \(wordCount)
        capture_quality: good
        audio_gaps: 0
        device_switches: 0
        ---

        ## Summary

        Test transcript generated for validation.

        ## Full Transcript

        """

        for i in 0..<utteranceCount {
            let speaker = speakerCount > 0 ? "Speaker \(i % speakerCount)" : "Speaker 0"
            let minutes = i / 2
            let seconds = (i % 2) * 30
            md += "[\(String(format: "%02d:%02d", minutes, seconds))] [\(speaker)] This is test utterance number \(i + 1) with enough words to be realistic.\n"
        }

        let filePath = outputDir.appendingPathComponent("\(name).md")
        try md.write(to: filePath, atomically: true, encoding: .utf8)

        // Set owner-only permissions (not world-readable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: filePath.path)
    }

    // MARK: - JSON Sidecar

    func generateSidecar(name: String, utteranceCount: Int, speakerCount: Int, durationSeconds: Int) throws {
        let effectiveSpeakerCount = max(speakerCount, utteranceCount > 0 ? 1 : 0)

        let wordsPerSpeaker = utteranceCount > 0 ? (utteranceCount * 12) / max(effectiveSpeakerCount, 1) : 0
        let speakingSecondsPerSpeaker = durationSeconds > 0 ? Double(durationSeconds) / Double(max(effectiveSpeakerCount, 1)) : 0.0

        var speakers: [[String: Any]] = []
        for i in 0..<effectiveSpeakerCount {
            speakers.append([
                "id": "speaker_\(i)",
                "persistent_speaker_id": UUID().uuidString,
                "name": "Speaker \(i)",
                "confidence": i == 0 ? "high" : "medium",
                "word_count": wordsPerSpeaker,
                "speaking_seconds": speakingSecondsPerSpeaker,
                "source": i == 0 ? "mic" : "system_audio"
            ])
        }

        var utterances: [[String: Any]] = []
        for i in 0..<utteranceCount {
            let start = Double(i) * 6.0  // 6 seconds apart, sorted ascending
            utterances.append([
                "start": start,
                "end": start + 5.0,
                "text": "This is test utterance number \(i + 1) with enough words to be realistic.",
                "speaker_id": "speaker_\(i % effectiveSpeakerCount)"
            ])
        }

        let sidecar: [String: Any] = [
            "version": "1.0",
            "recording": [
                "date": "2026-03-26T10:30:00-0500",
                "dropped_segments": 0,
                "engines": [
                    "stt": "parakeet-tdt-v3",
                    "diarization": "pyannote-offline"
                ],
                "duration_seconds": durationSeconds
            ],
            "speakers": speakers,
            "utterances": utterances
        ]

        let data = try JSONSerialization.data(withJSONObject: sidecar, options: [.prettyPrinted, .sortedKeys])
        let filePath = outputDir.appendingPathComponent("\(name).json")
        try data.write(to: filePath)
    }

    // MARK: - Speaker Database

    func generateSpeakerDB(speakerCount: Int) throws {
        let dbPath = outputDir.appendingPathComponent("speakers.sqlite").path
        try createSQLiteDB(at: dbPath) { db in
            try execSQL(db, """
                CREATE TABLE speakers (
                    id TEXT PRIMARY KEY,
                    display_name TEXT,
                    name_source TEXT DEFAULT NULL,
                    embedding BLOB NOT NULL,
                    first_seen TEXT NOT NULL,
                    last_seen TEXT NOT NULL,
                    call_count INTEGER DEFAULT 1,
                    confidence REAL DEFAULT 0.5,
                    dispute_count INTEGER DEFAULT 0,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try execSQL(db, "PRAGMA journal_mode=WAL")

            for i in 0..<speakerCount {
                let uuid = UUID().uuidString
                // Generate a 256-float32 embedding (1024 bytes)
                var embedding = [Float](repeating: 0, count: 256)
                for j in 0..<256 {
                    embedding[j] = Float(j + i) / 256.0
                }
                let embeddingData = embedding.withUnsafeBufferPointer { buffer in
                    Data(buffer: buffer)
                }

                let names = ["Alice", "Bob", "Charlie", "Diana", "Eve"]
                let name = names[i % names.count]
                let now = ISO8601DateFormatter().string(from: Date())

                try insertSpeaker(db,
                                  id: uuid,
                                  displayName: name,
                                  nameSource: "test",
                                  embedding: embeddingData,
                                  firstSeen: now,
                                  lastSeen: now,
                                  callCount: Int64(i + 1),
                                  confidence: min(0.5 + Double(i) * 0.1, 1.0))
            }
        }

        // Set owner-only permissions
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath)
    }

    // MARK: - Stats Database

    func generateStatsDB(recordingCount: Int) throws {
        let dbPath = outputDir.appendingPathComponent("stats.sqlite").path
        try createSQLiteDB(at: dbPath) { db in
            try execSQL(db, """
                CREATE TABLE recordings (
                    id TEXT PRIMARY KEY,
                    date TEXT NOT NULL,
                    time TEXT NOT NULL,
                    duration_seconds INTEGER NOT NULL,
                    word_count INTEGER NOT NULL,
                    speaker_count INTEGER NOT NULL,
                    processing_time_ms INTEGER NOT NULL,
                    transcript_path TEXT NOT NULL,
                    title TEXT,
                    created_at TEXT DEFAULT CURRENT_TIMESTAMP
                )
                """)

            try execSQL(db, """
                CREATE TABLE daily_activity (
                    date TEXT PRIMARY KEY,
                    recording_count INTEGER NOT NULL,
                    total_duration_seconds INTEGER NOT NULL,
                    action_items_count INTEGER NOT NULL
                )
                """)

            try execSQL(db, "PRAGMA journal_mode=WAL")

            for i in 0..<recordingCount {
                let uuid = UUID().uuidString
                let date = "2026-03-26"
                let time = String(format: "%02d:00:00", 10 + i)
                try execSQL(db, """
                    INSERT INTO recordings (id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title)
                    VALUES ('\(uuid)', '\(date)', '\(time)', \(300 * (i + 1)), \(100 * (i + 1)), \(i + 1), \(5000 * (i + 1)), 'Call_2026-03-26.md', 'Test Recording \(i + 1)')
                    """)
            }

            if recordingCount > 0 {
                try execSQL(db, """
                    INSERT INTO daily_activity (date, recording_count, total_duration_seconds, action_items_count)
                    VALUES ('2026-03-26', \(recordingCount), \(recordingCount * 300), 0)
                    """)
            }
        }

        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dbPath)
    }

    // MARK: - Index (transcripted.json)

    func generateIndex(transcriptNames: [String]) throws {
        let speakerNames = ["Alice", "Bob", "Charlie"]
        let speakerIds = (0..<3).map { _ in UUID().uuidString }

        var transcripts: [[String: Any]] = []
        for (idx, name) in transcriptNames.enumerated() {
            let speakerCount = min(idx + 1, speakerIds.count)
            let wordCount = idx * 60  // scaling word count
            let transcriptSpeakers: [[String: Any]] = (0..<speakerCount).map { i in
                ["persistent_speaker_id": speakerIds[i], "name": speakerNames[i]]
            }
            transcripts.append([
                "filename": name,
                "date": "2026-03-26",
                "duration_seconds": 300,
                "speaker_count": speakerCount,
                "word_count": wordCount,
                "speakers": transcriptSpeakers
            ])
        }

        let speakers: [[String: Any]] = speakerIds.enumerated().map { (i, id) in
            ["persistent_id": id, "name": speakerNames[i], "call_count": i + 1]
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let updatedAt = formatter.string(from: Date())

        let index: [String: Any] = [
            "version": "1.0",
            "updated_at": updatedAt,
            "transcript_count": transcripts.count,
            "transcripts": transcripts,
            "known_speakers": speakers
        ]

        let data = try JSONSerialization.data(withJSONObject: index, options: [.prettyPrinted, .sortedKeys])
        let filePath = outputDir.appendingPathComponent("transcripted.json")
        try data.write(to: filePath)
    }

    // MARK: - Log File (app.jsonl)

    func generateLogFile(entryCount: Int, errorRate: Double) throws {
        // Fixture runs keep logs inside a local Logs/ subdirectory so round-trip
        // and stress commands can validate everything from one temp root.
        let logsDir = outputDir.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let subsystems = ["audio", "transcription", "pipeline", "speaker-db", "ui", "stats", "app"]
        let messages = [
            "Recording started",
            "Parakeet transcription complete",
            "Pipeline step finished",
            "Speaker matched",
            "UI state updated",
            "Stats saved",
            "App launched"
        ]

        var lines: [String] = []
        let formatter = ISO8601DateFormatter()

        for i in 0..<entryCount {
            let isError = Double(i) / Double(max(entryCount, 1)) < errorRate
            let level = isError ? "error" : "info"
            let subsystem = subsystems[i % subsystems.count]
            let message = messages[i % messages.count]
            let timestamp = formatter.string(from: Date().addingTimeInterval(Double(-entryCount + i)))

            let entry: [String: Any] = [
                "t": timestamp,
                "l": level,
                "s": subsystem,
                "m": message
            ]

            let data = try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
            if let line = String(data: data, encoding: .utf8) {
                lines.append(line)
            }
        }

        let content = lines.joined(separator: "\n") + "\n"
        let logPath = logsDir.appendingPathComponent("app.jsonl")
        try content.write(to: logPath, atomically: true, encoding: .utf8)
    }

    // MARK: - SQLite Helpers

    private func createSQLiteDB(at path: String, setup: (OpaquePointer) throws -> Void) throws {
        // Remove existing file if any
        let fm = FileManager.default
        if fm.fileExists(atPath: path) {
            try fm.removeItem(atPath: path)
        }

        var db: OpaquePointer?
        guard sqlite3_open(path, &db) == SQLITE_OK, let db = db else {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown error"
            sqlite3_close(db)
            throw GeneratorError.sqliteError("Failed to create database: \(msg)")
        }

        defer { sqlite3_close(db) }
        try setup(db)
    }

    private func execSQL(_ db: OpaquePointer, _ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let msg = errMsg.flatMap { String(cString: $0) } ?? "Unknown error"
            sqlite3_free(errMsg)
            throw GeneratorError.sqliteError("SQL failed: \(msg) — \(sql.prefix(80))")
        }
    }

    private func insertSpeaker(
        _ db: OpaquePointer,
        id: String,
        displayName: String,
        nameSource: String,
        embedding: Data,
        firstSeen: String,
        lastSeen: String,
        callCount: Int64,
        confidence: Double
    ) throws {
        let sql = """
            INSERT INTO speakers (id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw GeneratorError.sqliteError("Prepare failed: \(msg)")
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 2, (displayName as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 3, (nameSource as NSString).utf8String, -1, nil)
        _ = embedding.withUnsafeBytes { ptr in
            sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(embedding.count), nil)
        }
        sqlite3_bind_text(stmt, 5, (firstSeen as NSString).utf8String, -1, nil)
        sqlite3_bind_text(stmt, 6, (lastSeen as NSString).utf8String, -1, nil)
        sqlite3_bind_int64(stmt, 7, callCount)
        sqlite3_bind_double(stmt, 8, confidence)

        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE else {
            let msg = String(cString: sqlite3_errmsg(db))
            throw GeneratorError.sqliteError("Insert failed: \(msg)")
        }
    }
}

enum GeneratorError: Error, LocalizedError {
    case sqliteError(String)
    case fileError(String)

    var errorDescription: String? {
        switch self {
        case .sqliteError(let msg): return "SQLite error: \(msg)"
        case .fileError(let msg): return "File error: \(msg)"
        }
    }
}
