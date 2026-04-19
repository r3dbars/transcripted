import ArgumentParser
import Foundation
import SQLite3

struct RoundTrip: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "round-trip",
        abstract: "Generate test data, validate, corrupt, re-validate — verifies validators catch real defects."
    )

    func run() throws {
        let tmpBase = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("transcripted-roundtrip-\(ProcessInfo.processInfo.processIdentifier)")
        let cleanDir = tmpBase.appendingPathComponent("clean")
        let fm = FileManager.default

        // Ensure clean slate
        if fm.fileExists(atPath: tmpBase.path) {
            try fm.removeItem(at: tmpBase)
        }

        defer {
            try? fm.removeItem(at: tmpBase)
        }

        // Step 1: Generate clean fixtures
        print("=== Step 1: Generate clean test data ===")
        let generator = TestDataGenerator(outputDir: cleanDir)
        try generator.generateAll()
        print("Generated fixtures at: \(cleanDir.path)")

        // Step 2: Validate clean data — expect 0 failures
        print("\n=== Step 2: Validate clean data (expect all PASS) ===")
        let cleanResults = runAllValidators(dir: cleanDir)
        let cleanFails = cleanResults.filter { $0.status == .fail }

        if cleanFails.isEmpty {
            print("PASS  Clean data passed all validators (\(cleanResults.count) checks)")
        } else {
            print("FAIL  Clean data had \(cleanFails.count) unexpected failures:")
            for f in cleanFails {
                print("      \(f.textLine)")
            }
        }

        // Step 3: Corruption tests
        print("\n=== Step 3: Corruption round-trip tests ===")

        var passed = 0
        var total = 0

        let checks: [(String, () throws -> Bool)] = [
            // --- YAML / Transcript ---

            ("Remove transcription_engine from YAML", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "yaml-engine") { dir in
                    let mdFile = dir.appendingPathComponent("Call_2026-03-26_10-30-00.md")
                    var content = try String(contentsOf: mdFile, encoding: .utf8)
                    content = content.replacingOccurrences(of: "transcription_engine: parakeet_local\n", with: "")
                    try content.write(to: mdFile, atomically: true, encoding: .utf8)
                    try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: mdFile.path)

                    let results = TranscriptValidator(directory: dir).validate()
                    return results.contains { $0.status == .fail && $0.check == "transcript/yaml-required-keys" }
                }
            }),

            ("Remove Markdown file for JSON sidecar", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "markdown-missing") { dir in
                    let mdFile = dir.appendingPathComponent("Call_2026-03-26_10-30-00.md")
                    try fm.removeItem(at: mdFile)

                    let results = JSONSidecarValidator(directory: dir).validate()
                    return results.contains { $0.status == .fail && $0.check == "artifact/md-match" }
                }
            }),

            // --- JSON Sidecar ---

            ("Unsort utterances in JSON sidecar", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "unsorted-utterances") { dir in
                    let jsonFile = dir.appendingPathComponent("Call_2026-03-26_14-00-00.json")
                    let data = try Data(contentsOf: jsonFile)
                    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          var utterances = json["utterances"] as? [[String: Any]],
                          utterances.count >= 2 else {
                        return false
                    }
                    utterances.reverse()
                    json["utterances"] = utterances
                    let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                    try newData.write(to: jsonFile)

                    let results = JSONSidecarValidator(directory: dir).validate()
                    return results.contains { $0.status == .fail && $0.check == "artifact/json-utterances-sorted" }
                }
            }),

            ("Set negative duration_seconds in JSON", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "negative-duration") { dir in
                    let jsonFile = dir.appendingPathComponent("Call_2026-03-26_10-30-00.json")
                    let data = try Data(contentsOf: jsonFile)
                    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          var recording = json["recording"] as? [String: Any] else {
                        return false
                    }
                    recording["duration_seconds"] = -1
                    json["recording"] = recording
                    let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                    try newData.write(to: jsonFile)

                    let results = JSONSidecarValidator(directory: dir).validate()
                    return results.contains { $0.status == .fail && $0.check == "artifact/json-duration" }
                }
            }),

            ("Add phantom speaker ref in utterances", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "phantom-speaker-ref") { dir in
                    let jsonFile = dir.appendingPathComponent("Call_2026-03-26_10-30-00.json")
                    let data = try Data(contentsOf: jsonFile)
                    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          var utterances = json["utterances"] as? [[String: Any]] else {
                        return false
                    }
                    // Add an utterance that references a speaker not in the speakers array
                    utterances.append([
                        "start": 9999.0,
                        "end": 10000.0,
                        "text": "Ghost speaker utterance",
                        "speaker_id": "speaker_nonexistent_999"
                    ])
                    json["utterances"] = utterances
                    let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                    try newData.write(to: jsonFile)

                    let results = JSONSidecarValidator(directory: dir).validate()
                    return results.contains { $0.status == .fail && $0.check == "artifact/json-speaker-refs" }
                }
            }),

            ("Set version to 99.0 in JSON sidecar", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "bad-json-version") { dir in
                    let jsonFile = dir.appendingPathComponent("Call_2026-03-26_10-30-00.json")
                    let data = try Data(contentsOf: jsonFile)
                    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return false
                    }
                    json["version"] = "99.0"
                    let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                    try newData.write(to: jsonFile)

                    let results = JSONSidecarValidator(directory: dir).validate()
                    return results.contains { $0.status == .fail && $0.check == "artifact/json-version" }
                }
            }),

            // --- Speaker DB: data-level corruptions ---

            ("Corrupt speakers.sqlite with garbage bytes", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "corrupt-speakerdb") { dir in
                    let dbFile = dir.appendingPathComponent("speakers.sqlite")
                    let garbage = Data("THIS IS NOT A SQLITE DATABASE FILE".utf8)
                    try garbage.write(to: dbFile)

                    let results = SpeakerDBValidator(dbPath: dbFile.path).validate()
                    return results.contains { $0.status == .fail }
                }
            }),

            ("Insert speaker with wrong embedding size (512 bytes)", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "wrong-embedding-size") { dir in
                    let dbPath = dir.appendingPathComponent("speakers.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    // Insert a speaker with a 512-byte embedding (128 floats) instead of 1024
                    let uuid = UUID().uuidString
                    let now = ISO8601DateFormatter().string(from: Date())
                    var embedding = [Float](repeating: 0.5, count: 128)
                    let embData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }

                    let sql = "INSERT INTO speakers (id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count) VALUES (?, 'BadEmbed', 'test', ?, ?, ?, 1, 0.5, 0)"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    _ = embData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(embData.count), nil)
                    }
                    sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)

                    let results = SpeakerDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/speakers-embedding-size" }
                }
            }),

            ("Insert speaker with NULL embedding", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "null-embedding") { dir in
                    let dbPath = dir.appendingPathComponent("speakers.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    let uuid = UUID().uuidString
                    let now = ISO8601DateFormatter().string(from: Date())
                    // Insert with a valid embedding first, then set it to NULL
                    var embedding = [Float](repeating: 0.5, count: 256)
                    let embData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }

                    let insertSQL = "INSERT INTO speakers (id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count) VALUES (?, 'NullEmbed', 'test', ?, ?, ?, 1, 0.5, 0)"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, insertSQL, -1, &stmt, nil) == SQLITE_OK else { return false }
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    _ = embData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(embData.count), nil)
                    }
                    sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)
                    sqlite3_finalize(stmt)

                    // The column has NOT NULL constraint, so UPDATE SET NULL silently fails.
                    // Instead, recreate the table without NOT NULL, migrate data, then set NULL.
                    let migrationSQL = """
                    CREATE TABLE speakers_new (
                        id TEXT PRIMARY KEY, display_name TEXT, name_source TEXT,
                        embedding BLOB, first_seen TEXT, last_seen TEXT,
                        call_count INTEGER, confidence REAL, dispute_count INTEGER,
                        created_at TEXT DEFAULT CURRENT_TIMESTAMP
                    );
                    INSERT INTO speakers_new SELECT * FROM speakers;
                    DROP TABLE speakers;
                    ALTER TABLE speakers_new RENAME TO speakers;
                    UPDATE speakers SET embedding = NULL WHERE id = '\(uuid)';
                    """
                    var errMsg: UnsafeMutablePointer<CChar>?
                    sqlite3_exec(db, migrationSQL, nil, nil, &errMsg)
                    sqlite3_free(errMsg)

                    let results = SpeakerDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/speakers-no-null-embeddings" }
                }
            }),

            ("Insert speaker with confidence=5.0 (out of range)", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "bad-confidence") { dir in
                    let dbPath = dir.appendingPathComponent("speakers.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    let uuid = UUID().uuidString
                    let now = ISO8601DateFormatter().string(from: Date())
                    // Valid 1024-byte embedding
                    var embedding = [Float](repeating: 0.5, count: 256)
                    let embData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }

                    let sql = "INSERT INTO speakers (id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count) VALUES (?, 'BadConf', 'test', ?, ?, ?, 1, 5.0, 0)"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    _ = embData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(embData.count), nil)
                    }
                    sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)

                    let results = SpeakerDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/speakers-confidence-range" }
                }
            }),

            ("Insert speaker with call_count=0", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "zero-callcount") { dir in
                    let dbPath = dir.appendingPathComponent("speakers.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    let uuid = UUID().uuidString
                    let now = ISO8601DateFormatter().string(from: Date())
                    var embedding = [Float](repeating: 0.5, count: 256)
                    let embData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }

                    let sql = "INSERT INTO speakers (id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count) VALUES (?, 'ZeroCall', 'test', ?, ?, ?, 0, 0.5, 0)"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    _ = embData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(embData.count), nil)
                    }
                    sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)

                    let results = SpeakerDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/speakers-callcount-positive" }
                }
            }),

            ("Insert speaker with invalid UUID", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "invalid-uuid") { dir in
                    let dbPath = dir.appendingPathComponent("speakers.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    let now = ISO8601DateFormatter().string(from: Date())
                    var embedding = [Float](repeating: 0.5, count: 256)
                    let embData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }

                    let sql = "INSERT INTO speakers (id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count) VALUES (?, 'BadUUID', 'test', ?, ?, ?, 1, 0.5, 0)"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, ("not-a-valid-uuid" as NSString).utf8String, -1, nil)
                    _ = embData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(embData.count), nil)
                    }
                    sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)

                    let results = SpeakerDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/speakers-valid-uuids" }
                }
            }),

            ("Insert speaker with invalid name_source", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "invalid-name-source") { dir in
                    let dbPath = dir.appendingPathComponent("speakers.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    let uuid = UUID().uuidString
                    let now = ISO8601DateFormatter().string(from: Date())
                    var embedding = [Float](repeating: 0.5, count: 256)
                    let embData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }

                    let sql = "INSERT INTO speakers (id, display_name, name_source, embedding, first_seen, last_seen, call_count, confidence, dispute_count) VALUES (?, 'BadSource', 'invalid_source', ?, ?, ?, 1, 0.5, 0)"
                    var stmt: OpaquePointer?
                    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
                    defer { sqlite3_finalize(stmt) }
                    sqlite3_bind_text(stmt, 1, (uuid as NSString).utf8String, -1, nil)
                    _ = embData.withUnsafeBytes { ptr in
                        sqlite3_bind_blob(stmt, 2, ptr.baseAddress, Int32(embData.count), nil)
                    }
                    sqlite3_bind_text(stmt, 3, (now as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (now as NSString).utf8String, -1, nil)
                    sqlite3_step(stmt)

                    let results = SpeakerDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/speakers-name-source" }
                }
            }),

            // --- Stats DB ---

            ("Set invalid date in stats.sqlite", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "invalid-stats-date") { dir in
                    let dbPath = dir.appendingPathComponent("stats.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    var errMsg: UnsafeMutablePointer<CChar>?
                    let sql = "UPDATE recordings SET date = 'not-a-date' WHERE rowid = 1"
                    sqlite3_exec(db, sql, nil, nil, &errMsg)
                    sqlite3_free(errMsg)

                    let results = StatsDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/stats-valid-dates" }
                }
            }),

            ("Drop recordings table from stats.sqlite", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "drop-recordings-table") { dir in
                    let dbPath = dir.appendingPathComponent("stats.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    var errMsg: UnsafeMutablePointer<CChar>?
                    sqlite3_exec(db, "DROP TABLE recordings", nil, nil, &errMsg)
                    sqlite3_free(errMsg)

                    let results = StatsDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/stats-schema-recordings" }
                }
            }),

            ("Insert recording with negative duration in stats.sqlite", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "negative-stats-duration") { dir in
                    let dbPath = dir.appendingPathComponent("stats.sqlite").path
                    var db: OpaquePointer?
                    guard sqlite3_open(dbPath, &db) == SQLITE_OK, let db = db else { return false }
                    defer { sqlite3_close(db) }

                    var errMsg: UnsafeMutablePointer<CChar>?
                    let uuid = UUID().uuidString
                    let sql = "INSERT INTO recordings (id, date, time, duration_seconds, word_count, speaker_count, processing_time_ms, transcript_path, title) VALUES ('\(uuid)', '2026-03-26', '12:00:00', -999, 100, 1, 5000, 'test.md', 'Negative Duration')"
                    sqlite3_exec(db, sql, nil, nil, &errMsg)
                    sqlite3_free(errMsg)

                    let results = StatsDBValidator(dbPath: dbPath).validate()
                    return results.contains { $0.status == .fail && $0.check == "database/stats-positive-durations" }
                }
            }),

            // --- Index ---

            ("Set wrong transcript_count in index", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "wrong-index-count") { dir in
                    let indexFile = dir.appendingPathComponent("transcripted.json")
                    let data = try Data(contentsOf: indexFile)
                    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        return false
                    }
                    json["transcript_count"] = 999
                    let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                    try newData.write(to: indexFile)

                    let results = IndexValidator(directory: dir).validate()
                    return results.contains { $0.status == .fail && $0.check == "index/count-match" }
                }
            }),

            ("Add phantom filename in index that does not exist on disk", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "phantom-index-file") { dir in
                    let indexFile = dir.appendingPathComponent("transcripted.json")
                    let data = try Data(contentsOf: indexFile)
                    guard var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                          var transcripts = json["transcripts"] as? [[String: Any]] else {
                        return false
                    }
                    // Add a transcript entry that has no matching file on disk
                    transcripts.append([
                        "filename": "Call_2026-12-31_23-59-59",
                        "date": "2026-12-31",
                        "duration_seconds": 100,
                        "speaker_count": 0,
                        "word_count": 0,
                        "speakers": [] as [[String: Any]]
                    ])
                    json["transcripts"] = transcripts
                    json["transcript_count"] = transcripts.count
                    let newData = try JSONSerialization.data(withJSONObject: json, options: .prettyPrinted)
                    try newData.write(to: indexFile)

                    let results = IndexValidator(directory: dir).validate()
                    return results.contains { $0.status == .fail && $0.check == "index/file-on-disk" }
                }
            }),

            // --- Log ---

            ("Write invalid JSON line in log", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "invalid-log-line") { dir in
                    let logFile = dir.appendingPathComponent("Logs/app.jsonl")
                    var content = try String(contentsOf: logFile, encoding: .utf8)
                    content = "this is not valid json {{{]\n" + content
                    try content.write(to: logFile, atomically: true, encoding: .utf8)

                    let results = LogValidator(logPath: logFile.path).validate()
                    return results.contains { $0.status == .fail && $0.check == "logs/jsonl-valid" }
                }
            }),

            ("Write log line with invalid level 'critical'", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "invalid-log-level") { dir in
                    let logFile = dir.appendingPathComponent("Logs/app.jsonl")
                    var content = try String(contentsOf: logFile, encoding: .utf8)
                    let badEntry: [String: Any] = ["t": "2026-03-26T10:00:00Z", "l": "critical", "s": "app", "m": "Bad level"]
                    let badData = try JSONSerialization.data(withJSONObject: badEntry, options: [.sortedKeys])
                    let badLine = String(data: badData, encoding: .utf8)!
                    content = badLine + "\n" + content
                    try content.write(to: logFile, atomically: true, encoding: .utf8)

                    let results = LogValidator(logPath: logFile.path).validate()
                    return results.contains { $0.status == .fail && $0.check == "logs/jsonl-valid-levels" }
                }
            }),

            ("Write log line missing the 'm' (message) key", {
                try corruptionTest(cleanDir: cleanDir, tmpBase: tmpBase, name: "missing-log-message") { dir in
                    let logFile = dir.appendingPathComponent("Logs/app.jsonl")
                    var content = try String(contentsOf: logFile, encoding: .utf8)
                    // Entry with t, l, s but no m
                    let badEntry: [String: Any] = ["t": "2026-03-26T10:00:00Z", "l": "info", "s": "app"]
                    let badData = try JSONSerialization.data(withJSONObject: badEntry, options: [.sortedKeys])
                    let badLine = String(data: badData, encoding: .utf8)!
                    content = badLine + "\n" + content
                    try content.write(to: logFile, atomically: true, encoding: .utf8)

                    let results = LogValidator(logPath: logFile.path).validate()
                    return results.contains { $0.status == .fail && $0.check == "logs/jsonl-required-keys" }
                }
            }),
        ]

        for (description, check) in checks {
            total += 1
            do {
                let caught = try check()
                if caught {
                    print("PASS  \(description) — validator caught the corruption")
                    passed += 1
                } else {
                    print("FAIL  \(description) — validator did NOT detect the corruption")
                }
            } catch {
                print("FAIL  \(description) — error: \(error.localizedDescription)")
            }
        }

        // Summary
        print("\n=== Summary ===")
        let cleanStatus = cleanFails.isEmpty ? "PASS" : "FAIL"
        print("Clean data validation: \(cleanStatus) (\(cleanResults.count) checks, \(cleanFails.count) failures)")
        print("Corruption round-trip: \(passed)/\(total) checks passed")

        let allPassed = cleanFails.isEmpty && passed == total
        if !allPassed {
            throw ExitCode(1)
        }
    }

    // MARK: - Helpers

    /// Run all validators against a data directory, with the log expected at dir/Logs/app.jsonl.
    private func runAllValidators(dir: URL) -> [ValidationResult] {
        var results: [ValidationResult] = []
        results += TranscriptValidator(directory: dir).validate()
        results += JSONSidecarValidator(directory: dir).validate()
        results += SpeakerDBValidator(dbPath: dir.appendingPathComponent("speakers.sqlite").path).validate()
        results += StatsDBValidator(dbPath: dir.appendingPathComponent("stats.sqlite").path).validate()
        results += LogValidator(logPath: dir.appendingPathComponent("Logs/app.jsonl").path).validate()
        results += IndexValidator(directory: dir).validate()
        return results
    }

    /// Copy clean data to a temp directory, apply a corruption, and check if the validator catches it.
    private func corruptionTest(
        cleanDir: URL,
        tmpBase: URL,
        name: String,
        corrupt: (URL) throws -> Bool
    ) throws -> Bool {
        let testDir = tmpBase.appendingPathComponent("corrupt-\(name)")
        let fm = FileManager.default

        // Remove previous test run if it exists
        if fm.fileExists(atPath: testDir.path) {
            try fm.removeItem(at: testDir)
        }

        // Deep copy the clean directory
        try fm.copyItem(at: cleanDir, to: testDir)

        return try corrupt(testDir)
    }
}
