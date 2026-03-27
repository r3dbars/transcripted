import XCTest
@testable import Transcripted

final class ModelDownloadServiceSecurityTests: XCTestCase {

    // MARK: - isSafeModelFilename — Valid Filenames

    func testValidSimpleFilename() {
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("model.bin"))
    }

    func testValidJsonFilename() {
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("config.json"))
    }

    func testValidSubfolderFilename() {
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("subfolder/weights.safetensors"))
    }

    func testValidFilenameWithSpaces() {
        XCTAssertTrue(ModelDownloadService.isSafeModelFilename("my model weights.bin"))
    }

    // MARK: - isSafeModelFilename — Path Traversal

    func testRejectsParentDirectoryTraversal() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("../../etc/passwd"))
    }

    func testRejectsSshKeyTraversal() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("../.ssh/keys"))
    }

    func testRejectsNestedTraversal() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("models/../../../secret"))
    }

    // MARK: - isSafeModelFilename — Absolute Paths

    func testRejectsAbsolutePathEtcPasswd() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("/etc/passwd"))
    }

    func testRejectsAbsolutePathTmp() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("/tmp/evil"))
    }

    // MARK: - isSafeModelFilename — Dot Components

    func testRejectsSingleDotComponent() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename("."))
    }

    func testRejectsDoubleDotComponent() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename(".."))
    }

    // MARK: - isSafeModelFilename — Control Characters

    func testRejectsNullByte() {
        let nameWithNull = "model\0.bin"
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename(nameWithNull))
    }

    func testRejectsTabCharacter() {
        let nameWithTab = "model\t.bin"
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename(nameWithTab))
    }

    // MARK: - isSafeModelFilename — Empty String

    func testRejectsEmptyString() {
        XCTAssertFalse(ModelDownloadService.isSafeModelFilename(""))
    }
}
