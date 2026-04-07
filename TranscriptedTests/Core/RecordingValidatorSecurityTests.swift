import XCTest
@testable import Transcripted
@testable import TranscriptedCore

final class RecordingValidatorSecurityTests: XCTestCase {

    // MARK: - Path Traversal

    func testRejectsPathTraversalToSystemDir() {
        // Path that traverses into /usr (which is in forbiddenPrefixes)
        let url = URL(fileURLWithPath: "/Users/test/../../../usr/bin/evil")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertFalse(result.isValid, "Path traversal into /usr should be rejected")
    }

    func testRejectsPathTraversalToLibrary() {
        let url = URL(fileURLWithPath: "/Users/test/../../Library/evil")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertFalse(result.isValid, "Path traversal into /Library should be rejected")
    }

    // MARK: - System Directories

    func testRejectsSystemDirectory() {
        let url = URL(fileURLWithPath: "/System/Library/Fonts")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertFalse(result.isValid, "/System should be rejected")
        XCTAssertNotNil(result.errorMessage)
    }

    func testRejectsLibraryDirectory() {
        let url = URL(fileURLWithPath: "/Library/Application Support")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertFalse(result.isValid, "/Library should be rejected")
    }

    func testRejectsUsrDirectory() {
        let url = URL(fileURLWithPath: "/usr/local/bin")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertFalse(result.isValid, "/usr should be rejected")
    }

    func testRejectsBinDirectory() {
        let url = URL(fileURLWithPath: "/bin/sh")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertFalse(result.isValid, "/bin should be rejected")
    }

    func testRejectsSbinDirectory() {
        let url = URL(fileURLWithPath: "/sbin/mount")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertFalse(result.isValid, "/sbin should be rejected")
    }

    func testPrivateResolvesToVar() {
        // On macOS, /private/var always resolves to /var via symlink.
        // The validator resolves symlinks first, so /private/var/db -> /var/db.
        // /var is not in forbiddenPrefixes, so the path is accepted.
        // This means the /private prefix in forbiddenPrefixes is effectively dead
        // code on macOS because it always resolves away.
        let url = URL(fileURLWithPath: "/private/var/db")
        let resolved = url.resolvingSymlinksInPath().path
        XCTAssertEqual(resolved, "/var/db")

        let result = RecordingValidator.validateSavePath(url)
        XCTAssertTrue(result.isValid, "/private/var/db resolves to /var/db which is not forbidden")
    }

    // MARK: - Symlinks to System Directories

    func testRejectsSymlinkToSystemDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let symlinkURL = tempDir.appendingPathComponent("test_symlink_\(UUID().uuidString)")

        // Create a symlink pointing to /System
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: URL(fileURLWithPath: "/System")
        )

        defer {
            try? FileManager.default.removeItem(at: symlinkURL)
        }

        let result = RecordingValidator.validateSavePath(symlinkURL)
        XCTAssertFalse(result.isValid, "Symlink to /System should be rejected after resolution")
    }

    // MARK: - Valid User Paths

    func testAcceptsDocumentsSubdirectory() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Documents/Transcripted")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertTrue(result.isValid, "~/Documents/Transcripted should be accepted")
    }

    func testAcceptsTempDirectory() {
        // On macOS, NSTemporaryDirectory() is /var/folders/... which is a symlink
        // from /private/var/folders/... The validator resolves symlinks first, so
        // /private/var/... -> /var/..., which is not under any forbidden prefix.
        let url = FileManager.default.temporaryDirectory
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertTrue(result.isValid, "Temp dir resolves to /var/folders/... which is not forbidden")
    }

    func testAcceptsUserDesktop() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Desktop")
        let result = RecordingValidator.validateSavePath(url)
        XCTAssertTrue(result.isValid, "~/Desktop should be accepted")
    }
}
