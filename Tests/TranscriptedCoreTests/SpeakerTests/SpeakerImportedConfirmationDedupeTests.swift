import XCTest
import Combine
import FluidAudio
@testable import TranscriptedCore

/// Promise: silent naming waits for a person to be confirmed in enough
/// *distinct* meetings. Re-importing the same recording is not a new meeting,
/// so confirmations from imports of identical audio count once. Live meetings
/// and different files still count separately, and every confirmation lands in
/// the speaker database the review was matched against.
@available(macOS 14.0, *)
final class SpeakerImportedConfirmationDedupeTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerImportedConfirmationDedupeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - Meeting id

    func testImportedContentKeyMapsToOneStableMeetingId() {
        let transcriptA = UUID()
        let transcriptB = UUID()
        let key = String(repeating: "3f", count: 32)
        let fromA = SpeakerConfirmationMeetingID.resolve(transcriptId: transcriptA, importedContentKey: key)
        let fromB = SpeakerConfirmationMeetingID.resolve(transcriptId: transcriptB, importedContentKey: key)
        XCTAssertEqual(fromA, fromB, "two imports of the same audio are one meeting")
        XCTAssertNotEqual(fromA, transcriptA)
        XCTAssertEqual(
            SpeakerConfirmationMeetingID.resolve(transcriptId: transcriptA, importedContentKey: key.uppercased()),
            fromA,
            "the hex key's case doesn't matter"
        )
        XCTAssertNotEqual(
            SpeakerConfirmationMeetingID.resolve(transcriptId: transcriptA, importedContentKey: String(repeating: "40", count: 32)),
            fromA,
            "different audio is a different meeting"
        )
        XCTAssertEqual(SpeakerConfirmationMeetingID.resolve(transcriptId: transcriptA, importedContentKey: nil), transcriptA)
        XCTAssertEqual(SpeakerConfirmationMeetingID.resolve(transcriptId: transcriptA, importedContentKey: "  "), transcriptA)
    }

    // MARK: - Review flow

    @MainActor
    func testTwoImportsOfIdenticalAudioCountAsOneConfirmedMeeting() async throws {
        let harness = try makeHarness()
        let maya = namedProfile("Maya Patel", in: harness)
        let key = String(repeating: "a1", count: 32)

        try await confirm(maya, in: harness, importedContentKey: key)
        try await confirm(maya, in: harness, importedContentKey: key)

        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 1)
    }

    @MainActor
    func testImportsOfDifferentFilesEachCount() async throws {
        let harness = try makeHarness()
        let maya = namedProfile("Maya Patel", in: harness)

        try await confirm(maya, in: harness, importedContentKey: String(repeating: "a1", count: 32))
        try await confirm(maya, in: harness, importedContentKey: String(repeating: "b2", count: 32))

        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 2)
    }

    @MainActor
    func testLiveMeetingsStillCountOncePerTranscript() async throws {
        let harness = try makeHarness()
        let maya = namedProfile("Maya Patel", in: harness)

        try await confirm(maya, in: harness, importedContentKey: nil, viaImport: false)
        try await confirm(maya, in: harness, importedContentKey: nil, viaImport: false)
        // An import whose key is unknown (an older journal) falls back to its transcript.
        try await confirm(maya, in: harness, importedContentKey: nil, viaImport: true)

        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 3)
    }

    @MainActor
    func testImportConfirmationPersistsToTheMatchedDatabase() async throws {
        let harness = try makeHarness()
        let maya = namedProfile("Maya Patel", in: harness)
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 0)

        try await confirm(maya, in: harness, importedContentKey: String(repeating: "c3", count: 32))

        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 1, "the review's database sees the confirmation")
        let reopened = SpeakerDatabase(path: harness.paths.speakerDB.path)
        XCTAssertEqual(reopened.getSpeaker(id: maya)?.confirmedMeetingCount, 1, "the confirmation is on disk, not only in memory")
    }

    @MainActor
    func testReimportConfirmationsKeepOneNamedProfile() async throws {
        let harness = try makeHarness()
        let maya = namedProfile("Maya Patel", in: harness)
        let key = String(repeating: "d4", count: 32)

        for _ in 0..<3 {
            try await confirm(maya, in: harness, importedContentKey: key)
        }

        let named = harness.speakerDB.allSpeakers().filter { $0.displayName == "Maya Patel" }
        XCTAssertEqual(named.map(\.id), [maya])
        XCTAssertEqual(named.first?.confirmedMeetingCount, 1)
    }

    // MARK: - Helpers

    // MARK: - Every later path counts the same recording once

    /// Saving an import records which recording its transcript belongs to, so a
    /// later re-transcription of that transcript (which runs without the import's
    /// session) confirms toward the same meeting instead of adding one.
    @MainActor
    func testReTranscribingAnImportDoesNotAddAConfirmedMeeting() async throws {
        let harness = try makeHarness()
        let maya = namedProfile("Maya Patel", in: harness)
        let key = String(repeating: "c3", count: 32)
        let transcriptId = UUID()
        commitImport(transcriptId: transcriptId, contentKey: key, in: harness)

        try await confirm(maya, in: harness, importedContentKey: key, transcriptId: transcriptId)
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 1)

        // Re-transcription: same transcript id, no import session.
        try await confirm(maya, in: harness, importedContentKey: nil, viaImport: false, transcriptId: transcriptId)
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 1)
    }

    /// Two imports of the same file left for later, then named from Settings
    /// (which records by each saved transcript's id), count as one meeting.
    @MainActor
    func testLaterConfirmationsOfTwoIdenticalImportsCountOnce() throws {
        let harness = try makeHarness()
        let maya = namedProfile("Maya Patel", in: harness)
        let key = String(repeating: "d4", count: 32)
        let first = UUID(), second = UUID()
        commitImport(transcriptId: first, contentKey: key, in: harness)
        commitImport(transcriptId: second, contentKey: key, in: harness)

        try harness.speakerDB.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: maya, transcriptId: first, kind: .confirmed),
            SpeakerUserConfirmation(profileId: maya, transcriptId: second, kind: .named),
        ])
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 1)

        // A live meeting still counts on its own.
        try harness.speakerDB.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: maya, transcriptId: UUID(), kind: .confirmed),
        ])
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 2)
    }

    /// A live recording's commit records no alias: its confirmations stay per transcript.
    @MainActor
    func testLiveCommitLeavesConfirmationsPerTranscript() throws {
        let harness = try makeHarness()
        let maya = namedProfile("Maya Patel", in: harness)
        let first = UUID(), second = UUID()
        commitImport(transcriptId: first, contentKey: nil, in: harness)
        commitImport(transcriptId: second, contentKey: nil, in: harness)
        try harness.speakerDB.recordUserConfirmations([
            SpeakerUserConfirmation(profileId: maya, transcriptId: first, kind: .confirmed),
            SpeakerUserConfirmation(profileId: maya, transcriptId: second, kind: .confirmed),
        ])
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: maya)?.confirmedMeetingCount, 2)
    }

    /// Runs the task manager's transcript-commit step for one job.
    @MainActor
    private func commitImport(transcriptId: UUID, contentKey: String?, in harness: Harness) {
        harness.manager.beginTaskLifecycle(taskId: transcriptId, audio: TranscriptionTaskManager.ActiveTaskAudio(
            micURL: nil,
            systemURL: harness.paths.audioCaptures.appendingPathComponent("\(transcriptId.uuidString)-system.wav"),
            meetingTitle: nil,
            recordingDate: nil,
            importedRecoverySession: contentKey.map { DedupeRecoverySession(sourceContentKey: $0) },
            splitLocalSpeakers: false,
            languageSelection: .automatic,
            micOnlyByChoice: false
        ))
        harness.manager.markTaskTranscriptCommitted(taskId: transcriptId, transcriptId: transcriptId)
        harness.manager.forgetTaskLifecycle(taskId: transcriptId)
    }

    private struct Harness {
        let paths: CoreStoragePaths
        let speakerDB: SpeakerDatabase
        let manager: TranscriptionTaskManager
    }

    @MainActor
    private func makeHarness() throws -> Harness {
        let paths = CoreStoragePaths(
            transcripts: tempDirectory.appendingPathComponent("transcripts"),
            speakerDB: tempDirectory.appendingPathComponent("speakers.sqlite"),
            statsDB: tempDirectory.appendingPathComponent("stats.sqlite"),
            failedQueue: tempDirectory.appendingPathComponent("failed_transcriptions.json"),
            speakerClips: tempDirectory.appendingPathComponent("speaker_clips"),
            audioCaptures: tempDirectory.appendingPathComponent("audio"),
            logs: tempDirectory.appendingPathComponent("logs")
        )
        for directory in [paths.transcripts, paths.audioCaptures, paths.speakerClips, paths.logs] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: FailedTranscriptionManager(paths: paths),
            speechToText: DedupeStubSpeechToTextEngine(),
            diarization: DedupeStubDiarizationEngine(),
            speakerStore: speakerDB,
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips]
        )
        return Harness(paths: paths, speakerDB: speakerDB, manager: manager)
    }

    private func namedProfile(_ name: String, in harness: Harness) -> UUID {
        let id = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.31, count: 256),
            existingId: nil
        ).id
        harness.speakerDB.setDisplayName(id: id, name: name, source: NameSource.userManual)
        return id
    }

    /// Runs one review where the user answers Yes to "Is this <name>?" for
    /// `profileId`, in a fresh transcript (each import gets a new transcript id).
    @MainActor
    private func confirm(
        _ profileId: UUID,
        in harness: Harness,
        importedContentKey: String?,
        viaImport: Bool = true,
        transcriptId: UUID = UUID()
    ) async throws {
        let name = try XCTUnwrap(harness.speakerDB.getSpeaker(id: profileId)?.displayName)
        let stem = transcriptId.uuidString
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("\(stem).md")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("\(stem)-system.wav")
        let clipURL = harness.paths.speakerClips.appendingPathComponent("\(stem)-clip.wav")
        try transcript(id: transcriptId, profileId: profileId, name: name)
            .write(to: transcriptURL, atomically: true, encoding: .utf8)
        try Data().write(to: systemURL)
        try Data().write(to: clipURL)

        let utterance = TranscriptionUtterance(
            start: 1, end: 4, channel: 1, speakerId: 1,
            persistentSpeakerId: profileId, matchSimilarity: nil,
            transcript: "Thanks for joining."
        )
        let result = TranscriptionResult(
            micUtterances: [], systemUtterances: [utterance], duration: 90, processingTime: 3
        )
        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            systemAudioURL: systemURL,
            micAudioURL: nil,
            onComplete: { _ in }
        )
        harness.manager.handleNamingComplete(
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: profileId,
                    diarizerSpeakerId: "1",
                    newName: name,
                    previousName: name,
                    action: .confirmed
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: result,
            micURL: nil,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: profileId,
                    diarizerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: name,
                    matchSimilarity: 0.82,
                    needsNaming: false,
                    needsConfirmation: true,
                    sessionEmbedding: [Float](repeating: 0.31, count: 256)
                )
            ],
            importedRecoverySession: viaImport ? DedupeRecoverySession(sourceContentKey: importedContentKey) : nil
        )

        let manager = harness.manager
        for _ in 0..<400 {
            if manager.speakerNamingRequest == nil, manager.lastSavedTranscriptId == transcriptId { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("The review never finished saving")
    }

    private func transcript(id: UUID, profileId: UUID, name: String) -> String {
        """
        ---
        transcript_id: "\(id.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [system_audio]
        mic_utterances: 0
        system_utterances: 1
        mic_speakers: 0
        system_speakers: 1
        total_word_count: 3
        speakers:
          - id: "1"
            db_id: "\(profileId.uuidString)"
            name: "\(name)"
            confidence: medium
            source: db
        ---

        # Imported audio

        **Duration:** 1:30 | **Words:** 3 | **Utterances:** 1

        ---

        ## Channel & Speaker Analytics

        ### Meeting Audio (Remote Participants)
        - **Utterances:** 1
        - **Words:** ~3
        - **Speaking Time:** 00:03
        - **Speakers Detected:** 1

        #### Remote Speaker Breakdown

        - **\(name):** 1 utterances, ~3 words, 00:03

        ---

        ## Full Transcript

        [00:01] [System/\(name)] Thanks for joining.

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 1:30 | 3 words | 1 speakers*
        """
    }
}

private final class DedupeRecoverySession: ImportedTranscriptionRecoverySession, @unchecked Sendable {
    let jobID = UUID()
    let sourceContentKey: String?
    init(sourceContentKey: String?) { self.sourceContentKey = sourceContentKey }
    func transcriptCommitConfirmed() {}
    func prepareForScratchCleanup() -> Bool { true }
    func scratchCleanupConfirmed() {}
    func failedQueueHandoffConfirmed() {}
}

@available(macOS 14.0, *)
@MainActor
private final class DedupeStubSpeechToTextEngine: SpeechToTextEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true
    func initialize() async {}
    func transcribeSegment(samples: [Float], source: AudioSource) async throws -> String { "" }
    func cleanup() {}
}

@available(macOS 14.0, *)
@MainActor
private final class DedupeStubDiarizationEngine: DiarizationEngine {
    nonisolated let objectWillChange = ObservableObjectPublisher()
    var isReady: Bool = true
    func initialize() async {}
    func diarizeOffline(samples: [Float], sampleRate: Int) async throws -> [SpeakerSegment] { [] }
    func diarizeOffline(audioURL: URL) async throws -> [SpeakerSegment] { [] }
    func cleanup() {}
}
