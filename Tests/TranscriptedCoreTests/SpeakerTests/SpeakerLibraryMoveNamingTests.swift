import Combine
import FluidAudio
import XCTest
@testable import TranscriptedCore

/// Only invented captures under one owned temporary root. No app, model or preferences.
final class SpeakerLibraryMoveNamingTests: XCTestCase {
    @MainActor
    func testPendingReviewSavesNamesInTheCurrentLibraryAfterItsOriginalWasMoved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let moved = fixture.currentLibrary.appendingPathComponent("Renamed.md")
        try FileManager.default.moveItem(at: fixture.original, to: moved)
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        XCTAssertEqual(fixture.manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(fixture.manager.lastSavedTranscriptURL, moved)
        XCTAssertNil(fixture.manager.lastSpeakerFinalizationFailure)
        XCTAssertTrue(fixture.failed.failedTranscriptions.isEmpty)
        XCTAssertEqual(fixture.database.getSpeaker(id: fixture.profileID)?.displayName, "Synthetic Person")
        XCTAssertTrue(try String(contentsOf: moved, encoding: .utf8).contains("[System/Synthetic Person]"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.original.path))
    }

    @MainActor
    func testCopyThenSwitchUpdatesOnlyTheCurrentLibraryCopy() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.original)
        let copy = fixture.currentLibrary.appendingPathComponent("Current.md")
        try FileManager.default.copyItem(at: fixture.original, to: copy)
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        XCTAssertEqual(fixture.manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(fixture.manager.lastSavedTranscriptURL, copy)
        XCTAssertEqual(try Data(contentsOf: fixture.original), originalBytes)
        XCTAssertTrue(try String(contentsOf: copy, encoding: .utf8).contains("[System/Synthetic Person]"))
    }

    @MainActor
    func testSwitchWithoutCopyStillSavesThePendingOriginalWhenCurrentLookupIsEmpty() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        XCTAssertEqual(fixture.manager.displayStatus, .transcriptSaved)
        XCTAssertEqual(fixture.manager.lastSavedTranscriptURL, fixture.original)
        XCTAssertEqual(fixture.database.getSpeaker(id: fixture.profileID)?.displayName, "Synthetic Person")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.currentLibrary.path).isEmpty)
    }

    @MainActor
    func testDuplicateStableIDsInCurrentLibraryRejectSaveWithoutFallingBackToOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.original)
        let first = fixture.currentLibrary.appendingPathComponent("First.md")
        let second = fixture.currentLibrary.appendingPathComponent("Second.md")
        try originalBytes.write(to: first)
        try originalBytes.write(to: second)
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        assertRejected(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: first), originalBytes)
        XCTAssertEqual(try Data(contentsOf: second), originalBytes)
    }

    @MainActor
    func testUnavailableCurrentLibraryRejectsSaveEvenWhenOriginalStillExists() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.original)
        try FileManager.default.removeItem(at: fixture.currentLibrary)
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        assertRejected(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.original), originalBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.currentLibrary.path))
    }

    @MainActor
    func testUnavailableHostAuthorityRejectsSaveBeforeFallingBackToOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.original)
        fixture.directory.set(nil)

        await save(fixture)

        assertRejected(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.original), originalBytes)
    }

    @MainActor
    func testDeletedCaptureDoesNotRecreateTranscriptOrMutatePeople() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.removeItem(at: fixture.original)
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        assertRejected(fixture)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.original.path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.currentLibrary.path).isEmpty)
    }

    @MainActor
    func testReadOnlyCurrentMatchRejectsSaveWithoutEditingWritableOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let originalBytes = try Data(contentsOf: fixture.original)
        let copy = fixture.currentLibrary.appendingPathComponent("ReadOnly.md")
        try originalBytes.write(to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: copy.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: copy.path) }
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        assertRejected(fixture)
        XCTAssertEqual(try Data(contentsOf: fixture.original), originalBytes)
        XCTAssertEqual(try Data(contentsOf: copy), originalBytes)
    }

    @MainActor
    func testMatchingFilenameWithDifferentIdentityIsNeverUsed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let unrelated = fixture.currentLibrary.appendingPathComponent(fixture.original.lastPathComponent)
        let unrelatedBytes = try String(contentsOf: fixture.original, encoding: .utf8)
            .replacingOccurrences(of: fixture.transcriptID.uuidString, with: UUID().uuidString)
        try unrelatedBytes.write(to: unrelated, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: fixture.original)
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        assertRejected(fixture)
        XCTAssertEqual(try String(contentsOf: unrelated, encoding: .utf8), unrelatedBytes)
    }

    @MainActor
    func testCurrentDirectorySymlinkToOutsideCaptureIsNotFollowed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = fixture.root.appendingPathComponent("outside.md")
        try FileManager.default.moveItem(at: fixture.original, to: outside)
        let outsideBytes = try Data(contentsOf: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.currentLibrary.appendingPathComponent("Linked.md"), withDestinationURL: outside
        )
        fixture.directory.set(fixture.currentLibrary)

        await save(fixture)

        assertRejected(fixture)
        XCTAssertEqual(try Data(contentsOf: outside), outsideBytes)
    }

    @MainActor
    func testMetadataPublicationResolvesLibraryMoveAfterTranscriptFinalization() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let moved = fixture.currentLibrary.appendingPathComponent("Finalized.md")
        try FileManager.default.moveItem(at: fixture.original, to: moved)
        fixture.directory.set(fixture.currentLibrary)

        let outcome = fixture.manager.finishNamingFlow(
            didFinalizeTranscript: true, updatesCount: 1, transcriptId: fixture.transcriptID,
            resolvedURL: fixture.original, micURL: fixture.mic, systemURL: fixture.system
        )

        guard case .completed = outcome else { return XCTFail("Publication must follow the authorized moved capture") }
        XCTAssertEqual(fixture.manager.lastSavedTranscriptURL, moved)
        XCTAssertTrue(fixture.failed.failedTranscriptions.isEmpty)
    }

    @MainActor
    private func assertRejected(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(fixture.manager.lastSpeakerFinalizationFailure?.reason, .transcriptUnresolved, file: file, line: line)
        XCTAssertNil(fixture.manager.lastSavedTranscriptURL, file: file, line: line)
        XCTAssertNil(fixture.database.getSpeaker(id: fixture.profileID)?.displayName, file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mic.path), file: file, line: line)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.system.path), file: file, line: line)
        XCTAssertEqual(fixture.failed.failedTranscriptions.map(\.id), [fixture.transcriptID], file: file, line: line)
    }

    @MainActor
    private func save(_ fixture: Fixture) async {
        let complete = expectation(description: "speaker review callback finishes")
        let subscription = fixture.manager.$speakerNamingRequest
            .filter { $0 == nil }
            .prefix(1)
            .sink { _ in complete.fulfill() }
        fixture.manager.handleNamingComplete(
            updates: [SpeakerNameUpdate(persistentSpeakerId: fixture.profileID, diarizerSpeakerId: "1",
                                       newName: "Synthetic Person", action: .named)],
            transcriptURL: fixture.original,
            transcriptId: fixture.transcriptID,
            transcriptionResult: fixture.result,
            micURL: fixture.mic,
            systemURL: fixture.system,
            clips: []
        )
        // An XCTest hang guard, never an elapsed-time assertion.
        await fulfillment(of: [complete], timeout: 30)
        withExtendedLifetime(subscription) {}
    }
}

private final class CurrentReviewDirectory: @unchecked Sendable {
    private let lock = NSLock()
    private var directory: URL?
    init(_ directory: URL) { self.directory = directory }
    func get() -> URL? { lock.withLock { directory } }
    func set(_ value: URL?) { lock.withLock { directory = value } }
}

@MainActor
private final class Fixture {
    let root: URL
    let oldLibrary: URL
    let currentLibrary: URL
    let original: URL
    let mic: URL
    let system: URL
    let transcriptID = UUID()
    let profileID: UUID
    let database: SpeakerDatabase
    let failed: FailedTranscriptionManager
    let manager: TranscriptionTaskManager
    let directory: CurrentReviewDirectory
    let result: TranscriptionResult

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SpeakerLibraryMove-\(UUID())", isDirectory: true)
        oldLibrary = root.appendingPathComponent("old/meetings", isDirectory: true)
        currentLibrary = root.appendingPathComponent("current/meetings", isDirectory: true)
        let scratch = root.appendingPathComponent("scratch", isDirectory: true)
        for folder in [oldLibrary, currentLibrary, scratch] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let paths = CoreStoragePaths(transcripts: oldLibrary,
                                    speakerDB: root.appendingPathComponent("people.sqlite"),
                                    statsDB: root.appendingPathComponent("stats.sqlite"),
                                    failedQueue: root.appendingPathComponent("failed.json"),
                                    speakerClips: scratch, audioCaptures: scratch, logs: scratch)
        database = SpeakerDatabase(path: paths.speakerDB.path)
        profileID = database.addOrUpdateSpeaker(embedding: [Float](repeating: 0.4, count: 256), existingId: nil).id
        failed = FailedTranscriptionManager(paths: paths)
        directory = CurrentReviewDirectory(oldLibrary)
        let currentDirectory = directory
        manager = TranscriptionTaskManager(failedTranscriptionManager: failed,
                                          speechToText: ReviewSTT(), diarization: ReviewDiarizer(),
                                          speakerStore: database, speakerClipsDirectory: scratch,
                                          cleanupDirectories: [scratch],
                                          transcriptDirectoryProvider: { currentDirectory.get() })
        original = oldLibrary.appendingPathComponent("Original.md")
        mic = scratch.appendingPathComponent("mic.wav")
        system = scratch.appendingPathComponent("system.wav")
        try Data().write(to: mic)
        try Data().write(to: system)
        result = TranscriptionResult(micUtterances: [], systemUtterances: [
            TranscriptionUtterance(start: 0, end: 3, channel: 1, speakerId: 1,
                                   persistentSpeakerId: profileID, matchSimilarity: nil,
                                   transcript: "Synthetic words.")
        ], duration: 3, processingTime: 1)
        let markdown = """
        ---
        transcript_id: "\(transcriptID)"
        date: 2026-01-01
        time: 12:00:00
        duration: "00:03"
        speakers:
          - id: "1"
            db_id: "\(profileID)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        # Synthetic meeting

        ## Full Transcript

        [00:00] [System/Speaker 1] Synthetic words.
        """
        try markdown.write(to: original, atomically: true, encoding: .utf8)
        manager.speakerNamingRequest = SpeakerNamingRequest(speakers: [], transcriptURL: original,
                                                            transcriptId: transcriptID,
                                                            systemAudioURL: system, micAudioURL: mic,
                                                            onComplete: { _ in })
    }

    func remove() {
        precondition(root.deletingLastPathComponent() == FileManager.default.temporaryDirectory)
        precondition(root.lastPathComponent.hasPrefix("SpeakerLibraryMove-"))
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor private final class ReviewSTT: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool { true }
    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String { "" }
    func cleanup() {}
}

@MainActor private final class ReviewDiarizer: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool { true }
    func initialize() async {}
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { [] }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { [] }
    func cleanup() {}
}
