import XCTest
@testable import TranscriptedCore

/// Storage-path and recording-validator coverage for the Core package seam.
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

    func testRecordingValidatorRejectsRawRelativePaths() {
        guard let result = RecordingValidator.validateRawSavePath("relative-capture-root") else {
            XCTFail("Expected raw relative path to fail validation")
            return
        }

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errorMessage, "Save path must be an absolute filesystem path")
    }

    func testRecordingValidatorRejectsRelativePathPreferencesBeforeURLConstruction() {
        let original = UserDefaults.standard.object(forKey: "transcriptSaveLocation")
        defer {
            if let original {
                UserDefaults.standard.set(original, forKey: "transcriptSaveLocation")
            } else {
                UserDefaults.standard.removeObject(forKey: "transcriptSaveLocation")
            }
        }

        let paths = CoreStoragePaths(
            transcripts: FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptedCoreTests-transcripts-\(UUID().uuidString)", isDirectory: true),
            speakerDB: FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptedCoreTests-speakers-\(UUID().uuidString).sqlite"),
            statsDB: FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptedCoreTests-stats-\(UUID().uuidString).sqlite"),
            failedQueue: FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptedCoreTests-failed-\(UUID().uuidString).json"),
            speakerClips: FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptedCoreTests-clips-\(UUID().uuidString)", isDirectory: true),
            audioCaptures: FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptedCoreTests-audio-\(UUID().uuidString)", isDirectory: true),
            logs: FileManager.default.temporaryDirectory
                .appendingPathComponent("TranscriptedCoreTests-logs-\(UUID().uuidString)", isDirectory: true)
        )
        defer {
            try? FileManager.default.removeItem(at: paths.transcripts)
            try? FileManager.default.removeItem(at: paths.speakerClips)
            try? FileManager.default.removeItem(at: paths.audioCaptures)
            try? FileManager.default.removeItem(at: paths.logs)
        }

        UserDefaults.standard.set("relative-capture-root", forKey: "transcriptSaveLocation")

        let result = RecordingValidator.validateRecordingConditions(paths: paths)

        XCTAssertFalse(result.isValid)
        XCTAssertEqual(result.errorMessage, "Save path must be an absolute filesystem path")
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
