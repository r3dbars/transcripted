import XCTest
import Combine
import AVFoundation
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class TranscriptionTaskManagerMetadataTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testPopulateSavedMetadataReadsLargeFrontmatterBeyondInitialChunk() throws {
        let manager = makeManager()
        let transcriptURL = tempDirectory.appendingPathComponent("Call_2026-04-22.md")

        let filler = (0..<180)
            .map { "padding_\($0): \"\(String(repeating: "x", count: 20))\"" }
            .joined(separator: "\n")
        let content = """
        ---
        date: 2026-04-22
        \(filler)
        title: "Quarterly Planning Review"
        duration: "42:17"
        mic_speakers: 2
        system_speakers: 3
        ---

        # Meeting Recording
        """
        try content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        manager.populateSavedMetadata(from: transcriptURL)

        XCTAssertEqual(manager.lastSavedTitle, "Quarterly Planning Review")
        XCTAssertEqual(manager.lastSavedDuration, "42:17")
        XCTAssertEqual(manager.lastSavedSpeakerCount, 5)
    }

    func testResolvedRetainedAudioDirectoryFollowsProvider() {
        var providerCallCount = 0
        var nextDirectory = tempDirectory.appendingPathComponent("first")
        let manager = makeManager(retainedAudioDirectoryProvider: {
            providerCallCount += 1
            return nextDirectory
        })

        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), tempDirectory.appendingPathComponent("first"))
        XCTAssertEqual(providerCallCount, 1, "resolver should call provider on each lookup")

        nextDirectory = tempDirectory.appendingPathComponent("second")
        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), tempDirectory.appendingPathComponent("second"),
                       "resolver should reflect provider changes between calls (e.g. user moves capture library)")
        XCTAssertEqual(providerCallCount, 2)
    }

    func testResolvedRetainedAudioDirectoryFallsBackToStaticValue() {
        let staticDirectory = tempDirectory.appendingPathComponent("static")
        let manager = makeManager(retainedAudioDirectory: staticDirectory)

        XCTAssertEqual(manager.resolvedRetainedAudioDirectory(), staticDirectory,
                       "embedders that pass only the static value should still get a valid resolver result")
    }

    func testStartTranscriptionRejectsMissingSystemAudioBeforeBackgroundWorkStarts() throws {
        let manager = makeManager()
        let micScratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: micScratchDirectory, withIntermediateDirectories: true)
        let micURL = micScratchDirectory.appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertEqual(manager.activeCount, 0)
        XCTAssertEqual(manager.backgroundTaskCount, 0)
        XCTAssertEqual(manager.activeTasks.count, 0)
        XCTAssertEqual(manager.failedTranscriptionManager.failedTranscriptions.count, 1)
        XCTAssertEqual(
            manager.failedTranscriptionManager.failedTranscriptions.first?.errorMessage,
            PipelineError.missingSystemAudio.localizedDescription
        )

        guard case .failed(let message) = manager.displayStatus else {
            return XCTFail("Expected failed display status when system audio is missing")
        }
        XCTAssertEqual(message, "System audio required")
    }

    func testMissingSystemAudioQueuesRetainedArchiveAndRemovesScratch() throws {
        let retainedAudioDirectory = tempDirectory
            .appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent("audio", isDirectory: true)
        let manager = makeManager(retainedAudioDirectory: retainedAudioDirectory)
        let micScratchDirectory = tempDirectory.appendingPathComponent("audio")
        try FileManager.default.createDirectory(at: micScratchDirectory, withIntermediateDirectories: true)
        let micURL = micScratchDirectory.appendingPathComponent("mic.wav")
        try writeMonoWAV(to: micURL, duration: 2.5)

        manager.startTranscription(
            micURL: micURL,
            systemURL: nil,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        let failed = try XCTUnwrap(manager.failedTranscriptionManager.failedTranscriptions.first)
        XCTAssertTrue(
            failed.micAudioURL.path.hasPrefix(retainedAudioDirectory.path + "/"),
            "failed queue should point at retained archive audio, not scratch audio"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: failed.micAudioURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "scratch mic audio should be removed after archiving")

        let archivedDirectory = failed.micAudioURL.deletingLastPathComponent()
        manager.failedTranscriptionManager.deleteFailedTranscription(id: failed.id)

        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.micAudioURL.path), "delete should remove archived failed audio")
        XCTAssertFalse(FileManager.default.fileExists(atPath: archivedDirectory.path), "delete should remove the empty failed-audio directory")
    }

    func testStartImportedTranscriptionDoesNotDeleteOutOfSandboxFileWhenRejected() throws {
        let manager = makeManager()
        let externalURL = tempDirectory.appendingPathComponent("outside.wav")
        try writeMonoWAV(to: externalURL, duration: 2.5)

        manager.activeTasks[UUID()] = Task {}
        manager.startImportedTranscription(
            audioURL: externalURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts")
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    private func makeManager(
        retainedAudioDirectory: URL? = nil,
        retainedAudioDirectoryProvider: (() -> URL?)? = nil
    ) -> TranscriptionTaskManager {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )

        try? FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)

        return TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: MetadataStubSpeechToTextEngine(),
            diarization: MetadataStubDiarizationEngine(),
            speakerStore: SpeakerDatabase(path: paths.speakerDB.path),
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips],
            retainedAudioDirectory: retainedAudioDirectory,
            retainedAudioDirectoryProvider: retainedAudioDirectoryProvider
        )
    }

    private func writeMonoWAV(to url: URL, duration: TimeInterval, sampleRate: Double = 16_000) throws {
        let frameCount = Int(duration * sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            return XCTFail("Failed to create test audio format")
        }

        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(frameCount)
        ) else {
            return XCTFail("Failed to create test audio buffer")
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let channelData = buffer.floatChannelData?[0] {
            for index in 0..<frameCount {
                channelData[index] = 0.25
            }
        }

        try file.write(from: buffer)
    }
}

@available(macOS 14.0, *)
@MainActor
private final class MetadataStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true

    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String { "" }
    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class MetadataStubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true

    func initialize() async {}
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { [] }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { [] }
    func cleanup() {}
}
