import XCTest
import Combine
import FluidAudio
import Foundation
import Darwin
@testable import TranscriptedCore

@MainActor
final class SavedAudioJobTimingsTests: XCTestCase {
    func testSavedJobBindsTimingsDuringFailedModelPreparation() async throws {
        try await exerciseJob(cancelWhilePreparing: false)
    }

    func testSavedJobKeepsItsTimingsUntilCancelledPreparationReturns() async throws {
        try await exerciseJob(cancelWhilePreparing: true)
    }

    private func exerciseJob(cancelWhilePreparing: Bool) async throws {
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
            XCTFail("owned timing fixture requires disabled file logging")
            return
        }
        let started = expectation(description: "fake model preparation entered")
        let speech = TimingUnreadySpeech(hold: cancelWhilePreparing, started: { started.fulfill() })
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = parent.appendingPathComponent("saved-job-timings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try removeTimingFixture(root, parent: parent) }
            catch { XCTFail("owned timing fixture cleanup failed") }
        }
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("transcripts"),
            speakerDB: root.appendingPathComponent("speakers.sqlite"),
            statsDB: root.appendingPathComponent("stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed.json"),
            speakerClips: root.appendingPathComponent("clips"),
            audioCaptures: root.appendingPathComponent("scratch"),
            logs: root.appendingPathComponent("logs")
        )
        let calls = TimingUnexpectedCalls()
        let queue = FailedTranscriptionManager(paths: paths)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: queue,
            speechToText: speech,
            diarization: TimingNoDiarizer(calls: calls),
            speakerStore: TimingMemorySpeakers(calls: calls),
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: paths.transcripts.appendingPathComponent("audio"),
            retainedAudioDirectoryProvider: { paths.transcripts.appendingPathComponent("audio") },
            transcriptDirectoryProvider: { paths.transcripts },
            transcriptFormatOptionsProvider: { TranscriptFormatOptions() },
            statsStore: TimingMemoryStats(calls: calls), notifier: nil
        )
        let original = root.appendingPathComponent("synthetic.bin")
        let bytes = Data([1, 3, 5, 7])
        try bytes.write(to: original)
        XCTAssertNil(MeetingPipelineTimings.current)
        manager.startSavedAudioRetranscription(
            micURL: nil, systemURL: original, outputFolder: paths.transcripts
        )
        // Capture the actual work before any await; always release the held fake
        // and await this handle before removing the fixture's owned directory.
        let work = manager.activeTasks.values.first
        XCTAssertNotNil(work)
        await fulfillment(of: [started], timeout: 30)
        if cancelWhilePreparing {
            manager.cancelAll()
            XCTAssertFalse(manager.activeTasks.isEmpty)
            XCTAssertEqual(manager.activeCount, 1)
            XCTAssertEqual(manager.backgroundTaskCount, 1)
            XCTAssertNotNil(speech.recorder)
            speech.finish()
        }
        await work?.value
        XCTAssertEqual(speech.initializeCount, 1)
        XCTAssertNotNil(speech.recorder, "saved jobs must bind the stage recorder before preparing models")
        // Fixed sentinel values prove the recorder reaches the injected stage;
        // no assertion depends on wall-clock duration or machine speed.
        let snapshot = speech.recorder?.snapshot()
        XCTAssertEqual(snapshot?.speechToTextCalls, 1)
        XCTAssertEqual(snapshot?.speechToTextInputSeconds, 17)
        XCTAssertEqual(snapshot?.speechModel, "synthetic-model")
        XCTAssertNil(MeetingPipelineTimings.current, "a job must not leak its recorder into the caller")
        XCTAssertNil(manager.lastPipelineTimings, "unsaved jobs must not publish success timings")
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        if cancelWhilePreparing {
            XCTAssertEqual(manager.displayStatus, .idle)
            XCTAssertNil(manager.lastFailureDiagnosticMessage)
        } else {
            if case .failed = manager.displayStatus {} else {
                XCTFail("unready injected model must fail before audio processing")
            }
            XCTAssertNotNil(manager.lastFailureDiagnosticMessage)
        }
        XCTAssertEqual(calls.count, 0, "no decoder-dependent diarization, speaker or stats work is permitted")
        XCTAssertTrue(queue.failedTranscriptions.isEmpty)
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.transcripts.path))
    }
}

@MainActor
private final class TimingUnreadySpeech: SpeechToTextEngine {
    var isReady: Bool { false }
    var recorder: MeetingPipelineTimings?
    var initializeCount = 0
    private let hold: Bool
    private let started: () -> Void
    private var completion: CheckedContinuation<Void, Never>?
    init(hold: Bool, started: @escaping () -> Void) { self.hold = hold; self.started = started }
    func initialize() async {
        initializeCount += 1
        recorder = MeetingPipelineTimings.current
        recorder?.addSpeechToTextCall(seconds: 2, inputSeconds: 17, model: "synthetic-model")
        if hold {
            await withCheckedContinuation { completion in
                self.completion = completion
                started()
            }
        } else {
            started()
        }
    }
    func finish() { completion?.resume(); completion = nil }
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        XCTFail("unready speech fixture must never receive decoded audio")
        throw TimingFixtureError.unexpectedPipeline
    }
    func cleanup() { XCTFail("fixture does not own a model") }
}

private enum TimingFixtureError: Error { case unowned, unexpectedPipeline }

private func removeTimingFixture(_ root: URL, parent: URL) throws {
    let resolved = root.resolvingSymlinksInPath().standardizedFileURL
    let prefix = "saved-job-timings-"
    let leaf = root.lastPathComponent
    guard root == resolved, resolved.deletingLastPathComponent() == parent,
          leaf.hasPrefix(prefix),
          let uuid = UUID(uuidString: String(leaf.dropFirst(prefix.count))),
          uuid.uuidString == String(leaf.dropFirst(prefix.count)).uppercased() else {
        throw TimingFixtureError.unowned
    }
    var info = stat()
    guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
        throw TimingFixtureError.unowned
    }
    try FileManager.default.removeItem(at: root)
}

private final class TimingUnexpectedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}

@MainActor
private final class TimingNoDiarizer: DiarizationEngine {
    nonisolated let calls: TimingUnexpectedCalls
    init(calls: TimingUnexpectedCalls) { self.calls = calls }
    var isReady: Bool { true }
    func initialize() async { calls.record() }
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        calls.record(); throw TimingFixtureError.unexpectedPipeline
    }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        calls.record(); throw TimingFixtureError.unexpectedPipeline
    }
    nonisolated func prewarmVoiceprintInBackground() { calls.record() }
    func cleanup() { calls.record() }
}

private final class TimingMemoryStats: StatsStore {
    let calls: TimingUnexpectedCalls
    init(calls: TimingUnexpectedCalls) { self.calls = calls }
    func recordSession(_ metadata: RecordingMetadata) { calls.record() }
    func getTotalRecordingsCount() -> Int { calls.record(); return 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { calls.record(); return [] }
    func recordingExists(transcriptPath: String) -> Bool { calls.record(); return false }
}

private final class TimingMemorySpeakers: SpeakerStore, @unchecked Sendable {
    let calls: TimingUnexpectedCalls
    init(calls: TimingUnexpectedCalls) { self.calls = calls }
    private var inertProfile: SpeakerProfile {
        SpeakerProfile(id: UUID(uuidString: "0CA66E7A-2DFA-455F-B0D9-067ACD0F932A")!, displayName: nil,
                       nameSource: nil, embedding: [], firstSeen: Date(timeIntervalSince1970: 0),
                       lastSeen: Date(timeIntervalSince1970: 0), callCount: 0, confidence: 0, disputeCount: 0)
    }
    func matchSpeaker(embedding: [Float], threshold: Double) -> SpeakerMatchResult? { calls.record(); return nil }
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?) -> SpeakerProfile { calls.record(); return inertProfile }
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?, blendAlpha: Float) -> SpeakerProfile { calls.record(); return inertProfile }
    func getSpeaker(id: UUID) -> SpeakerProfile? { calls.record(); return nil }
    func allSpeakers() -> [SpeakerProfile] { calls.record(); return [] }
    func setDisplayName(id: UUID, name: String, source: String) { calls.record() }
    func requireDisplayNameUpdate(id: UUID, name: String, source: String) throws { calls.record() }
    func restoreProfile(_ profile: SpeakerProfile) { calls.record() }
    func revertMatchContribution(snapshot: SpeakerProfile) { calls.record() }
    func deleteSpeaker(id: UUID) { calls.record() }
    func mergeProfiles(sourceId: UUID, into targetId: UUID) throws { calls.record() }
    func performMutationBatch(_ mutations: () throws -> Void) throws { calls.record() }
    func recordUserConfirmations(_ confirmations: [SpeakerUserConfirmation]) throws { calls.record() }
    func recordConfirmationMeetingAlias(transcriptId: UUID, meetingId: UUID) throws { calls.record() }
    func confirmationWouldIncreaseCount(profileId: UUID, transcriptId: UUID, meetingId: UUID?) throws -> Bool { calls.record(); return false }
    func mergeDuplicates() { calls.record() }
    func mergeDuplicates(protecting protectedIds: Set<UUID>) { calls.record() }
    func pruneWeakProfiles() { calls.record() }
    func pruneWeakProfiles(protecting protectedIds: Set<UUID>) { calls.record() }
    func mergeSurvivorId(of profileId: UUID) -> UUID? { calls.record(); return nil }
    func mergedAliasIds(of profileId: UUID) -> Set<UUID> { calls.record(); return [] }
    func incrementDisputeCount(id: UUID) { calls.record() }
    func resetDisputeCount(id: UUID) { calls.record() }
    func recordMatchOutcome(_ outcome: SpeakerMatchOutcome) { calls.record() }
    func recordMatchOutcomes(_ outcomes: [SpeakerMatchOutcome]) { calls.record() }
    func recentMatchOutcomes(profileId: UUID, limit: Int) -> [SpeakerMatchOutcome] { calls.record(); return [] }
    func recordNegativeExemplar(profileId: UUID, embedding: [Float]) { calls.record() }
    func negativeExemplarsByProfile() -> [UUID: [[Float]]] { calls.record(); return [:] }
}
