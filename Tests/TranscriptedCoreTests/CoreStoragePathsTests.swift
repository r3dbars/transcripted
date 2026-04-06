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

        // speakers.sqlite, stats.sqlite, failed_transcriptions.json, and speaker_clips all
        // live inside the transcripts root by default.
        XCTAssertEqual(paths.speakerDB.deletingLastPathComponent().path, paths.transcripts.path)
        XCTAssertEqual(paths.statsDB.deletingLastPathComponent().path, paths.transcripts.path)
        XCTAssertEqual(paths.failedQueue.deletingLastPathComponent().path, paths.transcripts.path)
        XCTAssertEqual(paths.speakerClips.deletingLastPathComponent().path, paths.transcripts.path)

        XCTAssertEqual(paths.speakerDB.lastPathComponent, "speakers.sqlite")
        XCTAssertEqual(paths.statsDB.lastPathComponent, "stats.sqlite")
        XCTAssertEqual(paths.failedQueue.lastPathComponent, "failed_transcriptions.json")
        XCTAssertEqual(paths.speakerClips.lastPathComponent, "speaker_clips")

        // Log directory lives under ~/Library/Logs/Transcripted, NOT under transcripts.
        XCTAssertTrue(paths.logs.path.hasSuffix("Library/Logs/Transcripted"))
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
}
