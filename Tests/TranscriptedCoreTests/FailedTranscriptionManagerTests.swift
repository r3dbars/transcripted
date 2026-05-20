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
        let traversalTargetURL = testRoot.appendingPathComponent("outside.wav")
        FileManager.default.createFile(atPath: traversalTargetURL.path, contents: Data("outside".utf8))
        let traversalMicURL = URL(fileURLWithPath: paths.audioCaptures.path + "/../../outside.wav")
        let documentsURL = testRoot.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: documentsURL, withIntermediateDirectories: true)
        let homeFileURL = documentsURL.appendingPathComponent("foo.wav")
        FileManager.default.createFile(atPath: homeFileURL.path, contents: Data("home".utf8))

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
        let traversalEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 4_000),
            micAudioURL: traversalMicURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        let arbitraryHomeEntry = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 5_000),
            micAudioURL: homeFileURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )

        let encoded = try JSONEncoder.iso8601.encode([
            safeEntry,
            unsafeMicEntry,
            unsafeSystemEntry,
            traversalEntry,
            arbitraryHomeEntry,
        ])
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

    func testAddFailedTranscriptionRejectsOutOfSandboxAudioPaths() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let safeMicURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: safeMicURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        manager.addFailedTranscription(
            micAudioURL: URL(fileURLWithPath: "/tmp/transcripted-unsafe-mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )
        manager.addFailedTranscription(
            micAudioURL: safeMicURL,
            systemAudioURL: URL(fileURLWithPath: "/tmp/transcripted-unsafe-system.wav"),
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertTrue(manager.failedTranscriptions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.failedQueue.path))
    }

    func testAddFailedTranscriptionAcceptsRetainedMeetingAudioArchivePaths() throws {
        let paths = makePaths(root: testRoot)
        let archiveRoot = paths.transcripts.appendingPathComponent("audio", isDirectory: true)
        let archivedDirectory = archiveRoot.appendingPathComponent("Failed_Call_audio", isDirectory: true)
        try FileManager.default.createDirectory(at: archivedDirectory, withIntermediateDirectories: true)

        let archivedMicURL = archivedDirectory.appendingPathComponent("microphone.wav")
        let archivedSystemURL = archivedDirectory.appendingPathComponent("system_audio.wav")
        FileManager.default.createFile(atPath: archivedMicURL.path, contents: Data("mic".utf8))
        FileManager.default.createFile(atPath: archivedSystemURL.path, contents: Data("system".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        manager.addFailedTranscription(
            micAudioURL: archivedMicURL,
            systemAudioURL: archivedSystemURL,
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertEqual(manager.failedTranscriptions.count, 1)
        XCTAssertEqual(manager.failedTranscriptions.first?.micAudioURL, archivedMicURL)
        XCTAssertEqual(manager.failedTranscriptions.first?.systemAudioURL, archivedSystemURL)

        let siblingArchiveURL = paths.transcripts
            .deletingLastPathComponent()
            .appendingPathComponent("audio/sibling.wav")
        try FileManager.default.createDirectory(
            at: siblingArchiveURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: siblingArchiveURL.path, contents: Data("sibling".utf8))

        manager.addFailedTranscription(
            micAudioURL: siblingArchiveURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertEqual(manager.failedTranscriptions.count, 1)
    }

    func testAddFailedTranscriptionPersistsMeetingTitle() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        manager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure",
            meetingTitle: "Meeting with Linus"
        )

        XCTAssertEqual(manager.failedTranscriptions.first?.meetingTitle, "Meeting with Linus")

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted.first?.meetingTitle, "Meeting with Linus")
    }

    func testUpdateFailedTranscriptionErrorPreservesMeetingTitle() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)

        let micURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let manager = FailedTranscriptionManager(paths: paths)
        manager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure",
            meetingTitle: "Design review"
        )
        let failed = try XCTUnwrap(manager.failedTranscriptions.first)

        XCTAssertTrue(manager.updateFailedTranscriptionError(
            id: failed.id,
            errorMessage: "Speaker names could not be saved."
        ))

        XCTAssertEqual(manager.failedTranscriptions.first?.meetingTitle, "Design review")

        let persisted = try JSONDecoder.iso8601.decode(
            [FailedTranscription].self,
            from: Data(contentsOf: paths.failedQueue)
        )
        XCTAssertEqual(persisted.first?.meetingTitle, "Design review")
    }

    func testAddFailedTranscriptionRollsBackMemoryWhenPersistenceFails() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        let micURL = paths.audioCaptures.appendingPathComponent("safe-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))
        let manager = FailedTranscriptionManager(paths: paths)
        try FileManager.default.createDirectory(at: paths.failedQueue, withIntermediateDirectories: true)

        let didPersist = manager.addFailedTranscription(
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure"
        )

        XCTAssertFalse(didPersist)
        XCTAssertTrue(manager.failedTranscriptions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testInitKeepsNonRetryableFailuresUntilUserDeletesThem() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let micURL = paths.audioCaptures.appendingPathComponent("missing-system-audio-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let failure = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 10),
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "System audio is required to transcribe this meeting."
        )
        XCTAssertFalse(failure.isRetryable)
        try JSONEncoder.iso8601.encode([failure]).write(to: paths.failedQueue, options: .atomic)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions, [failure])
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testInitKeepsExhaustedRetryFailuresUntilUserDeletesThem() throws {
        let paths = makePaths(root: testRoot)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: paths.failedQueue.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let micURL = paths.audioCaptures.appendingPathComponent("exhausted-retry-mic.wav")
        FileManager.default.createFile(atPath: micURL.path, contents: Data("mic".utf8))

        let failure = FailedTranscription(
            id: UUID(),
            timestamp: Date(timeIntervalSince1970: 11),
            micAudioURL: micURL,
            systemAudioURL: nil,
            errorMessage: "Temporary transcription failure",
            retryCount: 3
        )
        try JSONEncoder.iso8601.encode([failure]).write(to: paths.failedQueue, options: .atomic)

        let manager = FailedTranscriptionManager(paths: paths)

        XCTAssertEqual(manager.failedTranscriptions, [failure])
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }

    func testFailedTranscriptionRetryabilityDoesNotOvermatchGenericMinimumLanguage() {
        let failure = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Upload failed after at least one retry because the destination was unavailable."
        )

        XCTAssertTrue(failure.isRetryable)
    }

    func testFailedTranscriptionRetryabilityKeepsShortAudioPermanent() {
        let failure = FailedTranscription(
            micAudioURL: testRoot.appendingPathComponent("mic.wav"),
            systemAudioURL: nil,
            errorMessage: "Invalid audio data provided. Must be at least 1 second of 16kHz audio."
        )

        XCTAssertFalse(failure.isRetryable)
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
