import Foundation
import XCTest
@testable import transcripted_cli

final class ContextChronologyTests: XCTestCase {
    func testMixedFeedsSortInstantsBeforeApplyingCountAcrossTimeZones() throws {
        for (hours, clock, expected) in [
            (-5, "09:15:00", ["meeting", "writing", "dictation"]),
            (5, "13:15:00", ["writing", "dictation", "meeting"]),
            (0, "09:15:00", ["writing", "dictation", "meeting"]),
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let directories = CLIContextDirectories(meetingsDir: root, dictationsDir: root, writingDir: root)
            let meeting = """
            ---
            capture_type: meeting
            title: Fixture meeting
            date: 2026-04-07
            time: \(clock)
            ---

            ## Full Transcript

            [00:00] [Mic/You] Fixture words.
            """
            try meeting.write(to: root.appendingPathComponent("Meeting.md"), atomically: true, encoding: .utf8)
            try day(kind: "dictation", captured: "2026-04-07T10:00:00Z")
                .write(to: root.appendingPathComponent("Dictations_2026-04-07.md"), atomically: true, encoding: .utf8)
            try day(kind: "writing", captured: "2026-04-07T11:00:00.000Z")
                .write(to: root.appendingPathComponent("Writing_2026-04-07.md"), atomically: true, encoding: .utf8)
            let zone = try XCTUnwrap(TimeZone(secondsFromGMT: hours * 3600))

            let recent = CLIContextStore.recent(in: directories, kind: .all, count: 3, dateFrom: nil, dateTo: nil, timeZone: zone)
            let search = CLIContextStore.search(query: "fixture", speaker: nil, in: directories, kind: .all, count: 3, dateFrom: nil, dateTo: nil, timeZone: zone)
            XCTAssertEqual(recent.map(\.kind.rawValue), expected)
            XCTAssertEqual(search.map(\.kind.rawValue), expected)
            XCTAssertEqual(recent.first(where: { $0.kind == .meeting })?.datetime, "2026-04-07T\(clock)")
            XCTAssertEqual(recent.first(where: { $0.kind == .dictation })?.datetime, "2026-04-07T10:00:00Z")
            XCTAssertEqual(CLIContextStore.recent(in: directories, kind: .all, count: 1, dateFrom: nil, dateTo: nil, timeZone: zone).map(\.kind.rawValue), Array(expected.prefix(1)))
            XCTAssertEqual(CLIContextStore.search(query: "fixture", speaker: nil, in: directories, kind: .all, count: 1, dateFrom: nil, dateTo: nil, timeZone: zone).map(\.kind.rawValue), Array(expected.prefix(1)))
        }
    }

    func testEqualInstantsKeepExistingFeedOrder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directories = CLIContextDirectories(meetingsDir: root, dictationsDir: root, writingDir: root)
        try """
        ---
        capture_type: meeting
        title: Fixture meeting
        date: 2026-04-07
        time: 09:15:00
        ---

        ## Full Transcript

        [00:00] [Mic/You] Fixture words.
        """.write(to: root.appendingPathComponent("Meeting.md"), atomically: true, encoding: .utf8)
        try day(kind: "dictation", captured: "2026-04-07T14:15:00Z")
            .write(to: root.appendingPathComponent("Dictations_2026-04-07.md"), atomically: true, encoding: .utf8)
        try day(kind: "writing", captured: "2026-04-07T14:15:00.000Z")
            .write(to: root.appendingPathComponent("Writing_2026-04-07.md"), atomically: true, encoding: .utf8)
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: -5 * 3600))
        let expected = ["meeting", "dictation", "writing"]
        XCTAssertEqual(CLIContextStore.recent(in: directories, kind: .all, count: 3, dateFrom: nil, dateTo: nil, timeZone: zone).map(\.kind.rawValue), expected)
        XCTAssertEqual(CLIContextStore.search(query: "fixture", speaker: nil, in: directories, kind: .all, count: 3, dateFrom: nil, dateTo: nil, timeZone: zone).map(\.kind.rawValue), expected)
    }

    func testParserUnderstandsFractionalAndCompactOffsetStamps() throws {
        let parser = CLIContextInstantParser(timeZone: try XCTUnwrap(TimeZone(secondsFromGMT: -5 * 3600)))
        let instant = try XCTUnwrap(parser.date(from: "2026-04-07T14:15:00Z"))
        for value in ["2026-04-07T09:15:00", "2026-04-07T09:15", "2026-04-07T09:15:00-0500", "2026-04-07T14:15:00.000Z"] {
            XCTAssertEqual(parser.date(from: value), instant)
        }
        XCTAssertNil(parser.date(from: "not a timestamp"))
    }

    private func day(kind: String, captured: String) -> String {
        """
        ---
        capture_type: \(kind)_day
        date: 2026-04-07
        ---

        ## 10:00 AM - Fixture note

        Entry ID: `\(kind)-fixture`
        Captured: \(captured)
        Source app: Notes
        Words: 2

        Fixture words.
        """
    }
}
