import XCTest
@testable import TranscriptedCore

final class ClipRemovalPolicyTests: XCTestCase {
    func testRemovingAMissingClipCountsAsAlreadyGone() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-clip-\(UUID().uuidString).wav")
        do {
            try FileManager.default.removeItem(at: missing)
            XCTFail("removing a file that does not exist should throw")
        } catch {
            XCTAssertTrue(
                ClipRemovalPolicy.isAlreadyGone(error),
                "a speaker's first clip save must not log a removal warning"
            )
        }
    }

    func testRealRemovalFailuresStillWarn() {
        let permissionDenied = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError
        )
        XCTAssertFalse(ClipRemovalPolicy.isAlreadyGone(permissionDenied))
    }

    func testMissingFileWrappedAsUnderlyingErrorCountsAsAlreadyGone() {
        let wrapped = NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteUnknownError,
            userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))]
        )
        XCTAssertTrue(ClipRemovalPolicy.isAlreadyGone(wrapped))
    }
}
