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
}
