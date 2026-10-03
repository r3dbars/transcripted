import XCTest
@testable import transcripted_mcp

/// Repeated enumerations reuse a cached artifact kind. These pin that the
/// cache never changes what enumerateArtifacts (and so reconcile) returns.
final class ArtifactKindCacheTests: XCTestCase {
    private var root: URL!
    private var library: URL!

    override func setUp() {
        super.setUp()
        root = makeTempDir()
        library = root.appendingPathComponent("library", isDirectory: true)
        try? FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    }

    override func tearDown() {
        removeTempDir(root)
        super.tearDown()
    }

    private func kinds(_ dir: URL) -> [String: ContextArtifactKind] {
        var result: [String: ContextArtifactKind] = [:]
        for file in TranscriptLoader.enumerateArtifacts(in: dir) {
            result[file.url.lastPathComponent] = file.kind
        }
        return result
    }

    func testRepeatedEnumerationKeepsEveryKind() throws {
        try writeFixture(makeFixtureJSON(), filename: "Call_2026-03-29_10-00-00", to: library)
        try writeFixture(makeDictationDayJSON(), filename: "Dictations_2026-04-07", to: library)
        try writeFixture(makeWritingDayMarkdown(), filename: "Writing_2026-09-25", to: library)
        try "# just notes\n".write(to: library.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8)

        let expected: [String: ContextArtifactKind] = [
            "Call_2026-03-29_10-00-00.md": .meeting,
            "Dictations_2026-04-07.md": .dictationDay,
            "Writing_2026-09-25.md": .writingDay,
        ]
        XCTAssertEqual(kinds(library), expected)
        XCTAssertEqual(kinds(library), expected)

        try FileManager.default.removeItem(at: library.appendingPathComponent("Writing_2026-09-25.md"))
        XCTAssertEqual(kinds(library), expected.filter { $0.key != "Writing_2026-09-25.md" })
    }

    func testSameSizeRewriteWithoutFrontmatterAndRestoredMtimeDropsTheFile() throws {
        let filename = "Call_2026-03-29_10-00-00"
        let url = library.appendingPathComponent("\(filename).md")
        try writeFixture(makeFixtureJSON(), filename: filename, to: library)
        let index = try TranscriptIndex(indexDir: root.appendingPathComponent("index", isDirectory: true).creatingDirectory())
        try index.reconcile(meetingsDir: library, dictationsDir: library)
        XCTAssertEqual(kinds(library)["\(filename).md"], .meeting)
        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 1)

        // Overwrite in place (same inode, same size) so the opening fence is
        // gone, then put the old mtime back.
        let originalMtime = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        )
        let original = try Data(contentsOf: url)
        var rewritten = original
        rewritten.replaceSubrange(0..<4, with: Data("xxx\n".utf8))
        XCTAssertEqual(rewritten.count, original.count)
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: rewritten)
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: originalMtime], ofItemAtPath: url.path)

        XCTAssertNil(kinds(library)["\(filename).md"])
        try index.reconcile(meetingsDir: library, dictationsDir: library)
        XCTAssertEqual(try index.listRecentMeetings(count: 10).count, 0)
    }

    func testSwappingACachedFileForASymlinkExcludesIt() throws {
        let filename = "Call_2026-03-29_10-00-00"
        let url = library.appendingPathComponent("\(filename).md")
        try writeFixture(makeFixtureJSON(), filename: filename, to: library)
        XCTAssertEqual(kinds(library)["\(filename).md"], .meeting)

        let outside = root.appendingPathComponent("outside", isDirectory: true).creatingDirectory()
        try writeFixture(makeFixtureJSON(), filename: filename, to: outside)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(
            at: url,
            withDestinationURL: outside.appendingPathComponent("\(filename).md")
        )

        XCTAssertNil(kinds(library)["\(filename).md"])
    }
}

private extension URL {
    func creatingDirectory() -> URL {
        try? FileManager.default.createDirectory(at: self, withIntermediateDirectories: true)
        return self
    }
}
