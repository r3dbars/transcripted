import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

/// Regression tests for P5:
/// - `transcribeMicrophoneOnlyPipeline` with `splitLocalSpeakers == true` classifies
///   local speakers against `speakerDB`, writes known auto-accepted speaker names and
///   `db_id` metadata to the saved transcript, and queues a `.mic` `SpeakerNamingRequest`.
/// - `transcribeMicrophoneOnlyPipeline` with `splitLocalSpeakers == false` keeps the
///   legacy single-"You" transcript with no `db_id` entries and no naming request.
@available(macOS 14.0, *)
final class MicOnlySplitSpeakersPipelineTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MicOnlySplitSpeakersPipelineTests-\(UUID().uuidString)", isDirectory: true)
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

    private func writeMonoWAV(to url: URL, durationSeconds: Double = 6.0) throws {
        let sampleRate = 16_000.0
        let count = Int(sampleRate * durationSeconds)
        var samples = [Float](repeating: 0, count: count)
        for i in 0..<count {
            samples[i] = (i % 2 == 0) ? 0.1 : -0.1
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
    func testMicOnlySplitLocalSpeakersPreservesKnownNameDbIdsAndQueuesNamingRequest() async throws {
        let paths = makePaths()
        let outputFolder = paths.transcripts
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.speakerClips, withIntermediateDirectories: true)

        let micURL = tempRoot.appendingPathComponent("mic_split.wav")
        try writeMonoWAV(to: micURL, durationSeconds: 6.0)

        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        let aliceEmbedding = axisEmbedding(0)
        let guestEmbedding = axisEmbedding(1)

        // Seed Alice with enough distinct user confirmations to clear auto-accept.
        let alice = speakerDB.addOrUpdateSpeaker(embedding: aliceEmbedding, existingId: nil)
        speakerDB.setDisplayName(id: alice.id, name: "Alice Rivera", source: NameSource.userManual)
        let confirmations = (0..<SpeakerNamingPolicy.requiredConfirmedMeetings).map { _ in
            SpeakerUserConfirmation(profileId: alice.id, transcriptId: UUID(), kind: .confirmed)
        }
        try speakerDB.recordUserConfirmations(confirmations)

        let segments = [
            SpeakerSegment(speakerId: 1, startTime: 0.0, endTime: 3.0, embedding: aliceEmbedding, qualityScore: 0.95),
            SpeakerSegment(speakerId: 2, startTime: 3.0, endTime: 6.0, embedding: guestEmbedding, qualityScore: 0.95),
        ]

        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: MicOnlySplitStubSTT(responses: ["Welcome everyone to the room", "Glad to be here today"]),
            diarization: MicOnlySplitStubDiarizer(segments: segments),
            speakerStore: speakerDB,
            speakerClipsDirectory: paths.speakerClips,
            statsStore: DeferredTranscriptStatsStore()
        )

        let taskId = UUID()
        manager.activeTasks[taskId] = Task {}
        manager.beginTaskLifecycle(taskId: taskId, audio: nil)
        defer {
            manager.activeTasks.removeValue(forKey: taskId)
            manager.forgetTaskLifecycle(taskId: taskId)
            manager.cleanupPendingNaming()
        }

        let savedURL = try await manager.transcribeMicrophoneOnlyPipeline(
            micURL: micURL,
            outputFolder: outputFolder,
            taskId: taskId,
            healthInfo: nil,
            meetingTitle: "Room Standup",
            removeSourceAudioAfterArchive: false,
            splitLocalSpeakers: true
        )

        let markdown = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("Alice Rivera"), "auto-accepted local speaker's name must appear in the saved transcript")
        XCTAssertTrue(markdown.contains("db_id: \"\(alice.id.uuidString)\""), "known local speaker's db_id must be persisted in frontmatter")
        XCTAssertTrue(markdown.contains("source: db"), "auto-accepted local speaker must be marked source: db")
        XCTAssertTrue(markdown.contains("source: db_pending"), "unknown local speaker must be marked source: db_pending")

        let request = try XCTUnwrap(manager.speakerNamingRequest, "split mic-only pipeline must queue a SpeakerNamingRequest")
        XCTAssertNil(request.systemAudioURL, "mic-only review must not fabricate a systemAudioURL")
        XCTAssertEqual(request.micAudioURL, micURL)
        XCTAssertTrue(request.speakers.allSatisfy { $0.channel == .mic })
        XCTAssertEqual(request.speakers.count, 2, "all diarized mic speakers with persistent profiles are surfaced")
        let unknownEntry = try XCTUnwrap(request.speakers.first { $0.needsNaming })
        XCTAssertNil(unknownEntry.currentName)
        XCTAssertTrue(markdown.contains("db_id: \"\(unknownEntry.id.uuidString)\""), "unknown local speaker's db_id must be persisted in frontmatter")
    }

    @MainActor
    func testMicOnlyWithoutSplitLocalSpeakersKeepsSingleYouAndNoNamingRequest() async throws {
        let paths = makePaths()
        let outputFolder = paths.transcripts
        try FileManager.default.createDirectory(at: outputFolder, withIntermediateDirectories: true)

        let micURL = tempRoot.appendingPathComponent("mic_single.wav")
        try writeMonoWAV(to: micURL, durationSeconds: 4.0)

        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: MicOnlySplitStubSTT(responses: ["Solo microphone note"]),
            diarization: MicOnlySplitStubDiarizer(segments: []),
            speakerStore: speakerDB,
            speakerClipsDirectory: paths.speakerClips,
            statsStore: DeferredTranscriptStatsStore()
        )

        let taskId = UUID()
        manager.activeTasks[taskId] = Task {}
        manager.beginTaskLifecycle(taskId: taskId, audio: nil)
        defer {
            manager.activeTasks.removeValue(forKey: taskId)
            manager.forgetTaskLifecycle(taskId: taskId)
        }

        let savedURL = try await manager.transcribeMicrophoneOnlyPipeline(
            micURL: micURL,
            outputFolder: outputFolder,
            taskId: taskId,
            healthInfo: nil,
            meetingTitle: "Solo Note",
            removeSourceAudioAfterArchive: false,
            splitLocalSpeakers: false
        )

        let markdown = try String(contentsOf: savedURL, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[Mic/You]"), "non-split mic-only transcript must attribute speech with [Mic/You] label")
        XCTAssertTrue(markdown.contains("Solo microphone note"), "non-split mic-only transcript must preserve spoken text")
        XCTAssertFalse(markdown.contains("[Mic/Speaker"), "non-split mic-only transcript must not emit diarized mic speaker labels")
        XCTAssertFalse(markdown.contains("db_id:"), "non-split mic-only transcript must not emit speaker DB links")
        XCTAssertNil(manager.speakerNamingRequest, "non-split mic-only pipeline must not queue a SpeakerNamingRequest")
    }
}

@available(macOS 14.0, *)
@MainActor
private final class MicOnlySplitStubSTT: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady = true
    private var responses: [String]

    init(responses: [String]) {
        self.responses = responses
    }

    func initialize() async { isReady = true }
    func cleanup() { isReady = false }

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        if responses.isEmpty { return "additional speech" }
        return responses.removeFirst()
    }
}

@available(macOS 14.0, *)
@MainActor
private final class MicOnlySplitStubDiarizer: DiarizationEngine {
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
