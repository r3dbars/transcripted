import Foundation
import Combine
import FluidAudio
import XCTest
@testable import TranscriptedCore

/// Sole, serialized fixture for the existing process-global archive hooks.
/// Tiny canary bytes are copied, never decoded or passed to an audio engine.
@MainActor
final class FailedAudioArchiveManagerIntegrationTests: XCTestCase {
    func testManualArchiveUsesBackgroundCopyThenDurableMainActorApply() async {
        await withArchiveFixture(mode: .copy) { fixture in
            XCTAssertTrue(fixture.admit())
            fixture.assertOriginalRow()
            try fixture.assertDiskRowsMatch()
            await fixture.waitForArchives()
            let row = try XCTUnwrap(fixture.queue.failedTranscriptions.first)
            XCTAssertEqual(fixture.queue.count, 1)
            XCTAssertTrue(fixture.isArchived(row.micAudioURL))
            XCTAssertTrue(fixture.isArchived(try XCTUnwrap(row.systemAudioURL)))
            XCTAssertEqual(try Data(contentsOf: row.micAudioURL), fixture.micBytes)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(row.systemAudioURL)), fixture.systemBytes)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.mic.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.system.path))
            try fixture.assertDiskRowsMatch()
            XCTAssertFalse(fixture.probe.values.isEmpty, "actual archive work must hit the existing thread probe")
            XCTAssertTrue(fixture.probe.values.allSatisfy { !$0 }, "copy work must leave the main thread")
        }
    }

    func testPartialArchiveKeepsUncopiedOriginalAndSettles() async {
        await withArchiveFixture(mode: .rejectMic) { fixture in
            XCTAssertTrue(fixture.admit())
            fixture.assertOriginalRow()
            try fixture.assertDiskRowsMatch()
            await fixture.waitForArchives()
            let row = try XCTUnwrap(fixture.queue.failedTranscriptions.first)
            XCTAssertEqual(fixture.queue.count, 1)
            XCTAssertEqual(fixture.identity(row.micAudioURL), fixture.identity(fixture.mic))
            XCTAssertTrue(fixture.isArchived(try XCTUnwrap(row.systemAudioURL)))
            XCTAssertEqual(try Data(contentsOf: row.micAudioURL), fixture.micBytes)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(row.systemAudioURL)), fixture.systemBytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.mic.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.system.path))
            try fixture.assertDiskRowsMatch()
        }
    }

    func testTotalArchiveFailureCompletesWithoutLosingOriginalRow() async {
        await withArchiveFixture(mode: .rejectBoth) { fixture in
            XCTAssertTrue(fixture.admit())
            fixture.assertOriginalRow()
            try fixture.assertDiskRowsMatch()
            await fixture.waitForArchives()
            fixture.assertOriginalRow()
            XCTAssertEqual(try Data(contentsOf: fixture.mic), fixture.micBytes)
            XCTAssertEqual(try Data(contentsOf: fixture.system), fixture.systemBytes)
            try fixture.assertDiskRowsMatch()
            XCTAssertEqual(try fixture.archiveChildren(), [], "failed empty archive directory must be removed")
        }
    }

    func testDeletingRowWhileCopiedAudioIsHeldDoesNotResurrectIt() async {
        await withArchiveFixture(mode: .holdAfterMicCopy) { fixture in
            XCTAssertTrue(fixture.admit()) // Captures completion synchronously inside admit.
            fixture.assertOriginalRow()
            // Positive-event watchdog only; never a speed assertion. A failed
            // watchdog still releases and joins the worker before any cleanup.
            let result = await XCTWaiter.fulfillment(of: [fixture.files.entered], timeout: 30)
            XCTAssertEqual(result, .completed)
            if result == .completed {
                XCTAssertTrue(fixture.queue.deleteFailedTranscription(id: fixture.rowID))
                XCTAssertTrue(fixture.queue.failedTranscriptions.isEmpty)
            }
            fixture.files.release()
            await fixture.waitForArchives()
            XCTAssertTrue(fixture.queue.failedTranscriptions.isEmpty)
            XCTAssertEqual(try fixture.diskRows(), [])
            XCTAssertEqual(try fixture.archiveChildren(), [], "missing-row apply must roll back copied audio")
        }
    }
}

@MainActor
private func withArchiveFixture(
    mode: ArchiveOwnedFileManager.Mode,
    body: (ArchiveManagerFixture) async throws -> Void
) async {
    guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
        XCTFail("disable the file logger before constructing the owned manager fixture")
        return
    }
    let fixture: ArchiveManagerFixture
    do { fixture = try ArchiveManagerFixture(mode: mode) }
    catch { XCTFail("owned archive fixture setup failed"); return }
    fixture.installHooks() // ALL throwing setup and initial file writes finished.
    do { try await body(fixture) }
    catch { XCTFail("owned archive fixture assertion/read failed") }
    await fixture.cleanup()
}

@MainActor
private final class ArchiveManagerFixture {
    let parent: URL
    let root: URL
    let paths: CoreStoragePaths
    let archive: URL
    let mic: URL
    let system: URL
    let rowID = UUID(uuidString: "381822CB-DDA9-44CA-B4F4-390A44717B1B")!
    let micBytes = Data([0x11, 0x23, 0x35, 0x47])
    let systemBytes = Data([0x52, 0x64, 0x76])
    let calls = ArchiveUnexpectedCalls()
    let probe = ArchiveThreadProbe()
    let files: ArchiveOwnedFileManager
    let queue: FailedTranscriptionManager
    let manager: TranscriptionTaskManager
    private var completions: [FailedAudioArchiveJobs.Completion] = []

    init(mode: ArchiveOwnedFileManager.Mode) throws {
        let fm = FileManager.default
        parent = fm.temporaryDirectory.resolvingSymlinksInPath().standardizedFileURL
        root = parent.appendingPathComponent("failed-audio-archive-" + UUID().uuidString, isDirectory: true)
        paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("unused-speakers.sqlite"),
            statsDB: root.appendingPathComponent("unused-stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed.json"),
            speakerClips: root.appendingPathComponent("clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("scratch", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
        archive = paths.transcripts.appendingPathComponent("audio", isDirectory: true)
        mic = paths.audioCaptures.appendingPathComponent("mic.wav")
        system = paths.audioCaptures.appendingPathComponent("system.wav")
        do {
            for directory in [root, paths.transcripts, archive, paths.audioCaptures,
                              paths.speakerClips, paths.logs, paths.failedQueue.deletingLastPathComponent()] {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            }
            try micBytes.write(to: mic)
            try systemBytes.write(to: system)
        } catch {
            // No hook or producer exists yet. Even setup failure only removes
            // the verified, newly generated fixture root.
            do { try removeArchiveFixtureRoot(root, parent: parent) }
            catch { XCTFail("owned archive setup cleanup failed") }
            throw ArchiveFixtureError.setup
        }
        files = ArchiveOwnedFileManager(root: root, mode: mode)
        queue = FailedTranscriptionManager(paths: paths)
        let retainedDirectory = archive
        let transcriptDirectory = paths.transcripts
        manager = TranscriptionTaskManager(
            failedTranscriptionManager: queue,
            speechToText: ArchiveNoSTT(calls: calls),
            diarization: ArchiveNoDiarizer(calls: calls),
            speakerStore: ArchiveMemorySpeakers(calls: calls),
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: archive,
            retainedAudioDirectoryProvider: { retainedDirectory },
            transcriptDirectoryProvider: { transcriptDirectory },
            transcriptFormatOptionsProvider: { TranscriptFormatOptions() },
            statsStore: ArchiveMemoryStats(calls: calls), notifier: nil
        )
    }

    func installHooks() {
        TranscriptionTaskManager.setFailedAudioArchiveFileManager(files)
        TranscriptionTaskManager.setFailedAudioArchiveThreadProbe { [probe] in probe.append($0) }
    }

    func admit() -> Bool {
        let accepted = manager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: mic, systemAudioURL: system, errorMessage: "synthetic archive failure",
            taskId: rowID, archiveAudio: true, clearRecordingJournalAfterPersistence: false
        )
        // Snapshot before returning to any throwing assertion or suspension.
        completions.append(manager.beginWaitingForScheduledFailedAudioArchives())
        return accepted
    }

    func waitForArchives() async {
        for completion in completions { await completion.wait() }
    }

    func assertOriginalRow() {
        XCTAssertEqual(queue.count, 1)
        XCTAssertEqual(queue.failedTranscriptions.first?.id, rowID)
        XCTAssertEqual(queue.failedTranscriptions.first.map { identity($0.micAudioURL) }, identity(mic))
        XCTAssertEqual(queue.failedTranscriptions.first?.systemAudioURL.map(identity), identity(system))
    }

    func identity(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
    func isArchived(_ url: URL) -> Bool { identity(url).hasPrefix(identity(archive) + "/") }

    func diskRows() throws -> [FailedTranscription] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([FailedTranscription].self, from: Data(contentsOf: paths.failedQueue))
    }

    func assertDiskRowsMatch() throws {
        let disk = try diskRows()
        XCTAssertEqual(disk.count, queue.failedTranscriptions.count)
        for (saved, live) in zip(disk, queue.failedTranscriptions) {
            XCTAssertEqual(saved.id, live.id)
            XCTAssertEqual(identity(saved.micAudioURL), identity(live.micAudioURL))
            XCTAssertEqual(saved.systemAudioURL.map(identity), live.systemAudioURL.map(identity))
            XCTAssertEqual(saved.errorMessage, live.errorMessage)
            XCTAssertEqual(saved.meetingTitle, live.meetingTitle)
            XCTAssertEqual(saved.retryCount, live.retryCount)
        }
        // ISO-8601 persistence rounds timestamps; compare durable row identity,
        // paths and unchanged metadata rather than in-memory subsecond precision.
    }

    func archiveChildren() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: archive.path).sorted()
    }

    func cleanup() async {
        files.release() // Release EVERY held producer before waiting/reset/delete.
        await waitForArchives()
        TranscriptionTaskManager.setFailedAudioArchiveFileManager(nil)
        TranscriptionTaskManager.setFailedAudioArchiveThreadProbe(nil)
        XCTAssertEqual(calls.count, 0, "no STT, diarization, speaker or stats operation is permitted")
        do { try removeArchiveFixtureRoot(root, parent: parent) }
        catch { XCTFail("owned archive fixture cleanup failed") }
    }
}

private enum ArchiveFixtureError: Error { case setup, unowned, copyRejected, unexpectedPipeline }

private func removeArchiveFixtureRoot(_ root: URL, parent: URL) throws {
    let canonical = root.resolvingSymlinksInPath().standardizedFileURL
    let leaf = root.lastPathComponent
    guard root == canonical, canonical.deletingLastPathComponent() == parent,
          leaf.hasPrefix("failed-audio-archive-"),
          UUID(uuidString: String(leaf.dropFirst("failed-audio-archive-".count))) != nil else {
        throw ArchiveFixtureError.unowned
    }
    let metadata = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { throw ArchiveFixtureError.unowned }
    try FileManager.default.removeItem(at: root)
}

private final class ArchiveOwnedFileManager: FileManager, @unchecked Sendable {
    enum Mode { case copy, rejectMic, rejectBoth, holdAfterMicCopy }
    let entered = XCTestExpectation(description: "owned microphone bytes copied before return")
    private let root: URL
    private let mode: Mode
    private let condition = NSCondition()
    private var released = false

    init(root: URL, mode: Mode) { self.root = root; self.mode = mode; super.init() }

    override func copyItem(at source: URL, to destination: URL) throws {
        let canonicalSource = source.resolvingSymlinksInPath().standardizedFileURL
        let destinationParent = destination.deletingLastPathComponent()
        let canonicalParent = destinationParent.resolvingSymlinksInPath().standardizedFileURL
        let sourceMetadata = try source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        let parentMetadata = try destinationParent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard canonicalSource.path.hasPrefix(root.path + "/"), source == canonicalSource,
              sourceMetadata.isRegularFile == true, sourceMetadata.isSymbolicLink != true,
              canonicalParent.path.hasPrefix(root.path + "/"), destinationParent == canonicalParent,
              parentMetadata.isDirectory == true, parentMetadata.isSymbolicLink != true,
              !destination.lastPathComponent.isEmpty else { throw ArchiveFixtureError.unowned }
        if mode == .rejectBoth || (mode == .rejectMic && source.lastPathComponent == "mic.wav") {
            throw ArchiveFixtureError.copyRejected
        }
        try super.copyItem(at: source, to: destination)
        if mode == .holdAfterMicCopy && source.lastPathComponent == "mic.wav" {
            entered.fulfill()
            condition.lock()
            while !released { condition.wait() }
            condition.unlock()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ArchiveUnexpectedCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func record() { lock.lock(); value += 1; lock.unlock() }
}

private final class ArchiveThreadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var values: [Bool] { lock.lock(); defer { lock.unlock() }; return recorded }
    func append(_ value: Bool) { lock.lock(); recorded.append(value); lock.unlock() }
}

@MainActor
private final class ArchiveNoSTT: SpeechToTextEngine {
    let calls: ArchiveUnexpectedCalls
    init(calls: ArchiveUnexpectedCalls) { self.calls = calls }
    var isReady: Bool { calls.record(); return false }
    func initialize() async { calls.record() }
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        calls.record(); throw ArchiveFixtureError.unexpectedPipeline
    }
    func resolveLanguage(representativeSamples: [[Float]], selection: TranscriptionLanguageSelection) async throws -> TranscriptionLanguageContext {
        calls.record(); throw ArchiveFixtureError.unexpectedPipeline
    }
    func transcribeSegment(samples: [Float], source: AudioSource, language: TranscriptionLanguageContext) async throws -> String {
        calls.record(); throw ArchiveFixtureError.unexpectedPipeline
    }
    var usesRepresentativeLanguageSamples: Bool { calls.record(); return false }
    var packedSegmentWindowSamples: Int? { calls.record(); return nil }
    func transcribePackedSegments(_ segments: [[Float]], source: AudioSource, language: TranscriptionLanguageContext) async throws -> [String]? {
        calls.record(); throw ArchiveFixtureError.unexpectedPipeline
    }
    func cleanup() { calls.record() }
}

@MainActor
private final class ArchiveNoDiarizer: DiarizationEngine {
    nonisolated let calls: ArchiveUnexpectedCalls
    init(calls: ArchiveUnexpectedCalls) { self.calls = calls }
    var isReady: Bool { calls.record(); return false }
    func initialize() async { calls.record() }
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        calls.record(); throw ArchiveFixtureError.unexpectedPipeline
    }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        calls.record(); throw ArchiveFixtureError.unexpectedPipeline
    }
    nonisolated func prewarmVoiceprintInBackground() { calls.record() }
    func cleanup() { calls.record() }
}

private final class ArchiveMemoryStats: StatsStore {
    let calls: ArchiveUnexpectedCalls
    init(calls: ArchiveUnexpectedCalls) { self.calls = calls }
    func recordSession(_ metadata: RecordingMetadata) { calls.record() }
    func getTotalRecordingsCount() -> Int { calls.record(); return 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { calls.record(); return [] }
    func recordingExists(transcriptPath: String) -> Bool { calls.record(); return false }
}

private final class ArchiveMemorySpeakers: SpeakerStore, @unchecked Sendable {
    let calls: ArchiveUnexpectedCalls
    init(calls: ArchiveUnexpectedCalls) { self.calls = calls }
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
