import XCTest
@testable import TranscriptedCore

final class FileLoggerControlCharacterTests: XCTestCase {
    func testAllControlCharactersRoundTripInEveryJSONField() throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.resolvingSymlinksInPath()
        let leaf = "FileLoggerControlCharacters-" + UUID().uuidString
        let root = parent.appendingPathComponent(leaf, isDirectory: true)
        defer {
            let resolved = root.resolvingSymlinksInPath()
            if resolved.deletingLastPathComponent() == parent,
               resolved.lastPathComponent == leaf {
                do { try manager.removeItem(at: resolved) }
                catch { XCTFail("Could not remove the owned logging fixture") }
            } else { XCTFail("Logging fixture escaped its owned root") }
        }
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("meetings"),
            speakerDB: root.appendingPathComponent("speakers.sqlite"),
            statsDB: root.appendingPathComponent("stats.sqlite"),
            failedQueue: root.appendingPathComponent("failed.json"),
            speakerClips: root.appendingPathComponent("clips"),
            audioCaptures: root.appendingPathComponent("audio"), logs: logs
        )
        let values = (0..<32).map { "prefix" + String(UnicodeScalar($0)!) + "\\\" café 🦊 suffix" }
        // Explicitly synthetic, already-sanitized input tests JSON encoding
        // independently of the separate privacy redactor contract.
        do {
            let logger = FileLogger(paths: paths, isDisabledOverride: false)
            for value in values {
                logger.writeSanitized(level: value, subsystem: value, message: value,
                                      metadata: [value: value])
            }
            logger.flush()
        }
        let bytes = try Data(contentsOf: logs.appendingPathComponent("app.jsonl"))
        let rows = bytes.split(separator: 0x0a)
        XCTAssertEqual(rows.count, values.count, "One complete JSON object per write")
        for (row, expected) in zip(rows, values) {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(row)) as? [String: Any])
            XCTAssertEqual(object["l"] as? String, expected)
            XCTAssertEqual(object["s"] as? String, expected)
            XCTAssertEqual(object["m"] as? String, expected)
            XCTAssertEqual(object["d"] as? [String: String], [expected: expected])
        }
    }
}
