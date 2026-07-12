import XCTest
@testable import TranscriptedCore

/// Pins the injectable `statsStore` seam on `TranscriptScanner`. Both
/// `migrateExistingTranscripts` and `needsMigration` must accept a caller-supplied
/// `StatsDatabase` and write/read through it instead of always touching
/// `StatsDatabase.shared` (which opens the user's real `speakers.sqlite`-adjacent
/// stats database on disk).
@available(macOS 14.0, *)
final class TranscriptScannerStatsInjectionTests: XCTestCase {

    private var workingDirectory: URL!
    private var statsDBPath: URL!

    override func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptScannerStatsInjectionTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        workingDirectory = root.appendingPathComponent("transcripts", isDirectory: true)
        try? FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        statsDBPath = root.appendingPathComponent("stats-\(UUID().uuidString).sqlite")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workingDirectory.deletingLastPathComponent())
        workingDirectory = nil
        statsDBPath = nil
        super.tearDown()
    }

    func testMigrateExistingTranscriptsWritesToInjectedStatsStoreOnly() async throws {
        let injectedStore = StatsDatabase(path: statsDBPath.path)
        XCTAssertEqual(injectedStore.getTotalRecordingsCount(), 0)

        try writeSampleTranscript(named: "sample.md")

        let migrated = await TranscriptScanner.migrateExistingTranscripts(
            from: workingDirectory,
            statsStore: injectedStore
        )

        XCTAssertEqual(migrated, 1)
        XCTAssertEqual(injectedStore.getTotalRecordingsCount(), 1, "migration should land in the injected store")
    }

    func testNeedsMigrationReadsFromInjectedStatsStoreNotSharedInstance() throws {
        // needsMigration() only inspects TranscriptSaver.defaultSaveDirectory on disk, so this
        // test's job is narrower: prove the injected store's record count — not
        // StatsDatabase.shared's — is what decides the early-out. An injected store that
        // already has a record short-circuits to `false` immediately, before any directory
        // scan, regardless of what the real shared database contains.
        let injectedStore = StatsDatabase(path: statsDBPath.path)
        XCTAssertEqual(injectedStore.getTotalRecordingsCount(), 0)

        injectedStore.recordSession(
            RecordingMetadata(
                date: Date(),
                durationSeconds: 30,
                wordCount: 3,
                speakerCount: 1,
                transcriptPath: workingDirectory.appendingPathComponent("sample.md").path,
                title: "Sample"
            )
        )
        XCTAssertEqual(injectedStore.getTotalRecordingsCount(), 1)

        XCTAssertFalse(
            TranscriptScanner.needsMigration(statsStore: injectedStore),
            "a non-empty injected store should short-circuit needsMigration to false"
        )
    }

    private func writeSampleTranscript(named name: String) throws {
        let raw = """
        ---
        capture_type: meeting
        title: "Sample"
        date: 2026-04-22
        time: "13:14:15"
        duration: "00:30"
        total_word_count: 3
        ---

        ## Transcript

        Hello world here.
        """
        let url = workingDirectory.appendingPathComponent(name)
        try raw.write(to: url, atomically: true, encoding: .utf8)
    }
}
