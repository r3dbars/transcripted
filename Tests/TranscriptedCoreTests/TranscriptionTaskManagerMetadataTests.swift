import XCTest
import Combine
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

    func testCurrentRetainedAudioDirectoryUsesLiveProviderWhenAvailable() {
        let initialDirectory = tempDirectory.appendingPathComponent("audio-archive-a", isDirectory: true)
        let updatedDirectory = tempDirectory.appendingPathComponent("audio-archive-b", isDirectory: true)
        var currentDirectory = initialDirectory

        let manager = makeManager(
            retainedAudioDirectory: initialDirectory,
            retainedAudioDirectoryProvider: { currentDirectory }
        )

        XCTAssertEqual(manager.currentRetainedAudioDirectory(), initialDirectory)

        currentDirectory = updatedDirectory

        XCTAssertEqual(manager.currentRetainedAudioDirectory(), updatedDirectory)
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
            retainedAudioDirectory: retainedAudioDirectory,
            retainedAudioDirectoryProvider: retainedAudioDirectoryProvider
        )
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
