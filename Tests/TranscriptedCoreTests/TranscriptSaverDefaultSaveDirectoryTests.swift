import XCTest
@testable import TranscriptedCore

/// Pins the behaviour of `TranscriptSaver.defaultSaveDirectory` so a future revert
/// of the markdown-first storage refactor is loud. Pre-refactor, a custom
/// `transcriptSaveLocation` was used as the literal save directory; post-refactor it
/// is treated as a capture-library root and meetings land under `<custom>/meetings`.
@available(macOS 14.0, *)
final class TranscriptSaverDefaultSaveDirectoryTests: XCTestCase {

    private let preferenceKey = "transcriptSaveLocation"
    private var originalPreference: Any?

    override func setUp() {
        super.setUp()
        originalPreference = UserDefaults.standard.object(forKey: preferenceKey)
        UserDefaults.standard.removeObject(forKey: preferenceKey)
    }

    override func tearDown() {
        if let originalPreference {
            UserDefaults.standard.set(originalPreference, forKey: preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: preferenceKey)
        }
        super.tearDown()
    }

    func testReturnsDefaultTranscriptsWhenNoCustomPathSet() {
        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testReturnsDefaultTranscriptsWhenCustomPathIsBlank() {
        UserDefaults.standard.set("   ", forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testCustomAbsolutePathAppendsMeetingsSubdirectory() {
        let customRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSaverDefaultSaveDirectoryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: customRoot) }
        try? FileManager.default.createDirectory(at: customRoot, withIntermediateDirectories: true)

        UserDefaults.standard.set(customRoot.path, forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            customRoot.appendingPathComponent("meetings", isDirectory: true)
        )
    }

    func testRelativeCustomPathFallsBackToDefault() {
        UserDefaults.standard.set("relative/path", forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testTraversalCustomPathFallsBackToDefault() {
        UserDefaults.standard.set("/Users/someone/../../etc/passwd", forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testSystemCustomPathFallsBackToDefault() {
        UserDefaults.standard.set("/System/Library/Transcripted", forKey: preferenceKey)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testTargetURLReplacementPreservesOriginalFileDates() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSaverReplacementDates-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let transcriptURL = directory.appendingPathComponent("Reviewed_Call.md")
        try "Original transcript".write(to: transcriptURL, atomically: true, encoding: .utf8)

        let originalCreationDate = Date(timeIntervalSince1970: 1_700_000_000)
        let originalModificationDate = Date(timeIntervalSince1970: 1_700_000_123)
        try FileManager.default.setAttributes(
            [
                .creationDate: originalCreationDate,
                .modificationDate: originalModificationDate
            ],
            ofItemAtPath: transcriptURL.path
        )
        let beforeAttributes = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        let expectedCreationDate = try XCTUnwrap(beforeAttributes[.creationDate] as? Date)
        let expectedModificationDate = try XCTUnwrap(beforeAttributes[.modificationDate] as? Date)

        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Updated synthetic transcript."
                )
            ],
            duration: 2,
            processingTime: 0.5
        )

        let savedURL = TranscriptSaver.saveTranscript(
            result,
            transcriptId: UUID(),
            directory: directory,
            meetingTitle: "Reviewed Call",
            statsStore: TranscriptSaverNoopStatsStore(),
            recordingDate: Date(),
            targetURL: transcriptURL,
            transcriptionEngine: .parakeetLocal
        )

        XCTAssertEqual(savedURL, transcriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Updated synthetic transcript."))

        let afterAttributes = try FileManager.default.attributesOfItem(atPath: transcriptURL.path)
        let afterCreationDate = try XCTUnwrap(afterAttributes[.creationDate] as? Date)
        let afterModificationDate = try XCTUnwrap(afterAttributes[.modificationDate] as? Date)
        XCTAssertEqual(
            afterCreationDate.timeIntervalSince1970,
            expectedCreationDate.timeIntervalSince1970,
            accuracy: 1.0
        )
        XCTAssertEqual(
            afterModificationDate.timeIntervalSince1970,
            expectedModificationDate.timeIntervalSince1970,
            accuracy: 1.0
        )
    }
}

@available(macOS 14.0, *)
private final class TranscriptSaverNoopStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}

    func getTotalRecordingsCount() -> Int { 0 }

    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }

    func recordingExists(transcriptPath: String) -> Bool { false }
}
