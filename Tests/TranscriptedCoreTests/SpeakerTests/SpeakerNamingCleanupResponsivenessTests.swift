import Combine
import FluidAudio
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerNamingCleanupResponsivenessTests: XCTestCase {
    @MainActor
    func testSlowCleanupLeavesMainActorResponsiveAndKeepsReviewOwnedUntilFilesAreRemoved() async throws {
        let harness = try makeHarness()
        defer { harness.removeOwnedDirectory() }
        let enteredCleanup = expectation(description: "Cleanup reached the durable preparation boundary")
        let recovery = HeldNamingCleanupRecovery(
            entered: enteredCleanup,
            sourceURLs: [harness.micURL, harness.systemURL]
        )
        defer { recovery.resume() }
        let finished = expectation(description: "The review clears after cleanup returns")
        let request = harness.enqueue(recovery: recovery)
        let observation = harness.manager.$speakerNamingRequest.dropFirst().sink {
            if $0 == nil { finished.fulfill() }
        }
        defer { observation.cancel() }

        harness.complete(request: request, recovery: recovery)
        await fulfillment(of: [enteredCleanup], timeout: 60)

        // This is an actor turn while the worker is deliberately held. No elapsed
        // time assertion: the cleanup fake refuses to block if regressed onto main.
        XCTAssertFalse(recovery.snapshot.preparedOnMain)
        XCTAssertEqual(harness.manager.speakerNamingRequest?.id, request.id)
        XCTAssertTrue(harness.manager.speakerReviewProfileProtection.protectedProfileIds.contains(harness.profileID))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.systemURL.path))
        XCTAssertFalse(recovery.snapshot.confirmed)

        recovery.resume()
        await fulfillment(of: [finished], timeout: 60)

        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.systemURL.path))
        XCTAssertEqual(recovery.snapshot.transitions, ["prepare", "confirm"])
        XCTAssertTrue(recovery.snapshot.confirmedAfterSourcesWereRemoved)
        XCTAssertFalse(harness.manager.speakerReviewProfileProtection.protectedProfileIds.contains(harness.profileID))
        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
        XCTAssertTrue(harness.failedManager.failedTranscriptions.isEmpty)
    }

    @MainActor
    func testRejectedCleanupPreparationRetainsBothSourcesWithoutConfirmingDeletion() async throws {
        let harness = try makeHarness()
        defer { harness.removeOwnedDirectory() }
        let enteredCleanup = expectation(description: "Cleanup asks permission before deleting sources")
        let recovery = HeldNamingCleanupRecovery(
            entered: enteredCleanup,
            sourceURLs: [harness.micURL, harness.systemURL],
            preparationAllowed: false
        )
        defer { recovery.resume() }
        let finished = expectation(description: "Rejected cleanup returns to the review flow")
        let request = harness.enqueue(recovery: recovery)
        let observation = harness.manager.$speakerNamingRequest.dropFirst().sink {
            if $0 == nil { finished.fulfill() }
        }
        defer { observation.cancel() }

        harness.complete(request: request, recovery: recovery)
        await fulfillment(of: [enteredCleanup], timeout: 60)
        XCTAssertFalse(recovery.snapshot.preparedOnMain)
        recovery.resume()
        await fulfillment(of: [finished], timeout: 60)

        XCTAssertEqual(recovery.snapshot.transitions, ["prepare"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.systemURL.path))
        XCTAssertEqual(harness.manager.displayStatus, .transcriptSaved)
    }

    @MainActor
    func testPartialCleanupCannotAcknowledgeThatAllSourcesWereRemoved() async throws {
        let harness = try makeHarness(microphoneOutsideCleanupRoot: true)
        defer { harness.removeOwnedDirectory() }
        let enteredCleanup = expectation(description: "Cleanup reaches its permission boundary")
        let recovery = HeldNamingCleanupRecovery(
            entered: enteredCleanup,
            sourceURLs: [harness.micURL, harness.systemURL]
        )
        defer { recovery.resume() }
        let finished = expectation(description: "A refused deletion does not strand the review")
        let request = harness.enqueue(recovery: recovery)
        let observation = harness.manager.$speakerNamingRequest.dropFirst().sink {
            if $0 == nil { finished.fulfill() }
        }
        defer { observation.cancel() }

        harness.complete(request: request, recovery: recovery)
        await fulfillment(of: [enteredCleanup], timeout: 60)
        recovery.resume()
        await fulfillment(of: [finished], timeout: 60)

        XCTAssertEqual(recovery.snapshot.transitions, ["prepare"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.systemURL.path))
        XCTAssertFalse(recovery.snapshot.confirmed)
    }

    @MainActor
    private func makeHarness(microphoneOutsideCleanupRoot: Bool = false) throws -> NamingCleanupHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NamingCleanup-\(UUID().uuidString)", isDirectory: true)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("transcripts"),
            speakerDB: root.appendingPathComponent("speakers.sqlite"),
            statsDB: root.appendingPathComponent("stats.sqlite"),
            failedQueue: root.appendingPathComponent("failed.json"),
            speakerClips: root.appendingPathComponent("clips"),
            audioCaptures: root.appendingPathComponent("audio"),
            logs: root.appendingPathComponent("logs")
        )
        for directory in [paths.transcripts, paths.speakerClips, paths.audioCaptures, paths.logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        let profileID = speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256), existingId: nil
        ).id
        let failedManager = FailedTranscriptionManager(paths: paths)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: failedManager,
            speechToText: CleanupSpeechStub(),
            diarization: CleanupDiarizationStub(),
            speakerStore: speakerDB,
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            statsStore: StatsDatabase(path: paths.statsDB.path)
        )
        let transcriptID = UUID()
        let transcriptURL = paths.transcripts.appendingPathComponent("Meeting.md")
        let micURL = (microphoneOutsideCleanupRoot ? root : paths.audioCaptures)
            .appendingPathComponent("mic.wav")
        let systemURL = paths.audioCaptures.appendingPathComponent("system.wav")
        let clipURL = paths.speakerClips.appendingPathComponent("review.wav")
        for url in [micURL, systemURL, clipURL] { try Data("fixture".utf8).write(to: url) }
        try """
        ---
        transcript_id: "\(transcriptID.uuidString)"
        date: 2026-11-13
        time: 10:00:00
        duration: "0:05"
        sources: [mic, system_audio]
        mic_utterances: 0
        system_utterances: 1
        mic_speakers: 0
        system_speakers: 1
        total_word_count: 2
        speakers:
          - id: "1"
            db_id: "\(profileID.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---
        # Cleanup fixture

        ## Full Transcript

        [00:01] [System/Speaker 1] Synthetic fixture.
        """.write(to: transcriptURL, atomically: true, encoding: .utf8)
        return NamingCleanupHarness(
            root: root, manager: manager, failedManager: failedManager,
            profileID: profileID, transcriptID: transcriptID, transcriptURL: transcriptURL,
            micURL: micURL, systemURL: systemURL, clipURL: clipURL
        )
    }
}

@available(macOS 14.0, *)
@MainActor
private struct NamingCleanupHarness {
    let root: URL
    let manager: TranscriptionTaskManager
    let failedManager: FailedTranscriptionManager
    let profileID: UUID
    let transcriptID: UUID
    let transcriptURL: URL
    let micURL: URL
    let systemURL: URL
    let clipURL: URL

    private var entry: SpeakerNamingEntry {
        SpeakerNamingEntry(
            id: profileID, diarizerSpeakerId: "1", clipURL: clipURL,
            sampleText: "Synthetic fixture.", currentName: nil, matchSimilarity: nil,
            needsNaming: true, needsConfirmation: false,
            sessionEmbedding: [Float](repeating: 0.25, count: 256)
        )
    }

    func enqueue(recovery: HeldNamingCleanupRecovery) -> SpeakerNamingRequest {
        let request = SpeakerNamingRequest(
            speakers: [entry], transcriptURL: transcriptURL, transcriptId: transcriptID,
            systemAudioURL: systemURL, micAudioURL: micURL,
            importedRecoverySession: recovery, onComplete: { _ in }
        )
        manager.enqueueSpeakerNamingRequest(request)
        return request
    }

    func complete(request: SpeakerNamingRequest, recovery: HeldNamingCleanupRecovery) {
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [TranscriptionUtterance(
                start: 1, end: 3, channel: 1, speakerId: 1, persistentSpeakerId: profileID,
                matchSimilarity: nil, transcript: "Synthetic fixture."
            )],
            duration: 5, processingTime: 1
        )
        manager.handleNamingComplete(
            updates: [], transcriptURL: transcriptURL, transcriptId: transcriptID,
            transcriptionResult: result, micURL: micURL, systemURL: systemURL,
            clips: [entry], importedRecoverySession: recovery, requestId: request.id
        )
    }

    func removeOwnedDirectory() {
        // The exact UUID directory created by makeHarness owns every fixture.
        try? FileManager.default.removeItem(at: root)
    }
}

private final class HeldNamingCleanupRecovery: ImportedTranscriptionRecoverySession, @unchecked Sendable {
    struct Snapshot {
        var transitions: [String] = []
        var preparedOnMain = false
        var confirmed = false
        var confirmedAfterSourcesWereRemoved = false
    }
    let jobID = UUID()
    private let entered: XCTestExpectation
    private let sourceURLs: [URL]
    private let preparationAllowed: Bool
    private let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var state = Snapshot()

    init(entered: XCTestExpectation, sourceURLs: [URL], preparationAllowed: Bool = true) {
        self.entered = entered
        self.sourceURLs = sourceURLs
        self.preparationAllowed = preparationAllowed
    }

    var snapshot: Snapshot { lock.withLock { state } }
    func resume() { release.signal() }
    func transcriptCommitConfirmed() {}
    func failedQueueHandoffConfirmed() {}

    func prepareForScratchCleanup() -> Bool {
        let onMain = Thread.isMainThread
        lock.withLock {
            state.transitions.append("prepare")
            state.preparedOnMain = onMain
        }
        entered.fulfill()
        // Regression escape: old code fails the assertion without deadlocking
        // the main actor that must release this deliberately slow operation.
        guard !onMain else { return false }
        guard release.wait(timeout: .now() + 60) == .success else { return false }
        return preparationAllowed
    }

    func scratchCleanupConfirmed() {
        let removed = sourceURLs.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        lock.withLock {
            state.transitions.append("confirm")
            state.confirmed = true
            state.confirmedAfterSourcesWereRemoved = removed
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class CleanupSpeechStub: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String { "" }
    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class CleanupDiarizationStub: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    func initialize() async {}
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { [] }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { [] }
    func cleanup() {}
}
