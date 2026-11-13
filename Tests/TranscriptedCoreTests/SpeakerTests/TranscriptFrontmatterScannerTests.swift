import Foundation
import XCTest
@testable import TranscriptedCore

// Contract-authored before reading the scanner implementation.
final class TranscriptFrontmatterScannerTests: XCTestCase {
    private let chunkBytes = 64 * 1024
    private let capBytes = 1024 * 1024

    func testAnyQueryPositionCanMatchTheHeader() throws {
        try withOwnedDirectory { root in
            let url = try write(Data("---\nspeaker: owned-identity\n---\nBody\n".utf8), in: root)
            for queries in [
                ["owned-identity", "absent-a", "absent-b"],
                ["absent-a", "owned-identity", "absent-b"],
                ["absent-a", "absent-b", "owned-identity"],
            ] {
                assertScan(.matched, at: url, for: queries)
            }
        }
    }

    func testAClosedHeaderWithoutAnyQueryReturnsNotMatched() throws {
        try withOwnedDirectory { root in
            let url = try write(Data("---\nspeaker: another-identity\n---\nBody\n".utf8), in: root)
            assertScan(.notMatched, at: url, for: ["absent-a", "absent-b", "absent-c"])
        }
    }

    func testBodyOnlyQueriesAfterTheFirstClosingFenceNeverMatch() throws {
        try withOwnedDirectory { root in
            let url = try write(Data("---\nspeaker: header-only\n---\nbody-identity\n---\nsecond-fence-identity\n---\n".utf8), in: root)
            assertScan(.notMatched, at: url, for: ["body-identity", "second-fence-identity"])
        }
    }

    func testNeedlesAreLiteralRatherThanRegularExpressions() throws {
        try withOwnedDirectory { root in
            let url = try write(Data("---\nspeaker: alpha-123\ntag: literal[brackets]\n---\n".utf8), in: root)
            assertScan(.notMatched, at: url, for: ["alpha-.*", "^speaker:", "literal.*"])
            assertScan(.matched, at: url, for: ["literal[brackets]"])
        }
    }

    func testMissingOrMalformedHeaderRequiresFullReadEvenWithAnEarlyQuery() throws {
        try withOwnedDirectory { root in
            let malformed: [Data] = [
                Data(),
                Data("speaker: target\n---\nBody\n".utf8),
                Data("preamble\n---\nspeaker: target\n---\n".utf8),
                Data("---\r\nspeaker: target\r\n---\r\n".utf8),
                Data("---\nspeaker: target\n".utf8),
                Data("---\nspeaker: target\n--\nBody\n".utf8),
                // The closing search begins after the four opening bytes.
                Data("---\n---\nBody\n".utf8),
            ]
            for (index, bytes) in malformed.enumerated() {
                let url = try write(bytes, in: root, name: "malformed-\(index).md")
                assertScan(.needsFullRead, at: url, for: ["target"])
            }
        }
    }

    func testInvalidHeaderBytesPreserveLiteralByteMatching() throws {
        try withOwnedDirectory { root in
            var bytes = Data("---\nspeaker: ".utf8)
            bytes.append(contentsOf: [0xff, 0xfe])
            bytes.append(Data(" target-identity\n---\nBody\n".utf8))
            let url = try write(bytes, in: root)
            assertScan(.matched, at: url, for: ["target-identity"])
            assertScan(.notMatched, at: url, for: ["absent"])
        }
    }

    func testInvalidBodyBytesCannotInvalidateAClosedHeader() throws {
        try withOwnedDirectory { root in
            var bytes = Data("---\nspeaker: header-identity\n---\n".utf8)
            bytes.append(contentsOf: [0xff, 0xfe])
            let url = try write(bytes, in: root)
            assertScan(.matched, at: url, for: ["header-identity"])
            assertScan(.notMatched, at: url, for: ["absent"])
        }
    }

    func testNonexistentOwnedFileRequiresFullRead() throws {
        try withOwnedDirectory { root in
            let missing = root.appendingPathComponent("never-created.md")
            assertScan(.needsFullRead, at: missing, for: ["target"])
        }
    }

    func testDirectoryInputRequiresFullRead() throws {
        try withOwnedDirectory { root in
            assertScan(.needsFullRead, at: root, for: ["target"])
        }
    }

    func testUnicodeNeedleSplitAcrossAReadChunkStillMatches() throws {
        try withOwnedDirectory { root in
            let needle = "会議-🧭-café"
            var bytes = Data("---\nspeaker: ".utf8)
            bytes.append(Data(repeating: 0x78, count: chunkBytes - 1 - bytes.count))
            // The first multibyte scalar begins at the final byte of a chunk.
            bytes.append(Data(needle.utf8))
            bytes.append(Data("\n---\nBody\n".utf8))
            let url = try write(bytes, in: root)
            assertScan(.matched, at: url, for: ["absent-a", needle, "absent-b"])
        }
    }

    func testClosingFenceSplitAcrossAChunkStillExcludesTheBody() throws {
        try withOwnedDirectory { root in
            let headerNeedle = "🧭-会議-café"
            var bytes = Data("---\nspeaker: \(headerNeedle)\npadding: ".utf8)
            bytes.append(Data(repeating: 0x78, count: chunkBytes - 2 - bytes.count))
            bytes.append(Data("\n---\nbody-only-identity\n".utf8))
            let url = try write(bytes, in: root)
            assertScan(.matched, at: url, for: [headerNeedle])
            assertScan(.notMatched, at: url, for: ["body-only-identity"])
        }
    }

    func testAHeaderClosingExactlyAtTheCapCanMatchDespiteALargeBody() throws {
        try withOwnedDirectory { root in
            let closing = Data("\n---\n".utf8)
            var bytes = Data("---\nspeaker: cap-identity\npadding: ".utf8)
            bytes.append(Data(repeating: 0x78, count: capBytes - closing.count - bytes.count))
            bytes.append(closing)
            bytes.append(Data(repeating: 0x62, count: capBytes))
            let url = try write(bytes, in: root)
            assertScan(.matched, at: url, for: ["cap-identity"])
            assertScan(.notMatched, at: url, for: ["absent"])
        }
    }

    func testHeaderNotClosedWithinTheCapRequiresFullRead() throws {
        try withOwnedDirectory { root in
            var bytes = Data("---\npadding: ".utf8)
            bytes.append(Data(repeating: 0x78, count: capBytes + 16 - bytes.count))
            bytes.append(Data("\nspeaker: beyond-cap-identity\n---\n".utf8))
            let url = try write(bytes, in: root)
            assertScan(.needsFullRead, at: url, for: ["beyond-cap-identity"])
            assertScan(.needsFullRead, at: url, for: ["absent"])
        }
    }

    func testEmptyQueryListReturnsNotMatchedForANonexistentOwnedFile() throws {
        try withOwnedDirectory { root in
            let missing = root.appendingPathComponent("never-created.md")
            assertScan(.notMatched, at: missing, for: [])
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }

    private enum Expected: String { case matched, notMatched, needsFullRead }

    private func assertScan(_ expected: Expected, at url: URL, for needles: [String],
                            file: StaticString = #filePath, line: UInt = #line) {
        let observed: Expected
        switch TranscriptFrontmatterScanner.scan(at: url, for: needles) {
        case .matched: observed = .matched
        case .notMatched: observed = .notMatched
        case .needsFullRead: observed = .needsFullRead
        }
        XCTAssertEqual(observed, expected, file: file, line: line)
    }

    private func write(_ data: Data, in root: URL, name: String = "fixture.md") throws -> URL {
        let url = root.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func withOwnedDirectory(_ body: (URL) throws -> Void,
                                    file: StaticString = #filePath, line: UInt = #line) throws {
        let manager = FileManager.default
        let parent = manager.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = parent.appendingPathComponent("core-speaker11-test-" + UUID().uuidString,
                                                isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        defer { removeOwnedDirectory(root, parent: parent, file: file, line: line) }
        try body(root)
    }

    private func removeOwnedDirectory(_ root: URL, parent: URL,
                                      file: StaticString, line: UInt) {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        guard canonical == root.standardizedFileURL,
              canonical.deletingLastPathComponent() == parent,
              canonical.lastPathComponent.hasPrefix("core-speaker11-test-") else {
            XCTFail("Refusing cleanup outside the exact owned test directory", file: file, line: line)
            return
        }
        do { try FileManager.default.removeItem(at: canonical) }
        catch { XCTFail("Owned test directory cleanup failed", file: file, line: line) }
    }
}
