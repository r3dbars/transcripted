import XCTest
import Combine
import FluidAudio
import Foundation
import Darwin
@testable import TranscriptedCore

@MainActor
final class SavedAudioInputOwnershipStatusTests: XCTestCase {
    func testDiscardedPreparationFailureReturnsToIdleWithoutStartingWork() async throws {
        try await exerciseRejectedSnapshot(discard: true)
    }

    func testAlreadyClaimedInputFailureReturnsToIdleWithoutStartingWork() async throws {
        try await exerciseRejectedSnapshot(discard: false)
    }

    private func exerciseRejectedSnapshot(discard: Bool) async throws {
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
            XCTFail("owned status fixture requires disabled file logging")
            return
        }
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        let root = parent.appendingPathComponent("saved-input-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            do { try removeStatusFixture(root, parent: parent) }
            catch { XCTFail("owned status fixture cleanup failed") }
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
        let calls = StatusUnexpectedCalls()
        let queue = FailedTranscriptionManager(paths: paths)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: queue,
            speechToText: StatusNoSTT(calls: calls),
            diarization: StatusNoDiarizer(calls: calls),
            speakerStore: StatusMemorySpeakers(calls: calls),
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: paths.transcripts.appendingPathComponent("audio"),
            retainedAudioDirectoryProvider: { paths.transcripts.appendingPathComponent("audio") },
            transcriptDirectoryProvider: { paths.transcripts },
            transcriptFormatOptionsProvider: { TranscriptFormatOptions() },
            statsStore: StatusMemoryStats(calls: calls), notifier: nil
        )
        let original = root.appendingPathComponent("synthetic.bin")
        let bytes = Data([1, 3, 5, 7])
        try bytes.write(to: original)
        var snapshot: RetainedAudioInputSnapshot? = try await .prepare(
            microphoneURL: nil, systemURL: original, scratchRoot: paths.audioCaptures
        )
        defer { snapshot = nil } // Release snapshot ownership before the outer root cleanup.
        let input = try XCTUnwrap(snapshot?.systemURL)
        if discard {
            XCTAssertTrue(snapshot!.discardUnstartedPreparation())
        } else {
            XCTAssertTrue(snapshot!.claimForTranscription(microphoneURL: nil, systemURL: input))
        }
        XCTAssertFalse(snapshot!.claimForTranscription(microphoneURL: nil, systemURL: input),
                       "setup must present a snapshot whose input ownership is unavailable")
        XCTAssertEqual(manager.displayStatus, .idle)
        XCTAssertNil(manager.lastFailureDiagnosticMessage)

        let idle = expectation(description: "rejected saved input eventually publishes idle")
        let events = StatusObservedEvents()
        let subscription = manager.$displayStatus.dropFirst().sink { status in
            events.values.append(status)
            if status == .idle {
                events.diagnosticAtIdle = manager.lastFailureDiagnosticMessage
                idle.fulfill()
            }
        }
        defer { subscription.cancel() }
        manager.startSavedAudioRetranscription(
            micURL: nil, systemURL: input, outputFolder: paths.transcripts, inputSnapshot: snapshot
        )
        // No throwing lookup after admission: always reach the observable completion wait.
        let message = "This saved-audio request was cancelled. Refresh and try again."
        XCTAssertEqual(manager.displayStatus, .failed(message: message))
        XCTAssertEqual(manager.lastFailureDiagnosticMessage, "Saved-audio input ownership unavailable")
        XCTAssertEqual(events.values, [.failed(message: message)])
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertTrue(queue.failedTranscriptions.isEmpty)
        XCTAssertEqual(calls.count, 0)

        // A generous watchdog prevents a hung regression; no elapsed-time or delay-budget assertion.
        await fulfillment(of: [idle], timeout: 30)
        XCTAssertEqual(events.values, [.failed(message: message), .idle])
        XCTAssertNil(events.diagnosticAtIdle, "failure diagnostics clear before the idle publication")
        XCTAssertEqual(manager.displayStatus, .idle)
        XCTAssertNil(manager.lastFailureDiagnosticMessage)
        XCTAssertNil(manager.lastFailureErrorKind)
        XCTAssertNil(manager.lastSpeakerFinalizationFailure)
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertTrue(queue.failedTranscriptions.isEmpty)
        XCTAssertEqual(calls.count, 0, "no STT, diarization, speaker or stats operation is permitted")
        XCTAssertEqual(try Data(contentsOf: original), bytes)
        XCTAssertEqual(FileManager.default.fileExists(atPath: input.path), !discard)
    }
}

@MainActor
private final class StatusObservedEvents {
    var values: [DisplayStatus] = []
    var diagnosticAtIdle: String? = "not-observed"
}

private enum StatusFixtureError: Error { case unowned, unexpectedPipeline }

private func removeStatusFixture(_ root: URL, parent: URL) throws {
    let resolved = root.resolvingSymlinksInPath().standardizedFileURL
    let prefix = "saved-input-status-"
    let leaf = root.lastPathComponent
    guard root == resolved, resolved.deletingLastPathComponent() == parent,
          leaf.hasPrefix(prefix),
          let uuid = UUID(uuidString: String(leaf.dropFirst(prefix.count))),
          uuid.uuidString == String(leaf.dropFirst(prefix.count)).uppercased() else {
        throw StatusFixtureError.unowned
    }
    var info = stat()
    guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
          info.st_uid == getuid(), (info.st_mode & 0o777) == 0o700 else {
        throw StatusFixtureError.unowned
    }
    try FileManager.default.removeItem(at: root)
}

private final class StatusUnexpectedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}

@MainActor
private final class StatusNoSTT: SpeechToTextEngine {
    let calls: StatusUnexpectedCalls
    init(calls: StatusUnexpectedCalls) { self.calls = calls }
    var isReady: Bool { calls.record(); return false }
    func initialize() async { calls.record() }
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        calls.record(); throw StatusFixtureError.unexpectedPipeline
    }
    func resolveLanguage(representativeSamples: [[Float]], selection: TranscriptionLanguageSelection) async throws -> TranscriptionLanguageContext {
        calls.record(); throw StatusFixtureError.unexpectedPipeline
    }
    func transcribeSegment(samples: [Float], source: AudioSource, language: TranscriptionLanguageContext) async throws -> String {
        calls.record(); throw StatusFixtureError.unexpectedPipeline
    }
    var usesRepresentativeLanguageSamples: Bool { calls.record(); return false }
    var packedSegmentWindowSamples: Int? { calls.record(); return nil }
    func transcribePackedSegments(_ segments: [[Float]], source: AudioSource, language: TranscriptionLanguageContext) async throws -> [String]? {
        calls.record(); throw StatusFixtureError.unexpectedPipeline
    }
    func cleanup() { calls.record() }
}

@MainActor
private final class StatusNoDiarizer: DiarizationEngine {
    nonisolated let calls: StatusUnexpectedCalls
    init(calls: StatusUnexpectedCalls) { self.calls = calls }
    var isReady: Bool { calls.record(); return false }
    func initialize() async { calls.record() }
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        calls.record(); throw StatusFixtureError.unexpectedPipeline
    }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        calls.record(); throw StatusFixtureError.unexpectedPipeline
    }
    nonisolated func prewarmVoiceprintInBackground() { calls.record() }
    func cleanup() { calls.record() }
}

private final class StatusMemoryStats: StatsStore {
    let calls: StatusUnexpectedCalls
    init(calls: StatusUnexpectedCalls) { self.calls = calls }
    func recordSession(_ metadata: RecordingMetadata) { calls.record() }
    func getTotalRecordingsCount() -> Int { calls.record(); return 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { calls.record(); return [] }
    func recordingExists(transcriptPath: String) -> Bool { calls.record(); return false }
}

private final class StatusMemorySpeakers: SpeakerStore, @unchecked Sendable {
    let calls: StatusUnexpectedCalls
    init(calls: StatusUnexpectedCalls) { self.calls = calls }
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
