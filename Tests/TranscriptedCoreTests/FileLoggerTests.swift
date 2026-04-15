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
}
