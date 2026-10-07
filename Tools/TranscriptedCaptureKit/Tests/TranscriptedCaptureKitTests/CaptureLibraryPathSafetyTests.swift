import XCTest
@testable import TranscriptedCaptureKit

/// Pins the save-path safety rule. The same source file is compiled into the app,
/// TranscriptedCore, and this package (see the file header), so one behavioral test
/// here covers all three.
final class CaptureLibraryPathSafetyTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)

    func testPathUnderHomeIsSafe() {
        let url = home.appendingPathComponent("Documents/Transcripts", isDirectory: true)
        XCTAssertEqual(CaptureLibraryPathSafety.evaluate(url, homeDirectory: home), .safe)
        XCTAssertTrue(CaptureLibraryPathSafety.isSafe(url, homeDirectory: home))
    }

    func testNonFileURLsAreRejected() {
        XCTAssertEqual(
            CaptureLibraryPathSafety.evaluate(URL(string: "https://example.com/a")!, homeDirectory: home),
            .notAbsolutePath
        )
    }

    func testParentTraversalIsRejectedBeforeNormalization() {
        let url = URL(fileURLWithPath: "/Users/someone/Documents/../../other")
        XCTAssertEqual(CaptureLibraryPathSafety.evaluate(url, homeDirectory: home), .containsParentTraversal)
    }

    func testRootIsRejected() {
        XCTAssertEqual(
            CaptureLibraryPathSafety.evaluate(URL(fileURLWithPath: "/"), homeDirectory: home),
            .isRootPath
        )
    }

    func testSystemDirectoriesAreRejectedByPrefix() {
        for prefix in ["/System", "/usr", "/bin", "/sbin"] {
            let url = URL(fileURLWithPath: prefix + "/captures", isDirectory: true)
            XCTAssertEqual(
                CaptureLibraryPathSafety.evaluate(url, homeDirectory: home),
                .forbiddenSystemPath(prefix),
                "\(prefix) should be forbidden"
            )
        }
        XCTAssertFalse(CaptureLibraryPathSafety.isSafe(URL(fileURLWithPath: "/System"), homeDirectory: home))
    }

    func testForbiddenPrefixIsAllowedWhenItIsTheResolvedHome() {
        // A home that resolves under /private (e.g. a /var-based temp home) must stay usable.
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("path-safety-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempHome, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let inside = tempHome.appendingPathComponent("captures", isDirectory: true)
        XCTAssertEqual(CaptureLibraryPathSafety.evaluate(inside, homeDirectory: tempHome), .safe)
    }
}
