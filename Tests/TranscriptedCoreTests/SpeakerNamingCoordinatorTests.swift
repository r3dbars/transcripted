import XCTest
import Combine
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerNamingCoordinatorTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerNamingCoordinatorTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    @MainActor
    func testHandleNamingCompletePublishesSuccessAfterTranscriptRewrite() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker.wav")
        let micURL = tempDirectory.appendingPathComponent("mic.wav")
        let systemURL = tempDirectory.appendingPathComponent("system.wav")

        try sampleTranscript(
            transcriptId: transcriptId,
            persistentSpeakerId: persistentSpeakerId,
            speakerName: "Speaker 1"
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: clipURL)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)

        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            systemAudioURL: systemURL,
            micAudioURL: micURL,
            onComplete: { _ in }
        )

        harness.manager.handleNamingComplete(
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: [Float](repeating: 0.25, count: 256)
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        XCTAssertEqual(harness.manager.lastSavedTranscriptURL, transcriptURL)
        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("Sarah Graham"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
    }

    @MainActor
    func testHandleNamingCompletePublishesFailureWhenRewriteFails() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.4, count: 256),
            existingId: nil
        ).id
        let missingTranscriptURL = harness.paths.transcripts.appendingPathComponent("Missing.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-failure.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-failure.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-failure.wav")

        try Data().write(to: clipURL)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)

        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: missingTranscriptURL,
            transcriptId: transcriptId,
            systemAudioURL: systemURL,
            micAudioURL: micURL,
            onComplete: { _ in }
        )

        harness.manager.handleNamingComplete(
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: missingTranscriptURL,
            transcriptId: transcriptId,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: [Float](repeating: 0.4, count: 256)
                )
            ]
        )

        try await waitUntil {
            if case .failed(message: "Failed to finalize speaker names") = harness.manager.displayStatus,
               harness.manager.speakerNamingRequest == nil {
                return true
            }
            return false
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
    }

    @MainActor
    func testHandleNamingCompleteResolvesRenamedTranscriptByStableId() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.3, count: 256),
            existingId: nil
        ).id
        let originalTranscriptURL = harness.paths.transcripts.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let renamedTranscriptURL = harness.paths.transcripts.appendingPathComponent("Meeting with Speaker 1.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-renamed.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-renamed.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-renamed.wav")

        try sampleTranscript(
            transcriptId: transcriptId,
            persistentSpeakerId: persistentSpeakerId,
            speakerName: "Speaker 1"
        ).write(to: renamedTranscriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: clipURL)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)

        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: originalTranscriptURL,
            transcriptId: transcriptId,
            systemAudioURL: systemURL,
            micAudioURL: micURL,
            onComplete: { _ in }
        )

        harness.manager.handleNamingComplete(
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: originalTranscriptURL,
            transcriptId: transcriptId,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    sortformerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: [Float](repeating: 0.3, count: 256)
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        XCTAssertEqual(harness.manager.lastSavedTranscriptURL, renamedTranscriptURL)
        let savedTranscript = try String(contentsOf: renamedTranscriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("Sarah Graham"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalTranscriptURL.path))
    }

    @MainActor
    func testHandleNamingCompleteCorrectionKeepsRejectedProfileAndUsesExistingTarget() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let matchedProfile = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.2, count: 256),
            existingId: nil
        )
        harness.speakerDB.setDisplayName(
            id: matchedProfile.id,
            name: "Matt Vlasach",
            source: NameSource.userManual
        )
        guard let matchedSnapshot = harness.speakerDB.getSpeaker(id: matchedProfile.id) else {
            XCTFail("Expected matched profile snapshot")
            return
        }

        let targetProfile = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.8, count: 256),
            existingId: nil
        )
        harness.speakerDB.setDisplayName(
            id: targetProfile.id,
            name: "Sarah Graham",
            source: NameSource.userManual
        )
        let targetBefore = harness.speakerDB.getSpeaker(id: targetProfile.id)

        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Meeting with Matt Vlasach.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-correction.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-correction.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-correction.wav")

        try sampleTranscript(
            transcriptId: transcriptId,
            persistentSpeakerId: matchedProfile.id,
            speakerName: "Matt Vlasach"
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: clipURL)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)

        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            systemAudioURL: systemURL,
            micAudioURL: micURL,
            onComplete: { _ in }
        )

        harness.manager.handleNamingComplete(
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: matchedProfile.id,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: matchedProfile.id,
                    sortformerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: "Matt Vlasach",
                    matchSimilarity: 0.86,
                    needsNaming: false,
                    needsConfirmation: true,
                    sessionEmbedding: [Float](repeating: 0.8, count: 256),
                    matchedProfileSnapshot: matchedSnapshot
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("Sarah Graham"))
        XCTAssertFalse(savedTranscript.contains("Matt Vlasach"))
        XCTAssertTrue(savedTranscript.contains(targetProfile.id.uuidString))

        let rejectedProfile = harness.speakerDB.getSpeaker(id: matchedProfile.id)
        XCTAssertEqual(rejectedProfile?.displayName, "Matt Vlasach")
        XCTAssertEqual(rejectedProfile?.disputeCount, matchedSnapshot.disputeCount + 1)

        let correctedProfile = harness.speakerDB.getSpeaker(id: targetProfile.id)
        XCTAssertEqual(correctedProfile?.displayName, "Sarah Graham")
        XCTAssertEqual(correctedProfile?.disputeCount, 0)
        XCTAssertGreaterThan(correctedProfile?.callCount ?? 0, targetBefore?.callCount ?? 0)
    }

    @MainActor
    func testHandleNamingCompleteCorrectionWithoutSessionEmbeddingFailsClosed() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let matchedProfile = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        )
        harness.speakerDB.setDisplayName(
            id: matchedProfile.id,
            name: "Matt Vlasach",
            source: NameSource.userManual
        )
        guard let matchedSnapshot = harness.speakerDB.getSpeaker(id: matchedProfile.id) else {
            XCTFail("Expected matched profile snapshot")
            return
        }

        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Meeting with Matt Vlasach.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-no-embedding.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-no-embedding.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-no-embedding.wav")

        try sampleTranscript(
            transcriptId: transcriptId,
            persistentSpeakerId: matchedProfile.id,
            speakerName: "Matt Vlasach"
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: clipURL)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)

        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            systemAudioURL: systemURL,
            micAudioURL: micURL,
            onComplete: { _ in }
        )

        harness.manager.handleNamingComplete(
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: matchedProfile.id,
                    sortformerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: matchedProfile.id,
                    sortformerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: "Matt Vlasach",
                    matchSimilarity: 0.85,
                    needsNaming: false,
                    needsConfirmation: true,
                    sessionEmbedding: nil,
                    matchedProfileSnapshot: matchedSnapshot
                )
            ]
        )

        try await waitUntil {
            if case .failed(message: "Failed to finalize speaker names") = harness.manager.displayStatus,
               harness.manager.speakerNamingRequest == nil {
                return true
            }
            return false
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("Matt Vlasach"))
        XCTAssertFalse(savedTranscript.contains("Sarah Graham"))

        let rejectedProfile = harness.speakerDB.getSpeaker(id: matchedProfile.id)
        XCTAssertEqual(rejectedProfile?.displayName, "Matt Vlasach")
        XCTAssertEqual(rejectedProfile?.disputeCount, matchedSnapshot.disputeCount + 1)
    }

    @MainActor
    private func makeHarness() throws -> TestHarness {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )

        try FileManager.default.createDirectory(at: paths.transcripts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.audioCaptures, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)

        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        let failedManager = FailedTranscriptionManager(paths: paths)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: failedManager,
            speechToText: StubSpeechToTextEngine(),
            diarization: StubDiarizationEngine(),
            speakerStore: speakerDB
        )

        return TestHarness(paths: paths, speakerDB: speakerDB, manager: manager)
    }

    private func sampleTranscript(
        transcriptId: UUID,
        persistentSpeakerId: UUID,
        speakerName: String
    ) -> String {
        """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 0
        system_utterances: 1
        mic_speakers: 0
        system_speakers: 1
        total_word_count: 5
        speakers:
          - id: "1"
            db_id: "\(persistentSpeakerId.uuidString)"
            name: "\(speakerName)"
            confidence: medium
            source: db_pending
        ---

        ## Full Transcript

        [00:01] [System/\(speakerName)] Thanks for joining.

        ---
        """
    }

    private func waitUntil(
        timeout: TimeInterval = 2.0,
        condition: @escaping @Sendable @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await MainActor.run(body: condition) {
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for condition")
    }
}

@available(macOS 14.0, *)
private struct TestHarness {
    let paths: CoreStoragePaths
    let speakerDB: SpeakerDatabase
    let manager: TranscriptionTaskManager
}

@available(macOS 14.0, *)
@MainActor
private final class StubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true

    func initialize() async {}

    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String {
        ""
    }

    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class StubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true

    func initialize() async {}

    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] {
        []
    }

    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] {
        []
    }

    func cleanup() {}
}
