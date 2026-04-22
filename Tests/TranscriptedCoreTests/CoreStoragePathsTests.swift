import XCTest
@testable import TranscriptedCore

/// Smoke tests for the public Core API — verifies that `import TranscriptedCore`
/// produces a linkable test binary and that the Step 7 / Step 8 seams work as
/// documented. Heavier logic-level tests still live in the app-target
/// `TranscriptedTests/` directory until Step 10 rewires the Xcode app target.
@available(macOS 14.0, *)
final class CoreStoragePathsTests: XCTestCase {

    func testDefaultLayoutIsSelfConsistent() {
        let paths = CoreStoragePaths.default

        let appRoot = paths.transcripts
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        XCTAssertEqual(paths.transcripts.path, appRoot.appendingPathComponent("captures/meetings").path)
        XCTAssertEqual(paths.speakerDB.path, appRoot.appendingPathComponent("state/speakers.sqlite").path)
        XCTAssertEqual(paths.statsDB.path, appRoot.appendingPathComponent("state/stats.sqlite").path)
        XCTAssertEqual(paths.failedQueue.path, appRoot.appendingPathComponent("state/failed_transcriptions.json").path)
        XCTAssertEqual(paths.audioCaptures.path, appRoot.appendingPathComponent("tmp/recordings").path)
        XCTAssertEqual(paths.speakerClips.path, appRoot.appendingPathComponent("tmp/recordings/speaker_clips").path)
        XCTAssertEqual(paths.logs.path, appRoot.appendingPathComponent("logs").path)

        XCTAssertEqual(paths.speakerDB.lastPathComponent, "speakers.sqlite")
        XCTAssertEqual(paths.statsDB.lastPathComponent, "stats.sqlite")
        XCTAssertEqual(paths.failedQueue.lastPathComponent, "failed_transcriptions.json")
        XCTAssertEqual(paths.speakerClips.lastPathComponent, "speaker_clips")
        XCTAssertEqual(paths.transcripts.deletingLastPathComponent().lastPathComponent, "captures")
    }

    func testCustomLayoutHonorsFields() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptedCoreTests-\(UUID().uuidString)")
        let custom = CoreStoragePaths(
            transcripts: root.appendingPathComponent("t"),
            speakerDB: root.appendingPathComponent("s.sqlite"),
            statsDB: root.appendingPathComponent("st.sqlite"),
            failedQueue: root.appendingPathComponent("fq.json"),
            speakerClips: root.appendingPathComponent("clips"),
            audioCaptures: root.appendingPathComponent("caps"),
            logs: root.appendingPathComponent("logs")
        )

        XCTAssertEqual(custom.transcripts, root.appendingPathComponent("t"))
        XCTAssertEqual(custom.speakerDB, root.appendingPathComponent("s.sqlite"))
        XCTAssertEqual(custom.audioCaptures, root.appendingPathComponent("caps"))
    }

    func testModelBundleProviderDefaultIsNilOutsideAppBundle() {
        // When running under `swift test`, Bundle.main is the xctest harness and does not
        // contain the diarization models directory, so the default provider should
        // cleanly return nil (NOT crash) — that's the signal DiarizationService uses
        // to fall through to HuggingFace download.
        let resolved = defaultModelBundleProvider("offline-diarizer-models")
        XCTAssertNil(resolved)
    }

    func testRecordingValidatorRejectsParentTraversal() {
        let evil = URL(fileURLWithPath: "/Users/someone/../../etc/passwd")
        let result = RecordingValidator.validateSavePath(evil)
        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errorMessage, "Save path cannot contain '..' components")
    }

    func testRecordingValidatorRejectsSystemPaths() {
        let systemPath = URL(fileURLWithPath: "/System/Library/Transcripted")
        let result = RecordingValidator.validateSavePath(systemPath)
        XCTAssertFalse(result.isValid)
        XCTAssertNotNil(result.errorMessage)
    }

    func testRecordingValidatorAllowsCustomUserPathOutsideDefaultRoots() {
        let customPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("TranscriptedCustomCaptureRoot", isDirectory: true)
        let result = RecordingValidator.validateSavePath(customPath)
        XCTAssertTrue(result.isValid)
    }

    func testRecordingValidatorAllowsDocumentsTranscriptedSubdirectory() {
        let allowedPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent("Transcripted", isDirectory: true)
            .appendingPathComponent("Exports", isDirectory: true)
        let result = RecordingValidator.validateSavePath(allowedPath)
        XCTAssertTrue(result.isValid)
    }

    func testRecordingValidatorDiskSpaceProbeFallsBackToExistingParent() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let missingLeaf = tempRoot
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("transcripts", isDirectory: true)

        let probeURL = RecordingValidator.diskSpaceProbeURL(for: missingLeaf)

        XCTAssertEqual(probeURL, tempRoot)
    }

    func testRecordingValidatorDiskSpaceProbePreservesExistingPath() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecordingValidatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let probeURL = RecordingValidator.diskSpaceProbeURL(for: tempRoot)

        XCTAssertEqual(probeURL, tempRoot)
    }
}
