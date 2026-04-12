import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class FailedTranscriptionManagerTests: XCTestCase {
    private var testRoot: URL!

    override func setUpWithError() throws {
        let homeRoot = FileManager.default.homeDirectoryForCurrentUser
        testRoot = homeRoot
            .appendingPathComponent("Library/Application Support/TranscriptedTests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let testRoot {
            try? FileManager.default.removeItem(at: testRoot)
        }
        testRoot = nil
    }

    func testInitRejectsOutOfHomeAudioPathsAndRewritesQueue() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let safeMicURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        let safeSystemURL = paths.audioCaptures.appendingPathComponent("safe-system.wav")
        FileManager.default.createFile(atPath: safeMicURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: safeSystemURL.path, contents: Data("system".utf8))

        let safeEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 1_000),
            micAudioURL: safeMicURL,
            systemAudioURL: safeSystemURL,
            errorMessage: "Temporary transcription failure"
        )
        let unsafeMicEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 2_000),
            micAudioURL: URL(fileURLWithPath: "/tmp/transcripted-unsafe-mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        let unsafeSystemEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 3_000),
            micAudioURL: safeMicURL,
            systemAudioURL: URL(fileURLWithPath: "/tmp/transcripted-unsafe-system.wav"),
            errorMessage: "Temporary transcription failure"
        )

        let encoded = try JSONEncoder.iso8601.encode([safeEntry, unsafeMicEntry, unsafeSystemEntry])
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoded.write(to: paths.failedQueue, options: .atomic)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions, [safeEntry])

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted, [safeEntry])
    }

    private func makePaths(root: URL) -> CoreStoragePaths {
        CoreStoragePaths(
            transcripts: root.appendingPathComponent("captures/meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("state/speakers.sqlite"),
            statsDB: root.appendingPathComponent("state/stats.sqlite"),
            failedQueue: root.appendingPathComponent("state/failed_transcriptions.json"),
            speakerClips: root.appendingPathComponent("tmp/recordings/speaker_clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("tmp/recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )
    }
}

private extension JSONEncoder {
    static var iso8601: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
