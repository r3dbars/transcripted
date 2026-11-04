import AVFoundation
import Combine
import FluidAudio
import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testSavedReprocessInputsSurviveTaskReturnAndDeferredReviewRetryHandoff() async throws {
        try await exerciseSnapshotReviewFailure(blockPersistence: false)
    }

    func testSavedReprocessReviewPersistenceFailureLeavesOwnedInputsInPlace() async throws {
        try await exerciseSnapshotReviewFailure(blockPersistence: true)
    }

    func testSavedReprocessCancellationKeepsInputsUntilNoncooperativeEngineReturns() async throws {
        let engine = SnapshotHeldSpeechEngine()
        let manager = makeManager(speechToText: engine,
                                  diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 3)))
        let original = tempDirectory.appendingPathComponent("retained.wav")
        try writeMonoWAV(to: original, duration: 3)
        var snapshot: RetainedAudioInputSnapshot? = try await .prepare(
            microphoneURL: nil, systemURL: original,
            scratchRoot: tempDirectory.appendingPathComponent("audio")
        )
        let input = snapshot!.systemURL
        weak var owner = snapshot
        manager.startSavedAudioRetranscription(
            micURL: nil, systemURL: input, outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            inputSnapshot: snapshot
        )
        snapshot = nil
        var work: Task<Void, Never>? = try XCTUnwrap(manager.activeTasks.values.first)
        try await waitUntil { engine.didStart }
        manager.cancelAll()
        XCTAssertNotNil(owner)
        XCTAssertFalse(manager.activeTasks.isEmpty, "cancellation status cannot end native input ownership")
        XCTAssertEqual(try AudioResampler.loadAndResample(url: input).count, 48_000)
        engine.finish()
        await work!.value
        work = nil
        XCTAssertNil(owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testRejectedSavedReprocessDropsOnlyItsOwnedSnapshot() async throws {
        let manager = makeManager()
        let occupiedID = UUID()
        manager.activeTasks[occupiedID] = Task {}
        defer { manager.activeTasks.removeValue(forKey: occupiedID) }
        let original = tempDirectory.appendingPathComponent("retained-rejected.wav")
        try writeMonoWAV(to: original, duration: 3)
        var snapshot: RetainedAudioInputSnapshot? = try await .prepare(
            microphoneURL: nil, systemURL: original,
            scratchRoot: tempDirectory.appendingPathComponent("audio")
        )
        let input = snapshot!.systemURL
        manager.startSavedAudioRetranscription(
            micURL: nil, systemURL: input, outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            inputSnapshot: snapshot
        )
        snapshot = nil
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(try AudioResampler.loadAndResample(url: original).count, 48_000)
        XCTAssertEqual(Set(manager.activeTasks.keys), [occupiedID])
    }

    func testSavedReprocessModelPreparationFailureCleansOnlyItsSnapshot() async throws {
        let manager = makeManager(speechToText: SnapshotUnreadySpeechEngine())
        let original = tempDirectory.appendingPathComponent("retained-unready.wav")
        try writeMonoWAV(to: original, duration: 3)
        var snapshot: RetainedAudioInputSnapshot? = try await .prepare(
            microphoneURL: nil, systemURL: original, scratchRoot: tempDirectory.appendingPathComponent("audio")
        )
        let input = snapshot!.systemURL
        manager.startSavedAudioRetranscription(
            micURL: nil, systemURL: input, outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            inputSnapshot: snapshot
        )
        snapshot = nil
        var work: Task<Void, Never>? = try XCTUnwrap(manager.activeTasks.values.first)
        await work!.value
        work = nil
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.path))
        XCTAssertEqual(try AudioResampler.loadAndResample(url: original).count, 48_000)
    }

    func testDualTrackReprocessReloadsOwnedMicrophoneAfterTheSystemPhase() async throws {
        let engine = SnapshotDualTrackSpeechEngine()
        let manager = makeManager(speechToText: engine,
                                  diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 3)))
        let observed = SnapshotResultRecorder()
        manager.pipelineResultObserver = { observed.record($0) }
        let originalMic = tempDirectory.appendingPathComponent("retained-microphone.wav")
        let originalSystem = tempDirectory.appendingPathComponent("retained-system.wav")
        try writeMonoWAV(to: originalMic, duration: 3)
        try writeMonoWAV(to: originalSystem, duration: 3)
        var snapshot: RetainedAudioInputSnapshot? = try await .prepare(
            microphoneURL: originalMic, systemURL: originalSystem,
            scratchRoot: tempDirectory.appendingPathComponent("audio")
        )
        let microphone = try XCTUnwrap(snapshot?.microphoneURL)
        let system = try XCTUnwrap(snapshot?.systemURL)
        weak var owner = snapshot
        manager.startSavedAudioRetranscription(
            micURL: microphone, systemURL: system,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"), inputSnapshot: snapshot
        )
        snapshot = nil
        var work: Task<Void, Never>? = try XCTUnwrap(manager.activeTasks.values.first)
        try await waitUntil { engine.systemDidStart }
        XCTAssertTrue(engine.microphoneSampleCounts.isEmpty, "the call track is held before the delayed microphone phase")
        try FileManager.default.removeItem(at: originalMic)
        try FileManager.default.removeItem(at: originalSystem)
        XCTAssertEqual(try AudioResampler.loadAndResample(url: microphone).count, 48_000)
        engine.finishSystem()
        await work!.value
        work = nil
        let result = try XCTUnwrap(observed.result)
        XCTAssertEqual(result.microphoneAudioOutcome, .usable)
        XCTAssertEqual(result.micUtterances.map(\.transcript), ["Owned microphone words."])
        XCTAssertEqual(engine.microphoneSampleCounts, [48_000], "the actual late reload still provides the full owned mic input")
        XCTAssertNotNil(owner, "pending review owns both inputs after task completion")
        manager.cleanupPendingNaming()
        XCTAssertNil(owner)
        XCTAssertFalse(FileManager.default.fileExists(atPath: microphone.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: system.path))
    }

    private func exerciseSnapshotReviewFailure(blockPersistence: Bool) async throws {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Owned reprocess fixture words."),
            diarization: MetadataStubDiarizationEngine(segments: singleSpeakerSegments(duration: 3))
        )
        let original = tempDirectory.appendingPathComponent("retained-review.wav")
        try writeMonoWAV(to: original, duration: 3)
        var snapshot: RetainedAudioInputSnapshot? = try await .prepare(
            microphoneURL: nil, systemURL: original,
            scratchRoot: tempDirectory.appendingPathComponent("audio")
        )
        let input = snapshot!.systemURL
        let directory = snapshot!.directory
        weak var owner = snapshot
        let transcriptID = UUID()
        let transcript = tempDirectory.appendingPathComponent("transcripts/Selected.md")
        try ("---\ncapture_type: meeting\ntranscript_id: \"\(transcriptID.uuidString)\"\n"
             + "title: Synthetic saved meeting\n---\n\n## Full Transcript\n\nSynthetic original words.\n")
            .write(to: transcript, atomically: true, encoding: .utf8)
        // A user/library maintenance operation can remove the original as soon
        // as admission succeeds. All pipeline and later review reads use input.
        try FileManager.default.removeItem(at: original)
        manager.startSavedAudioRetranscription(
            micURL: nil, systemURL: input, outputFolder: transcript.deletingLastPathComponent(),
            replacementTranscriptURL: transcript, inputSnapshot: snapshot,
            expectedReplacementTranscriptID: transcriptID
        )
        snapshot = nil
        var work: Task<Void, Never>? = try XCTUnwrap(manager.activeTasks.values.first)
        await work!.value
        work = nil
        XCTAssertTrue(manager.activeTasks.isEmpty)
        XCTAssertNotNil(owner, "the queued real speaker review must own inputs after the transcription task returns")
        XCTAssertEqual(try AudioResampler.loadAndResample(url: input).count, 48_000)
        var request = try XCTUnwrap(manager.speakerNamingRequest)
        XCTAssertEqual(request.systemAudioURL, input)
        try FileManager.default.removeItem(at: transcript)
        let queue = tempDirectory.appendingPathComponent("failed_transcriptions.json")
        if blockPersistence {
            try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: false)
        }
        request.onComplete([])
        // Drop this local callback as well as the manager's completed request.
        request = SpeakerNamingRequest(speakers: [], transcriptURL: transcript,
                                       transcriptId: UUID(), systemAudioURL: input,
                                       micAudioURL: nil, onComplete: { _ in })
        try await waitUntil {
            manager.speakerNamingRequest == nil && {
                if case .failed = manager.displayStatus { return true }
                return false
            }()
        }
        try await waitUntil { owner == nil }
        XCTAssertEqual(try AudioResampler.loadAndResample(url: input).count, 48_000,
                       "late review failure must preserve readable bytes after every snapshot owner is released")
        if blockPersistence {
            XCTAssertTrue(manager.failedTranscriptionManager.failedTranscriptions.isEmpty)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
        } else {
            let paths = CoreStoragePaths(
                transcripts: transcript.deletingLastPathComponent(),
                speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
                statsDB: tempDirectory.appendingPathComponent("stats.sqlite"), failedQueue: queue,
                speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
                audioCaptures: tempDirectory.appendingPathComponent("audio"), logs: tempDirectory.appendingPathComponent("logs")
            )
            let reopened = FailedTranscriptionManager(paths: paths)
            let retry = try XCTUnwrap(reopened.failedTranscriptions.first)
            XCTAssertEqual(retry.systemAudioURL, input)
            XCTAssertEqual(try AudioResampler.loadAndResample(url: try XCTUnwrap(retry.systemAudioURL)).count, 48_000)
            XCTAssertTrue(reopened.deleteFailedTranscription(id: retry.id))
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "normal failed-row deletion retires the owned snapshot folder")
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class SnapshotHeldSpeechEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    var didStart = false
    private var completion: CheckedContinuation<String, Never>?
    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        didStart = true
        return await withCheckedContinuation { completion = $0 }
    }
    func finish() { completion?.resume(returning: "Synthetic resumed words."); completion = nil }
    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class SnapshotDualTrackSpeechEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    var usesRepresentativeLanguageSamples: Bool { false }
    var systemDidStart = false
    var microphoneSampleCounts: [Int] = []
    private var completion: CheckedContinuation<String, Never>?
    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        switch source {
        case .system:
            systemDidStart = true
            return await withCheckedContinuation { completion = $0 }
        case .microphone:
            microphoneSampleCounts.append(samples.count)
            return "Owned microphone words."
        }
    }
    func finishSystem() { completion?.resume(returning: "Owned system words."); completion = nil }
    func cleanup() {}
}

private final class SnapshotResultRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: TranscriptionResult?
    var result: TranscriptionResult? { lock.withLock { stored } }
    func record(_ result: TranscriptionResult) { lock.withLock { stored = result } }
}

@available(macOS 14.0, *)
@MainActor
private final class SnapshotUnreadySpeechEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = false
    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        XCTFail("an unavailable model must not receive snapshot audio")
        return ""
    }
    func cleanup() {}
}
