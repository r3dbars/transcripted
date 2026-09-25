import Foundation
import XCTest
@testable import TranscriptedCore

final class TranscriptFileRewriteTests: XCTestCase {
    private var temporaryDirectory: URL!
    private let oldDate = Date(timeIntervalSince1970: 1_767_225_600) // 2026-01-01

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptFileRewriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
        super.tearDown()
    }

    func testIdenticalContentSkipsWriteAndKeepsBothDates() throws {
        let url = try savedTranscript(named: "same.md", content: "---\ntitle: \"Standup\"\n---\n\nHello\n")

        let outcome = try TranscriptFileRewrite.write("---\ntitle: \"Standup\"\n---\n\nHello\n", to: url)

        XCTAssertEqual(outcome, .unchanged)
        let dates = try fileDates(url)
        XCTAssertEqual(dates.created.timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(dates.modified.timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 1)
    }

    func testChangedContentKeepsCreationDateAndMovesModificationDate() throws {
        let url = try savedTranscript(named: "changed.md", content: "[System/Speaker 1] hi\n")

        let outcome = try TranscriptFileRewrite.write("[System/Dana] hi\n", to: url)

        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "[System/Dana] hi\n")
        let dates = try fileDates(url)
        XCTAssertEqual(dates.created.timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 1)
        // A real edit must still bump Modified: the MCP index and Home's cache use it.
        XCTAssertGreaterThan(dates.modified.timeIntervalSince1970, oldDate.timeIntervalSince1970 + 60)
    }

    func testDataOverloadSkipsIdenticalBytes() throws {
        let url = try savedTranscript(named: "data.md", content: "same bytes\n")

        let outcome = try TranscriptFileRewrite.write(Data("same bytes\n".utf8), to: url)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(try fileDates(url).modified.timeIntervalSince1970, oldDate.timeIntervalSince1970, accuracy: 1)
    }

    func testMissingFileIsCreated() throws {
        let url = temporaryDirectory.appendingPathComponent("new.md")

        let outcome = try TranscriptFileRewrite.write("fresh\n", to: url)

        XCTAssertEqual(outcome, .written)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "fresh\n")
    }

    private func savedTranscript(named name: String, content: String) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try content.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.creationDate: oldDate, .modificationDate: oldDate],
            ofItemAtPath: url.path
        )
        return url
    }

    private func fileDates(_ url: URL) throws -> (created: Date, modified: Date) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (
            try XCTUnwrap(attributes[.creationDate] as? Date),
            try XCTUnwrap(attributes[.modificationDate] as? Date)
        )
    }
}
