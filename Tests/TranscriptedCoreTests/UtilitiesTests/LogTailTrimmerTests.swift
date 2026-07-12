import XCTest
@testable import TranscriptedCore

final class LogTailTrimmerTests: XCTestCase {
    private func makeTempFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogTailTrimmerTests-\(UUID().uuidString).log")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testMaxLinesGateSkipsTrimBelowThreshold() throws {
        let url = try makeTempFile(contents: "one\ntwo\nthree\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let didTrim = LogTailTrimmer.trimIfNeeded(
            at: url.path,
            maxLines: 10,
            keepLines: 2,
            filterEmptyLines: true,
            appendsTrailingNewline: true
        )

        XCTAssertFalse(didTrim)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\nthree\n")
    }

    func testMaxLinesGateTrimsToKeepLinesWithTrailingNewline() throws {
        let lines = (0..<10).map { "line-\($0)" }
        let url = try makeTempFile(contents: lines.joined(separator: "\n") + "\n")
        defer { try? FileManager.default.removeItem(at: url) }

        let didTrim = LogTailTrimmer.trimIfNeeded(
            at: url.path,
            maxLines: 5,
            keepLines: 3,
            filterEmptyLines: true,
            appendsTrailingNewline: true
        )

        XCTAssertTrue(didTrim)
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "line-7\nline-8\nline-9\n")
    }

    func testNilMaxLinesAlwaysTrimsForCallersThatAlreadyGated() throws {
        // No trailing newline, matching AppLogSink's on-disk shape (see the
        // next test): a trailing "\n" would split into a trailing empty
        // "line" that a naive suffix() would keep instead of "b".
        let url = try makeTempFile(contents: "a\nb")
        defer { try? FileManager.default.removeItem(at: url) }

        let didTrim = LogTailTrimmer.trimIfNeeded(
            at: url.path,
            maxLines: nil,
            keepLines: 1,
            filterEmptyLines: false,
            appendsTrailingNewline: false
        )

        XCTAssertTrue(didTrim, "a nil maxLines gate always trims — the caller already decided trimming was needed")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "b")
    }

    func testNoTrailingNewlineAndNoEmptyLineFilterMatchesAppLogSinkShape() throws {
        // AppLogSink's on-disk debug log has no trailing newline convention and
        // does not filter blank lines — mirror that shape here.
        let url = try makeTempFile(contents: "a\n\nb\nc")
        defer { try? FileManager.default.removeItem(at: url) }

        let didTrim = LogTailTrimmer.trimIfNeeded(
            at: url.path,
            maxLines: nil,
            keepLines: 3,
            filterEmptyLines: false,
            appendsTrailingNewline: false
        )

        XCTAssertTrue(didTrim)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "\nb\nc")
    }

    func testMissingFileIsANoOp() {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogTailTrimmerTests-missing-\(UUID().uuidString).log")
            .path

        let didTrim = LogTailTrimmer.trimIfNeeded(
            at: missingPath,
            maxLines: 1,
            keepLines: 1,
            filterEmptyLines: true,
            appendsTrailingNewline: true
        )

        XCTAssertFalse(didTrim)
    }

    func testRestrictsPermissionsToOwnerOnlyAfterRewrite() throws {
        let url = try makeTempFile(contents: "a\nb\nc\n")
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: url.path)
        defer { try? FileManager.default.removeItem(at: url) }

        let didTrim = LogTailTrimmer.trimIfNeeded(
            at: url.path,
            maxLines: nil,
            keepLines: 1,
            filterEmptyLines: true,
            appendsTrailingNewline: true
        )

        XCTAssertTrue(didTrim)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = try XCTUnwrap(attributes[.posixPermissions] as? NSNumber)
        XCTAssertEqual(permissions, NSNumber(value: 0o600))
    }
}
