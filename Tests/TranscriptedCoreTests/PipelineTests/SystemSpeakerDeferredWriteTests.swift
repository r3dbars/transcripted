import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

/// Regression tests for P3:
/// - System-channel `speakerDB` writes (new profile creation, embedding blends,
///   `call_count` bumps, exemplars, provenance rows) are deferred until after
///   system STT, mic STT, and `Task.checkCancellation()` succeed.
/// - `TranscriptionPipelineRunner` checks cancellation before running
///   `mergeDuplicates` and `pruneWeakProfiles`.
@available(macOS 14.0, *)
final class SystemSpeakerDeferredWriteTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SystemSpeakerDeferredWriteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    private func axisEmbedding(_ axis: Int, dim: Int = 256) -> [Float] {
        var vector = [Float](repeating: 0.0, count: dim)
        vector[axis] = 1.0
        return vector
    }

    private func writeMonoWAV(to url: URL, durationSeconds: Double = 4.0) throws {
        let sampleRate = 16_000.0
        let count = Int(sampleRate * durationSeconds)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = (i % 2 == 0) ? 0.08 : -0.08
        }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        let channel = try XCTUnwrap(buffer.floatChannelData?[0])
        samples.withUnsafeBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return }
            channel.update(from: base, count: count)
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        try file.write(from: buffer)
    }

    private func makePaths() -> CoreStoragePaths {
        CoreStoragePaths(
            transcripts: tempRoot.appendingPathComponent("transcripts", isDirectory: true),
            speakerDB: tempRoot.appendingPathComponent("speakers.sqlite"),
            statsDB: tempRoot.appendingPathComponent("stats.sqlite"),
            failedQueue: tempRoot.appendingPathComponent("failed.json"),
            speakerClips: tempRoot.appendingPathComponent("clips", isDirectory: true),
            audioCaptures: tempRoot.appendingPathComponent("captures", isDirectory: true),
            logs: tempRoot.appendingPathComponent("logs", isDirectory: true)
        )
    }

    @MainActor
    func testFailedSystemSTTLeavesSpeakerDatabaseUntouched() async throws {
        let systemURL = tempRoot.appendingPathComponent("system.wav")
        try writeMonoWAV(to: systemURL)

        let speakerDB = SpeakerDatabase(path: tempRoot.appendingPathComponent("speakers.sqlite").path)
        let knownEmbedding = axisEmbedding(0)
        let existing = speakerDB.addOrUpdateSpeaker(embedding: knownEmbedding, existingId: nil)
        speakerDB.setDisplayName(id: existing.id, name: "Jordan", source: NameSource.userManual)
        let beforeKnown = try XCTUnwrap(speakerDB.getSpeaker(id: existing.id))
        let beforeContributions = speakerDB.contributions(forProfileId: existing.id).count

        // One matched speaker (axis 0) + one new unknown speaker (axis 5).
        let segments = [
            SpeakerSegment(speakerId: 1, startTime: 0.0, endTime: 2.0, embedding: knownEmbedding, qualityScore: 0.95),
            SpeakerSegment(speakerId: 2, startTime: 2.0, endTime: 4.0, embedding: axisEmbedding(5), qualityScore: 0.95),
        ]
        let sttError = PipelineError.modelInferenceFailed(model: "Parakeet", underlying: "simulated failure")
        let transcription = Transcription(
            speechToText: DeferredWriteStubSTT(behavior: .failOnSource(.system, sttError)),
            diarization: DeferredWriteStubDiarizer(segments: segments),
            speakerStore: speakerDB,
            speakerClipsDirectory: tempRoot.appendingPathComponent("clips", isDirectory: true)
        )

        do {
            _ = try await transcription.transcribeMultichannel(micURL: nil, systemURL: systemURL)
            XCTFail("Expected system STT failure to propagate")
        } catch {
            // Expected
        }

        XCTAssertEqual(speakerDB.allSpeakers().count, 1, "failed STT must not insert new profiles")
        let afterKnown = try XCTUnwrap(speakerDB.getSpeaker(id: existing.id))
        XCTAssertEqual(afterKnown.callCount, beforeKnown.callCount, "failed STT must not bump call_count")
        XCTAssertEqual(afterKnown.embedding, beforeKnown.embedding, "failed STT must not blend embedding")
        XCTAssertEqual(afterKnown.exemplars, beforeKnown.exemplars)
        XCTAssertEqual(speakerDB.contributions(forProfileId: existing.id).count, beforeContributions)
    }

    @MainActor
    func testCancelledMultichannelSystemSTTLeavesSpeakerDatabaseUntouched() async throws {
        let systemURL = tempRoot.appendingPathComponent("system.wav")
        try writeMonoWAV(to: systemURL)

        let speakerDB = SpeakerDatabase(path: tempRoot.appendingPathComponent("speakers.sqlite").path)
        let knownEmbedding = axisEmbedding(1)
        let existing = speakerDB.addOrUpdateSpeaker(embedding: knownEmbedding, existingId: nil)
        let beforeKnown = try XCTUnwrap(speakerDB.getSpeaker(id: existing.id))

        let segments = [
            SpeakerSegment(speakerId: 1, startTime: 0.0, endTime: 2.0, embedding: knownEmbedding, qualityScore: 0.95),
            SpeakerSegment(speakerId: 2, startTime: 2.0, endTime: 4.0, embedding: axisEmbedding(6), qualityScore: 0.95),
        ]
        let transcription = Transcription(
            speechToText: DeferredWriteStubSTT(behavior: .cancelOnSource(.system)),
            diarization: DeferredWriteStubDiarizer(segments: segments),
            speakerStore: speakerDB,
            speakerClipsDirectory: tempRoot.appendingPathComponent("clips", isDirectory: true)
        )

        do {
            _ = try await transcription.transcribeMultichannel(micURL: nil, systemURL: systemURL)
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }

        XCTAssertEqual(speakerDB.allSpeakers().count, 1, "cancelled STT must not create profiles")
        let afterKnown = try XCTUnwrap(speakerDB.getSpeaker(id: existing.id))
        XCTAssertEqual(afterKnown.callCount, beforeKnown.callCount)
        XCTAssertEqual(afterKnown.embedding, beforeKnown.embedding)
        XCTAssertEqual(speakerDB.contributions(forProfileId: existing.id).count, 1)
    }

    @MainActor
    func testCancelledMicPhaseLeavesSystemSpeakerDatabaseUntouched() async throws {
        let micURL = tempRoot.appendingPathComponent("mic.wav")
        let systemURL = tempRoot.appendingPathComponent("system.wav")
        try writeMonoWAV(to: micURL)
        try writeMonoWAV(to: systemURL)

        let speakerDB = SpeakerDatabase(path: tempRoot.appendingPathComponent("speakers.sqlite").path)
        let knownEmbedding = axisEmbedding(2)
        let existing = speakerDB.addOrUpdateSpeaker(embedding: knownEmbedding, existingId: nil)
        let beforeKnown = try XCTUnwrap(speakerDB.getSpeaker(id: existing.id))

        let segments = [
            SpeakerSegment(speakerId: 1, startTime: 0.0, endTime: 2.0, embedding: knownEmbedding, qualityScore: 0.95),
            SpeakerSegment(speakerId: 2, startTime: 2.0, endTime: 4.0, embedding: axisEmbedding(7), qualityScore: 0.95),
        ]
        let transcription = Transcription(
            speechToText: DeferredWriteStubSTT(behavior: .cancelOnSource(.microphone)),
            diarization: DeferredWriteStubDiarizer(segments: segments),
            speakerStore: speakerDB,
            speakerClipsDirectory: tempRoot.appendingPathComponent("clips", isDirectory: true)
        )

        do {
            _ = try await transcription.transcribeMultichannel(micURL: micURL, systemURL: systemURL)
            XCTFail("Expected CancellationError during mic STT")
        } catch is CancellationError {
            // Expected
        }

        XCTAssertEqual(speakerDB.allSpeakers().count, 1, "cancellation during mic phase must not leave system profiles behind")
        let afterKnown = try XCTUnwrap(speakerDB.getSpeaker(id: existing.id))
        XCTAssertEqual(afterKnown.callCount, beforeKnown.callCount)
        XCTAssertEqual(afterKnown.embedding, beforeKnown.embedding)
    }

    @MainActor
    func testCancelledSplitMicMultichannelLeavesSpeakerDatabaseUntouched() async throws {
        let micURL = tempRoot.appendingPathComponent("mic_split.wav")
        let systemURL = tempRoot.appendingPathComponent("system_split.wav")
        try writeMonoWAV(to: micURL)
        try writeMonoWAV(to: systemURL)

        let speakerDB = SpeakerDatabase(path: tempRoot.appendingPathComponent("speakers.sqlite").path)
        let knownEmbedding = axisEmbedding(3)
        let existing = speakerDB.addOrUpdateSpeaker(embedding: knownEmbedding, existingId: nil)
        let beforeKnown = try XCTUnwrap(speakerDB.getSpeaker(id: existing.id))

        let segments = [
            SpeakerSegment(speakerId: 1, startTime: 0.0, endTime: 2.0, embedding: knownEmbedding, qualityScore: 0.95),
            SpeakerSegment(speakerId: 2, startTime: 2.0, endTime: 4.0, embedding: axisEmbedding(8), qualityScore: 0.95),
        ]
        let transcription = Transcription(
            speechToText: DeferredWriteStubSTT(behavior: .succeed("split mic spoken words")),
            diarization: DeferredWriteStubDiarizer(segments: segments),
            speakerStore: speakerDB,
            speakerClipsDirectory: tempRoot.appendingPathComponent("clips", isDirectory: true)
        )

        let cancelBox = CancellableTaskBox()
        let running = Task<TranscriptionResult, Error> {
            try await transcription.transcribeMultichannel(
                micURL: micURL,
                systemURL: systemURL,
                splitLocalSpeakers: true,
                onProgress: { progress in
                    // Cancel right after both system STT and split-mic diarization+STT finish,
                    // just before the final commit stage.
                    if progress >= 0.95 {
                        cancelBox.cancel()
                    }
                }
            )
        }
        cancelBox.set { running.cancel() }

        do {
            _ = try await running.value
            XCTFail("Expected CancellationError before speakerDB commit")
        } catch is CancellationError {
            // Expected
        }

        XCTAssertEqual(speakerDB.allSpeakers().count, 1, "cancelled split-mic run must not insert new mic or system profiles")
        let afterKnown = try XCTUnwrap(speakerDB.getSpeaker(id: existing.id))
        XCTAssertEqual(afterKnown.callCount, beforeKnown.callCount, "cancelled split-mic run must not bump call_count")
        XCTAssertEqual(afterKnown.embedding, beforeKnown.embedding, "cancelled split-mic run must not blend embedding")
        XCTAssertEqual(speakerDB.contributions(forProfileId: existing.id).count, 1)
    }

    @MainActor
    func testCancelledPipelineRunnerSkipsDuplicateMergeAndWeakProfilePrune() async throws {
        let systemURL = tempRoot.appendingPathComponent("system.wav")
        let outputFolder = tempRoot.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try writeMonoWAV(to: systemURL)

        let paths = makePaths()
        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        // Seed two identical unnamed profiles (would merge if mergeDuplicates ran)
        // and one stale weak profile (would prune if pruneWeakProfiles ran).
        let dupA = speakerDB.addOrUpdateSpeaker(embedding: axisEmbedding(10), existingId: nil)
        let dupB = speakerDB.addOrUpdateSpeaker(embedding: axisEmbedding(10), existingId: nil)
        let stale = speakerDB.addOrUpdateSpeaker(embedding: axisEmbedding(11), existingId: nil)
        speakerDB.restoreProfile(SpeakerProfile(
            id: stale.id,
            displayName: nil,
            nameSource: nil,
            embedding: stale.embedding,
            firstSeen: Date().addingTimeInterval(-7200),
            lastSeen: Date().addingTimeInterval(-7200),
            callCount: 1,
            confidence: 0.5,
            disputeCount: 0
        ))

        let segments = [
            SpeakerSegment(speakerId: 1, startTime: 0.0, endTime: 4.0, embedding: axisEmbedding(12), qualityScore: 0.95),
        ]
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: DeferredWriteStubSTT(behavior: .succeed("hello from call")),
            diarization: DeferredWriteStubDiarizer(segments: segments),
            speakerStore: speakerDB,
            speakerClipsDirectory: paths.speakerClips,
            statsStore: DeferredTranscriptStatsStore()
        )

        let taskId = UUID()
        let cancelBox = CancellableTaskBox()
        // Cancel inside `callSpeakerActivityProvider`, which runs right before the
        // pre-cleanup cancellation check in `transcribeMultichannelPipeline`.
        manager.callSpeakerActivityProvider = { _ in
            cancelBox.cancel()
            return nil
        }

        let running = Task<URL, Error> {
            try await manager.transcribeMultichannelPipeline(
                micURL: nil,
                systemURL: systemURL,
                outputFolder: outputFolder,
                taskId: taskId,
                healthInfo: nil,
                removeSourceAudioAfterArchive: false,
                archiveRecordingAudio: false
            )
        }
        cancelBox.set { running.cancel() }

        do {
            _ = try await running.value
            XCTFail("Expected CancellationError")
        } catch is CancellationError {
            // Expected
        }

        XCTAssertNotNil(speakerDB.getSpeaker(id: dupA.id), "cancelled runner must not merge duplicates")
        XCTAssertNotNil(speakerDB.getSpeaker(id: dupB.id), "cancelled runner must not merge duplicates")
        XCTAssertNotNil(speakerDB.getSpeaker(id: stale.id), "cancelled runner must not prune weak profiles")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class DeferredWriteStubSTT: SpeechToTextEngine {
    enum Behavior {
        case succeed(String)
        case failOnSource(AudioSource, Error)
        case cancelOnSource(AudioSource)
    }

    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private let behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func initialize() async { isReady = true }
    func cleanup() { isReady = false }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        switch behavior {
        case .succeed(let text):
            return text
        case .failOnSource(let target, let error):
            if source == target { throw error }
            return "spoken words"
        case .cancelOnSource(let target):
            if source == target { throw CancellationError() }
            return "spoken words"
        }
    }
}

@available(macOS 14.0, *)
@MainActor
private final class DeferredWriteStubDiarizer: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private let segments: [SpeakerSegment]

    init(segments: [SpeakerSegment]) {
        self.segments = segments
    }

    func initialize() async { isReady = true }
    func cleanup() { isReady = false }

    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        segments
    }

    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        segments
    }
}

private final class CancellableTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelAction: (() -> Void)?
    private var cancelRequested = false

    func set(_ action: @escaping () -> Void) {
        let shouldCancelNow: Bool = lock.withLock {
            cancelAction = action
            return cancelRequested
        }
        if shouldCancelNow {
            action()
        }
    }

    func cancel() {
        let action: (() -> Void)? = lock.withLock {
            cancelRequested = true
            return cancelAction
        }
        action?()
    }
}
