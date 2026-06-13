import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class FileLoggerTests: XCTestCase {

    func testMultipleLoggersAppendWithoutOverwritingEarlierEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: logs
        )

        let first = FileLogger(paths: paths, isDisabledOverride: false)
        let second = FileLogger(paths: paths, isDisabledOverride: false)

        first.write(level: "info", subsystem: "app", message: "first", metadata: nil)
        first.flush()
        second.write(level: "info", subsystem: "app", message: "second", metadata: nil)
        second.flush()
        first.write(level: "info", subsystem: "app", message: "third", metadata: nil)
        first.flush()

        let logURL = logs.appendingPathComponent("app.jsonl")
        let lines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(lines.count, 3)

        let messages = try lines.map { line -> String in
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(object["m"] as? String)
        }

        XCTAssertEqual(messages, ["first", "second", "third"])
    }

    func testFileLoggerRedactsSensitiveMessagesAndMetadata() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerPrivacyTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: logs
        )

        let logger = FileLogger(paths: paths, isDisabledOverride: false)
        logger.write(
            level: "error",
            subsystem: "pipeline",
            message: "Failed /Users/jane/Library/Application Support/Transcripted/captures/meetings/Customer Sync.md for person@example.com with token sk-private",
            metadata: [
                "audio_duration_s": "12.3",
                "audio": "/Users/jane/Private/raw.wav",
                "device": "Jane's AirPods Pro",
                "error": "Read /Users/jane/Private/audio.wav with Bearer abc123",
                "file": "Customer Sync.md",
                "name": "Alice Customer",
                "path": "/Users/jane/Private/Customer Sync.md",
                "profileName": "Bob Customer",
                "speakers": "3",
                "transcriptId": "recording-123",
            ]
        )
        logger.flush()

        let logURL = logs.appendingPathComponent("app.jsonl")
        let line = try XCTUnwrap(
            try String(contentsOf: logURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
                .first
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = try XCTUnwrap(object["m"] as? String)
        let metadata = try XCTUnwrap(object["d"] as? [String: String])

        XCTAssertFalse(message.contains("/Users/jane/"), "absolute paths should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("Customer Sync.md"), "meeting-derived filenames should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("person@example.com"), "emails should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("sk-private"), "tokens should not enter app.jsonl messages")
        XCTAssertTrue(message.contains("[redacted-path]"))
        XCTAssertTrue(message.contains("[redacted-email]"))

        XCTAssertEqual(metadata["audio_duration_s"], "12.3")
        XCTAssertEqual(metadata["speakers"], "3")
        XCTAssertEqual(metadata["transcriptId"], "recording-123")
        XCTAssertEqual(metadata["audio"], "[redacted-sensitive-value]")
        XCTAssertEqual(metadata["device"], "[redacted-sensitive-value]")
        XCTAssertEqual(metadata["file"], "[redacted-sensitive-value]")
        XCTAssertEqual(metadata["name"], "[redacted-sensitive-value]")
        XCTAssertEqual(metadata["path"], "[redacted-sensitive-value]")
        XCTAssertEqual(metadata["profileName"], "[redacted-sensitive-value]")
        XCTAssertFalse(metadata["error"]?.contains("/Users/jane/") == true, "metadata values should redact paths")
        XCTAssertFalse(metadata["error"]?.contains("Bearer abc123") == true, "metadata values should redact auth headers")
    }

    func testFileLoggerRedactsInlineSensitiveAssignmentsInMessages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerInlinePrivacyTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: logs
        )

        let logger = FileLogger(paths: paths, isDisabledOverride: false)
        logger.write(
            level: "warning",
            subsystem: "pipeline",
            message: "DICTATION | started (parakeet, Jane's AirPods Pro) from Janes-MacBook-Pro.local transcript_text=private roadmap words speaker_name=Alice Customer audio_path=/Users/jane/Private/customer.wav title=Customer Roadmap",
            metadata: nil
        )
        logger.flush()

        let logURL = logs.appendingPathComponent("app.jsonl")
        let line = try XCTUnwrap(
            try String(contentsOf: logURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
                .first
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = try XCTUnwrap(object["m"] as? String)

        XCTAssertFalse(message.contains("Jane's AirPods Pro"), "raw device names should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("Janes-MacBook-Pro.local"), "local hostnames should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("private roadmap words"), "transcript text should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("Alice Customer"), "speaker names should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("/Users/jane/Private/customer.wav"), "audio paths should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("Customer Roadmap"), "titles should not enter app.jsonl messages")
        XCTAssertTrue(message.contains("(parakeet, [redacted-sensitive-value])"))
        XCTAssertTrue(message.contains("[redacted-host]"))
        XCTAssertTrue(message.contains("transcript_text=[redacted-sensitive-value]"))
        XCTAssertTrue(message.contains("speaker_name=[redacted-sensitive-value]"))
        XCTAssertTrue(message.contains("audio_path=[redacted-sensitive-value]"))
        XCTAssertTrue(message.contains("title=[redacted-sensitive-value]"))
    }

    func testFileLoggerRedactsPunctuationInsideAbsolutePathMessages() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerPathPunctuationPrivacyTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: logs
        )

        let logger = FileLogger(paths: paths, isDisabledOverride: false)
        logger.write(
            level: "error",
            subsystem: "pipeline",
            message: "Failed /Users/jane/Client, Secret/meeting.md; archived /Users/jane/Decks/Customer) Roadmap/final.md status=failed",
            metadata: nil
        )
        logger.flush()

        let logURL = logs.appendingPathComponent("app.jsonl")
        let line = try XCTUnwrap(
            try String(contentsOf: logURL, encoding: .utf8)
                .split(separator: "\n")
                .map(String.init)
                .first
        )
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        let message = try XCTUnwrap(object["m"] as? String)

        XCTAssertFalse(message.contains("/Users/jane/"), "absolute paths should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("Secret/meeting.md"), "path suffix after comma should not enter app.jsonl messages")
        XCTAssertFalse(message.contains("Roadmap/final.md"), "path suffix after closing parenthesis should not enter app.jsonl messages")
        XCTAssertTrue(message.contains("[redacted-path]"))
        XCTAssertTrue(message.contains("status=failed"))
    }

    func testDisableFlagSkipsFileLogging() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerDisableTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer {
            unsetenv("TRANSCRIPTED_DISABLE_FILE_LOGGER")
            try? FileManager.default.removeItem(at: root)
        }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: logs
        )

        setenv("TRANSCRIPTED_DISABLE_FILE_LOGGER", "1", 1)

        let logger = FileLogger(paths: paths)
        logger.write(level: "info", subsystem: "app", message: "should-not-write", metadata: nil)
        logger.flush()

        let logURL = logs.appendingPathComponent("app.jsonl")
        let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.isEmpty)
    }

    func testDefaultLoggerSkipsWritesInTestProcess() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerDefaultDisableTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: logs
        )

        let logger = FileLogger(paths: paths)
        logger.write(level: "info", subsystem: "app", message: "test-process-write", metadata: nil)
        logger.flush()

        let logURL = logs.appendingPathComponent("app.jsonl")
        let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        XCTAssertTrue(content.isEmpty)
    }

    func testLoggerTrimsOversizedExistingLogOnInit() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerTrimTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = logs.appendingPathComponent("app.jsonl")
        let lines = (0..<2105).map { index in
            #"{"t":"2026-04-14T00:00:00.000Z","l":"info","s":"app","m":"line-\#(index)"}"#
        }
        try (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: logs
        )

        _ = FileLogger(paths: paths, isDisabledOverride: false)

        let trimmedLines = try String(contentsOf: logURL, encoding: .utf8)
            .split(separator: "\n")
            .map(String.init)

        XCTAssertEqual(trimmedLines.count, 1500)

        let firstObject = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(trimmedLines[0].utf8)) as? [String: Any])
        XCTAssertEqual(firstObject["m"] as? String, "line-605")
    }

    func testLoggerTrimKeepsOwnerOnlyPermissionsAfterAtomicRewrite() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileLoggerTrimPermissionsTests-\(UUID().uuidString)", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let logURL = logs.appendingPathComponent("app.jsonl")
        let lines = (0..<2105).map { index in
            #"{"t":"2026-04-14T00:00:00.000Z","l":"info","s":"app","m":"line-\#(index)"}"#
        }
        try (lines.joined(separator: "\n") + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: logURL.path)

        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: logs
        )

        _ = FileLogger(paths: paths, isDisabledOverride: false)

        let attributes = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: logURL.path) as [FileAttributeKey: Any]?)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(
            permissions,
            NSNumber(value: 0o600),
            "trimmed log should stay owner-only after the atomic rewrite path"
        )
    }
}
