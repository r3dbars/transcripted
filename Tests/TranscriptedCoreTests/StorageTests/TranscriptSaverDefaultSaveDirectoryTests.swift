import XCTest
@testable import TranscriptedCore

/// Pins the behaviour of `TranscriptSaver.defaultSaveDirectory` so a future revert
/// of the markdown-first storage refactor is loud. Pre-refactor, a custom
/// `transcriptSaveLocation` was used as the literal save directory; post-refactor it
/// is treated as a capture-library root and meetings land under `<custom>/meetings`.
@available(macOS 14.0, *)
final class TranscriptSaverDefaultSaveDirectoryTests: XCTestCase {

    private let preferenceKey = "transcriptSaveLocation"
    private var originalArguments: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        originalArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        // An empty value masks any persistent location without changing it.
        setPreference("")
    }

    override func tearDown() {
        UserDefaults.standard.setVolatileDomain(originalArguments, forName: UserDefaults.argumentDomain)
        super.tearDown()
    }

    // XCTest runs these cases serially within this test process. Keep each
    // override scoped to setUp/tearDown; parallel workers have separate processes.
    private func setPreference(_ value: String) {
        var arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        arguments[preferenceKey] = value
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
    }

    func testVolatileLocationReachesDefaultAccessorWithoutPersistentWrites() throws {
        let processName = ProcessInfo.processInfo.processName
        let bundleID = Bundle.main.bundleIdentifier
        let domain = bundleID.flatMap { $0.isEmpty ? nil : $0 } ?? processName
        // Never inspect a product preference domain, even if this fixture is
        // accidentally linked into the app instead of a test executable.
        guard !["Transcripted", "Draft"].contains(processName),
              bundleID != "com.justinbetker.draft",
              domain == "swiftpm-testing-helper" || domain == "com.apple.dt.xctest.tool"
                || domain.hasSuffix("Tests") else {
            XCTFail("Preference isolation proof requires a test-process domain")
            return
        }
        let persistentBefore = UserDefaults.standard.persistentDomain(forName: domain)
        let argumentsBefore = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        defer {
            UserDefaults.standard.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
        }
        let customRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("VolatileLocation-\(UUID().uuidString)", isDirectory: true)
        setPreference(customRoot.path)
        XCTAssertEqual(TranscriptSaver.defaultSaveDirectory, customRoot.appendingPathComponent("meetings", isDirectory: true))
        // Blank is the no-custom-location control, without exposing an
        // underlying persistent location as removeObject would.
        setPreference("")
        XCTAssertEqual(TranscriptSaver.defaultSaveDirectory, CoreStoragePaths.default.transcripts)
        let persistentAfter = UserDefaults.standard.persistentDomain(forName: domain)
        XCTAssertTrue((persistentBefore as NSDictionary?) == (persistentAfter as NSDictionary?),
                      "Volatile overrides must not alter persistent preferences")
        UserDefaults.standard.setVolatileDomain(argumentsBefore, forName: UserDefaults.argumentDomain)
        XCTAssertTrue((argumentsBefore as NSDictionary).isEqual(
            UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)),
            "The complete prior argument domain must be restored")
    }

    func testReturnsDefaultTranscriptsWhenNoCustomPathSet() {
        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testReturnsDefaultTranscriptsWhenCustomPathIsBlank() {
        setPreference("   ")

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

        setPreference(customRoot.path)

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            customRoot.appendingPathComponent("meetings", isDirectory: true)
        )
    }

    func testRelativeCustomPathFallsBackToDefault() {
        setPreference("relative/path")

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testTraversalCustomPathFallsBackToDefault() {
        setPreference("/Users/someone/../../etc/passwd")

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testSystemCustomPathFallsBackToDefault() {
        setPreference("/System/Library/Transcripted")

        XCTAssertEqual(
            TranscriptSaver.defaultSaveDirectory,
            CoreStoragePaths.default.transcripts
        )
    }

    func testTargetURLReplacementKeepsCreationDateAndUpdatesModificationDate() throws {
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
        // New text must get a new mtime so mtime-keyed indexes re-read it.
        XCTAssertGreaterThan(
            afterModificationDate.timeIntervalSince1970,
            expectedModificationDate.timeIntervalSince1970 + 1
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
