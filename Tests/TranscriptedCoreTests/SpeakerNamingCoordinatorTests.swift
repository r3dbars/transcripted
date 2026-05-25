import XCTest
import Combine
import FluidAudio
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class SpeakerNamingCoordinatorTests: XCTestCase {

    private struct MarkdownSpeaker {
        let id: String
        let persistentSpeakerId: UUID
        let name: String
        let confidence: String
        let source: String
    }

    private struct MarkdownUtterance {
        let timestamp: String
        let source: String
        let label: String
        let text: String
        let diarizerSpeakerId: Int?
        let speakingSeconds: Double

        init(
            timestamp: String,
            source: String,
            label: String,
            text: String,
            diarizerSpeakerId: Int? = nil,
            speakingSeconds: Double = 3.0
        ) {
            self.timestamp = timestamp
            self.source = source
            self.label = label
            self.text = text
            self.diarizerSpeakerId = diarizerSpeakerId
            self.speakingSeconds = speakingSeconds
        }
    }

    private struct BreakdownEntry {
        let name: String
        let utterances: Int
        let wordCount: Int
        let duration: String
    }

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
    func testCleanupPendingNamingDoesNotDeleteOutOfSandboxFiles() throws {
        let harness = try makeHarness()
        let externalClipURL = tempDirectory.appendingPathComponent("outside-clip.wav")
        let externalMicURL = tempDirectory.appendingPathComponent("outside-mic.wav")
        let externalSystemURL = tempDirectory.appendingPathComponent("outside-system.wav")
        try Data().write(to: externalClipURL)
        try Data().write(to: externalMicURL)
        try Data().write(to: externalSystemURL)

        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [
                SpeakerNamingEntry(
                    id: UUID(),
                    diarizerSpeakerId: "1",
                    channel: .system,
                    clipURL: externalClipURL,
                    sampleText: "hello",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: nil,
                    matchedProfileSnapshot: nil
                )
            ],
            transcriptURL: harness.paths.transcripts.appendingPathComponent("Call.md"),
            transcriptId: UUID(),
            systemAudioURL: externalSystemURL,
            micAudioURL: externalMicURL,
            shouldRemoveTemporaryAudioOnCleanup: true,
            onComplete: { _ in }
        )

        harness.manager.cleanupPendingNaming()

        XCTAssertTrue(FileManager.default.fileExists(atPath: externalClipURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalMicURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalSystemURL.path))
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
        let clipURL = harness.paths.speakerClips.appendingPathComponent("speaker.wav")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("mic.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("system.wav")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
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
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
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
    func testHandleNamingCompleteCoalescesSplitSpeakerRowsWithSameName() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let firstSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.21, count: 256),
            existingId: nil
        ).id
        let secondSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.22, count: 256),
            existingId: nil
        ).id
        let thirdSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.23, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Split_Speaker.md")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("split-mic.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("split-system.wav")
        let clipURLs = [
            harness.paths.speakerClips.appendingPathComponent("split-1.wav"),
            harness.paths.speakerClips.appendingPathComponent("split-2.wav"),
            harness.paths.speakerClips.appendingPathComponent("split-3.wav"),
        ]
        let speakers = [
            MarkdownSpeaker(id: "1", persistentSpeakerId: firstSpeakerId, name: "Speaker 1", confidence: "unknown", source: "db_pending"),
            MarkdownSpeaker(id: "2", persistentSpeakerId: secondSpeakerId, name: "Speaker 2", confidence: "unknown", source: "db_pending"),
            MarkdownSpeaker(id: "3", persistentSpeakerId: thirdSpeakerId, name: "Speaker 3", confidence: "unknown", source: "db_pending"),
        ]
        let utterances = [
            MarkdownUtterance(timestamp: "00:01", source: "System", label: "Speaker 1", text: "First fragment.", diarizerSpeakerId: 1),
            MarkdownUtterance(timestamp: "00:05", source: "System", label: "Speaker 2", text: "Second fragment.", diarizerSpeakerId: 2),
            MarkdownUtterance(timestamp: "00:09", source: "System", label: "Speaker 3", text: "Third fragment.", diarizerSpeakerId: 3),
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 2, duration: "00:03"),
                BreakdownEntry(name: "Speaker 2", utterances: 1, wordCount: 2, duration: "00:03"),
                BreakdownEntry(name: "Speaker 3", utterances: 1, wordCount: 2, duration: "00:03"),
            ],
            totalWords: 6
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
        for clipURL in clipURLs {
            try Data().write(to: clipURL)
        }

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
                SpeakerNameUpdate(persistentSpeakerId: firstSpeakerId, diarizerSpeakerId: "1", newName: "Grigory", action: .named),
                SpeakerNameUpdate(persistentSpeakerId: secondSpeakerId, diarizerSpeakerId: "2", newName: "grigory", action: .named),
                SpeakerNameUpdate(persistentSpeakerId: thirdSpeakerId, diarizerSpeakerId: "3", newName: "GRIGORY", action: .named),
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(id: firstSpeakerId, diarizerSpeakerId: "1", clipURL: clipURLs[0], sampleText: "First fragment.", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false, sessionEmbedding: [Float](repeating: 0.21, count: 256)),
                SpeakerNamingEntry(id: secondSpeakerId, diarizerSpeakerId: "2", clipURL: clipURLs[1], sampleText: "Second fragment.", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false, sessionEmbedding: [Float](repeating: 0.22, count: 256)),
                SpeakerNamingEntry(id: thirdSpeakerId, diarizerSpeakerId: "3", clipURL: clipURLs[2], sampleText: "Third fragment.", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false, sessionEmbedding: [Float](repeating: 0.23, count: 256)),
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        let dbIdLines = savedTranscript.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("db_id:") }
        XCTAssertEqual(Set(dbIdLines).count, 1, savedTranscript)
        XCTAssertTrue(savedTranscript.contains("[00:01] [System/Grigory] First fragment."), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("[00:05] [System/Grigory] Second fragment."), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("[00:09] [System/Grigory] Third fragment."), savedTranscript)
        XCTAssertFalse(savedTranscript.contains("[System/grigory]"), savedTranscript)
        XCTAssertFalse(savedTranscript.contains("[System/GRIGORY]"), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("- **Grigory:** 3 utterances, ~6 words, 00:09"), savedTranscript)

        let namedProfiles = harness.speakerDB.allSpeakers().filter { $0.displayName == "Grigory" }
        XCTAssertEqual(namedProfiles.count, 1)
        XCTAssertNil(harness.speakerDB.getSpeaker(id: secondSpeakerId))
        XCTAssertNil(harness.speakerDB.getSpeaker(id: thirdSpeakerId))
    }

    @MainActor
    func testHandleNamingCompleteCoalescesSplitRowsAndSkipsNoDialogSpeaker() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let firstSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.41, count: 256),
            existingId: nil
        ).id
        let secondSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.42, count: 256),
            existingId: nil
        ).id
        let emptySpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.43, count: 256),
            existingId: nil
        ).id
        let emptySpeakerTargetId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.44, count: 256),
            existingId: nil
        ).id
        harness.speakerDB.setDisplayName(id: emptySpeakerTargetId, name: "Known Phantom")
        let emptySpeakerTargetBefore = harness.speakerDB.getSpeaker(id: emptySpeakerTargetId)
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Split_With_No_Dialog.md")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("split-empty-mic.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("split-empty-system.wav")
        let clipURLs = [
            harness.paths.speakerClips.appendingPathComponent("split-empty-1.wav"),
            harness.paths.speakerClips.appendingPathComponent("split-empty-2.wav"),
            harness.paths.speakerClips.appendingPathComponent("split-empty-3.wav"),
        ]
        let speakers = [
            MarkdownSpeaker(id: "1", persistentSpeakerId: firstSpeakerId, name: "Speaker 1", confidence: "unknown", source: "db_pending"),
            MarkdownSpeaker(id: "2", persistentSpeakerId: secondSpeakerId, name: "Speaker 2", confidence: "unknown", source: "db_pending"),
            MarkdownSpeaker(id: "3", persistentSpeakerId: emptySpeakerId, name: "Speaker 3", confidence: "unknown", source: "db_pending"),
        ]
        let utterances = [
            MarkdownUtterance(timestamp: "00:01", source: "System", label: "Speaker 1", text: "First fragment.", diarizerSpeakerId: 1),
            MarkdownUtterance(timestamp: "00:05", source: "System", label: "Speaker 2", text: "Second fragment.", diarizerSpeakerId: 2),
            MarkdownUtterance(timestamp: "00:09", source: "System", label: "Speaker 3", text: "", diarizerSpeakerId: 3),
        ]
        let styledTranscript = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        title: "Styled Meeting"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 0
        system_utterances: 3
        mic_speakers: 0
        system_speakers: 3
        total_word_count: 4
        speakers:
          - id: "1"
            channel: system
            db_id: "\(firstSpeakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
          - id: "2"
            channel: system
            db_id: "\(secondSpeakerId.uuidString)"
            name: "Speaker 2"
            confidence: unknown
            source: db_pending
          - id: "3"
            channel: system
            db_id: "\(emptySpeakerId.uuidString)"
            name: "Speaker 3"
            confidence: unknown
            source: db_pending
        ---

        # Styled Meeting

        Recorded Apr 10, 2026 at 3:01 PM  •  1:30  •  4 words  •  3 turns

        ## Transcript

        **00:01**  [System/Speaker 1]
        First fragment.

        **00:05**  [System/Speaker 2]
        Second fragment.
        """

        try styledTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
        for clipURL in clipURLs {
            try Data().write(to: clipURL)
        }

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
                SpeakerNameUpdate(persistentSpeakerId: firstSpeakerId, diarizerSpeakerId: "1", newName: "Grigory", action: .named),
                SpeakerNameUpdate(persistentSpeakerId: secondSpeakerId, diarizerSpeakerId: "2", newName: "grigory", action: .named),
                SpeakerNameUpdate(persistentSpeakerId: emptySpeakerId, diarizerSpeakerId: "3", newName: "Known Phantom", action: .merged(targetProfileId: emptySpeakerTargetId)),
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(id: firstSpeakerId, diarizerSpeakerId: "1", clipURL: clipURLs[0], sampleText: "First fragment.", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false, sessionEmbedding: [Float](repeating: 0.41, count: 256)),
                SpeakerNamingEntry(id: secondSpeakerId, diarizerSpeakerId: "2", clipURL: clipURLs[1], sampleText: "Second fragment.", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false, sessionEmbedding: [Float](repeating: 0.42, count: 256)),
                SpeakerNamingEntry(id: emptySpeakerId, diarizerSpeakerId: "3", clipURL: clipURLs[2], sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false, sessionEmbedding: [Float](repeating: 0.43, count: 256)),
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("**00:01**  [System/Grigory]"), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("**00:05**  [System/Grigory]"), savedTranscript)
        XCTAssertFalse(savedTranscript.contains("[System/Known Phantom]"), savedTranscript)
        XCTAssertFalse(savedTranscript.contains(#"name: "Known Phantom""#), savedTranscript)

        let namedProfiles = harness.speakerDB.allSpeakers().filter { $0.displayName == "Grigory" }
        XCTAssertEqual(namedProfiles.count, 1)
        XCTAssertNil(harness.speakerDB.getSpeaker(id: secondSpeakerId))
        XCTAssertNil(harness.speakerDB.getSpeaker(id: emptySpeakerId))
        let emptySpeakerTarget = harness.speakerDB.getSpeaker(id: emptySpeakerTargetId)
        XCTAssertEqual(emptySpeakerTarget?.displayName, "Known Phantom")
        XCTAssertGreaterThan(emptySpeakerTarget?.callCount ?? 0, emptySpeakerTargetBefore?.callCount ?? 0)
    }

    @MainActor
    func testHandleNamingCompleteCoalescesCorrectedAndNamedRowsWithSameName() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let matchedSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.31, count: 256),
            existingId: nil
        ).id
        harness.speakerDB.setDisplayName(id: matchedSpeakerId, name: "Matt Vlasach")
        guard let matchedSnapshot = harness.speakerDB.getSpeaker(id: matchedSpeakerId) else {
            XCTFail("Expected matched speaker snapshot")
            return
        }
        let splitSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.32, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Corrected_Split_Speaker.md")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("corrected-split-mic.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("corrected-split-system.wav")
        let firstClipURL = harness.paths.speakerClips.appendingPathComponent("corrected-split-1.wav")
        let secondClipURL = harness.paths.speakerClips.appendingPathComponent("corrected-split-2.wav")
        let speakers = [
            MarkdownSpeaker(id: "1", persistentSpeakerId: matchedSpeakerId, name: "Matt Vlasach", confidence: "medium", source: "db_pending"),
            MarkdownSpeaker(id: "2", persistentSpeakerId: splitSpeakerId, name: "Speaker 2", confidence: "unknown", source: "db_pending"),
        ]
        let utterances = [
            MarkdownUtterance(timestamp: "00:01", source: "System", label: "Matt Vlasach", text: "First fragment.", diarizerSpeakerId: 1),
            MarkdownUtterance(timestamp: "00:05", source: "System", label: "Speaker 2", text: "Second fragment.", diarizerSpeakerId: 2),
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 2, duration: "00:03"),
                BreakdownEntry(name: "Speaker 2", utterances: 1, wordCount: 2, duration: "00:03"),
            ],
            totalWords: 4
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)
        try Data().write(to: firstClipURL)
        try Data().write(to: secondClipURL)

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
                SpeakerNameUpdate(persistentSpeakerId: matchedSpeakerId, diarizerSpeakerId: "1", newName: "Grigory", previousName: "Matt Vlasach", action: .corrected),
                SpeakerNameUpdate(persistentSpeakerId: splitSpeakerId, diarizerSpeakerId: "2", newName: "Grigory", action: .named),
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(id: matchedSpeakerId, diarizerSpeakerId: "1", clipURL: firstClipURL, sampleText: "First fragment.", currentName: "Matt Vlasach", matchSimilarity: 0.86, needsNaming: false, needsConfirmation: true, sessionEmbedding: [Float](repeating: 0.33, count: 256), matchedProfileSnapshot: matchedSnapshot),
                SpeakerNamingEntry(id: splitSpeakerId, diarizerSpeakerId: "2", clipURL: secondClipURL, sampleText: "Second fragment.", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false, sessionEmbedding: [Float](repeating: 0.32, count: 256)),
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        let dbIdLines = savedTranscript.components(separatedBy: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("db_id:") }
        XCTAssertEqual(Set(dbIdLines).count, 1, savedTranscript)
        XCTAssertTrue(savedTranscript.contains("[00:01] [System/Grigory] First fragment."), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("[00:05] [System/Grigory] Second fragment."), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("- **Grigory:** 2 utterances, ~4 words, 00:06"), savedTranscript)

        let namedProfiles = harness.speakerDB.allSpeakers().filter { $0.displayName == "Grigory" }
        XCTAssertEqual(namedProfiles.count, 1)
        XCTAssertNil(harness.speakerDB.getSpeaker(id: splitSpeakerId))
        let restoredProfile = harness.speakerDB.getSpeaker(id: matchedSpeakerId)
        XCTAssertEqual(restoredProfile?.displayName, "Matt Vlasach")
        XCTAssertEqual(restoredProfile?.disputeCount, matchedSnapshot.disputeCount + 1)
    }

    @MainActor
    func testHandleNamingCompleteDoesNotRepublishSavedStatusAfterRenamedTranscriptAlreadyPublished() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        ).id
        let originalURL = harness.paths.transcripts.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let renamedURL = harness.paths.transcripts.appendingPathComponent("Customer_Call.md")
        let clipURL = harness.paths.speakerClips.appendingPathComponent("speaker-renamed.wav")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("mic-renamed.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("system-renamed.wav")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: originalURL, atomically: true, encoding: .utf8)
        harness.manager.publishTranscriptSaved(from: originalURL)
        harness.manager.displayStatus = .idle
        try FileManager.default.moveItem(at: originalURL, to: renamedURL)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        try Data().write(to: clipURL)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)

        harness.manager.speakerNamingRequest = SpeakerNamingRequest(
            speakers: [],
            transcriptURL: originalURL,
            transcriptId: transcriptId,
            systemAudioURL: systemURL,
            micAudioURL: micURL,
            onComplete: { _ in }
        )

        harness.manager.handleNamingComplete(
            updates: [
                SpeakerNameUpdate(
                    persistentSpeakerId: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: originalURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
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
        }

        XCTAssertEqual(harness.manager.displayStatus, .idle)
        XCTAssertEqual(harness.manager.lastSavedTranscriptURL, renamedURL)
        XCTAssertEqual(harness.manager.lastSavedTranscriptId, transcriptId)
        let savedTranscript = try String(contentsOf: renamedURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("Sarah Graham"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
    }

    @MainActor
    func testDeferringSpeakerReviewKeepsUnnamedProfileAndSampleForPeopleSettings() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let clipURL = harness.paths.speakerClips.appendingPathComponent("speaker-defer.wav")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("mic-defer.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("system-defer.wav")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        try Data("clip".utf8).write(to: clipURL)
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
            updates: [],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
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

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains(#"db_id: "\#(persistentSpeakerId.uuidString)""#))
        XCTAssertTrue(savedTranscript.contains(#"name: "Speaker 1""#))
        XCTAssertTrue(savedTranscript.contains("source: db_pending"))
        XCTAssertNil(harness.speakerDB.getSpeaker(id: persistentSpeakerId)?.displayName)
        XCTAssertNotNil(SpeakerClipExtractor.persistentClipURL(for: persistentSpeakerId, clipsDirectory: harness.paths.speakerClips))
        XCTAssertFalse(FileManager.default.fileExists(atPath: clipURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: systemURL.path))
    }

    @MainActor
    func testDeferringTentativeMatchRestoresMatchedProfileAndCreatesUnnamedReviewProfile() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let matchedProfileId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        ).id
        harness.speakerDB.setDisplayName(id: matchedProfileId, name: "Matt Vlasach")
        guard let matchedSnapshot = harness.speakerDB.getSpeaker(id: matchedProfileId) else {
            XCTFail("Expected matched profile snapshot")
            return
        }

        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let clipURL = harness.paths.speakerClips.appendingPathComponent("speaker-defer-match.wav")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("mic-defer-match.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("system-defer-match.wav")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: matchedProfileId,
                name: "Speaker 1",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
        try Data("clip".utf8).write(to: clipURL)
        try Data().write(to: micURL)
        try Data().write(to: systemURL)

        harness.manager.handleNamingComplete(
            updates: [],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: matchedProfileId,
                    diarizerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: "Matt Vlasach",
                    matchSimilarity: 0.9,
                    needsNaming: false,
                    needsConfirmation: true,
                    sessionEmbedding: [Float](repeating: 0.5, count: 256),
                    matchedProfileSnapshot: matchedSnapshot
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let profiles = harness.speakerDB.allSpeakers()
        let deferredProfile = try XCTUnwrap(profiles.first { $0.id != matchedProfileId })
        let restoredProfile = try XCTUnwrap(harness.speakerDB.getSpeaker(id: matchedProfileId))
        XCTAssertEqual(restoredProfile.displayName, "Matt Vlasach")
        XCTAssertNil(deferredProfile.displayName)

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(savedTranscript.contains(#"db_id: "\#(matchedProfileId.uuidString)""#))
        XCTAssertTrue(savedTranscript.contains(#"db_id: "\#(deferredProfile.id.uuidString)""#))
        XCTAssertTrue(savedTranscript.contains(#"name: "Speaker 1""#))
        XCTAssertTrue(savedTranscript.contains("source: db_pending"))
        XCTAssertNotNil(SpeakerClipExtractor.persistentClipURL(for: deferredProfile.id, clipsDirectory: harness.paths.speakerClips))
        XCTAssertNil(SpeakerClipExtractor.persistentClipURL(for: matchedProfileId, clipsDirectory: harness.paths.speakerClips))
    }

    @MainActor
    func testHandleNamingCompleteDiscardDeletesNewProfileAndClearsTranscriptLink() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-discard.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-discard.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-discard.wav")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
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
                    diarizerSpeakerId: "1",
                    newName: "Speaker 1",
                    previousName: nil,
                    action: .discardedFromDatabase
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        XCTAssertNil(harness.speakerDB.getSpeaker(id: persistentSpeakerId))

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(savedTranscript.contains(persistentSpeakerId.uuidString))
        XCTAssertTrue(savedTranscript.contains("source: unknown"))
        XCTAssertTrue(savedTranscript.contains("[00:01] [System/Speaker 1] Thanks for joining."))
    }

    @MainActor
    func testHandleNamingCompleteDiscardRestoresExistingProfileSnapshot() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let matchedProfile = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.2, count: 256),
            existingId: nil
        )
        harness.speakerDB.setDisplayName(
            id: matchedProfile.id,
            name: "Nate",
            source: NameSource.userManual
        )
        guard let matchedSnapshot = harness.speakerDB.getSpeaker(id: matchedProfile.id) else {
            XCTFail("Expected matched profile snapshot")
            return
        }
        _ = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.22, count: 256),
            existingId: matchedProfile.id
        )

        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-discard-existing.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-discard-existing.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-discard-existing.wav")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: matchedProfile.id,
                name: "Speaker 1",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Noisy sample."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 2, duration: "00:03")
            ],
            totalWords: 2
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
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
                    diarizerSpeakerId: "1",
                    newName: "Speaker 1",
                    previousName: "Nate",
                    action: .discardedFromDatabase
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: matchedProfile.id,
                    diarizerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Noisy sample.",
                    currentName: "Nate",
                    matchSimilarity: 0.81,
                    needsNaming: false,
                    needsConfirmation: true,
                    matchedProfileSnapshot: matchedSnapshot
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let restoredProfile = harness.speakerDB.getSpeaker(id: matchedProfile.id)
        XCTAssertEqual(restoredProfile?.displayName, "Nate")
        XCTAssertEqual(restoredProfile?.callCount, matchedSnapshot.callCount)
        XCTAssertEqual(restoredProfile?.disputeCount, matchedSnapshot.disputeCount + 1)

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertFalse(savedTranscript.contains(matchedProfile.id.uuidString))
        XCTAssertTrue(savedTranscript.contains("source: unknown"))
    }

    @MainActor
    func testHandleNamingCompletePreservesMicChannelUpdatesAndLocalBreakdown() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.3, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("MicOnly_2026-04-10_15-01-23.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-mic.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-source.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-source.wav")

        let transcript = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 1
        system_utterances: 0
        mic_speakers: 1
        system_speakers: 0
        total_word_count: 5
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(persistentSpeakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        # Meeting Recording - Apr 10, 2026 at 3:01 PM

        **Duration:** 1:30 | **Words:** 5 | **Utterances:** 1

        ---

        ## Summary

        *Paste into your favorite AI tool for summary generation*

        ---

        ## Channel & Speaker Analytics

        ### Microphone (People in the Room)
        - **Utterances:** 1
        - **Words:** ~5
        - **Speaking Time:** 00:03
        - **Speakers Detected:** 1

        #### Local Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~5 words, 00:03

        ### Meeting Audio (Remote Participants)
        - **Utterances:** 0
        - **Words:** ~0
        - **Speaking Time:** 00:00
        - **Speakers Detected:** 0

        #### Remote Speaker Breakdown


        ---

        ## Full Transcript

        [00:01] [Mic/Speaker 1] I am in the room.

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 1:30 | 5 words | 1 speakers*
        """

        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = TranscriptionResult(
            micUtterances: [
                TranscriptionUtterance(
                    start: 1,
                    end: 4,
                    channel: 0,
                    speakerId: 1,
                    persistentSpeakerId: persistentSpeakerId,
                    matchSimilarity: nil,
                    transcript: "I am in the room."
                )
            ],
            systemUtterances: [],
            duration: 90,
            processingTime: 3.0
        )
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
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    newName: "Michael",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    clipURL: clipURL,
                    sampleText: "I am in the room.",
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

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains(#"channel: mic"#))
        XCTAssertTrue(savedTranscript.contains(#"name: "Michael""#))
        XCTAssertTrue(
            savedTranscript.contains("[00:01] [Mic/Michael] I am in the room."),
            savedTranscript
        )
        XCTAssertTrue(
            savedTranscript.contains("- **Michael:** 1 utterances, ~5 words, 00:03"),
            savedTranscript
        )
        XCTAssertFalse(savedTranscript.contains("[Mic/Speaker 1]"))
    }

    @MainActor
    func testHandleNamingCompleteCanNameOneMicSpeakerAsYouWithoutCollapsingOthers() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let youSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.4, count: 256),
            existingId: nil
        ).id
        let otherSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.7, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("MicRoom_2026-04-10_15-01-23.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-mic-you.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-you-source.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-you-source.wav")

        let transcript = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 2
        system_utterances: 0
        mic_speakers: 2
        system_speakers: 0
        total_word_count: 6
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(youSpeakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
          - id: "2"
            channel: mic
            db_id: "\(otherSpeakerId.uuidString)"
            name: "Speaker 2"
            confidence: unknown
            source: db_pending
        ---

        # Meeting Recording - Apr 10, 2026 at 3:01 PM

        **Duration:** 1:30 | **Words:** 6 | **Utterances:** 2

        ---

        ## Channel & Speaker Analytics

        ### Microphone (People in the Room)
        - **Utterances:** 2
        - **Words:** ~6
        - **Speaking Time:** 00:06
        - **Speakers Detected:** 2

        #### Local Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~3 words, 00:03
        - **Speaker 2:** 1 utterances, ~3 words, 00:03

        ### Meeting Audio (Remote Participants)
        - **Utterances:** 0
        - **Words:** ~0
        - **Speaking Time:** 00:00
        - **Speakers Detected:** 0

        #### Remote Speaker Breakdown


        ---

        ## Full Transcript

        [00:01] [Mic/Speaker 1] I am speaking.

        [00:05] [Mic/Speaker 2] Nate is speaking.

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 1:30 | 6 words | 2 speakers*
        """

        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = TranscriptionResult(
            micUtterances: [
                TranscriptionUtterance(
                    start: 1,
                    end: 4,
                    channel: 0,
                    speakerId: 1,
                    persistentSpeakerId: youSpeakerId,
                    matchSimilarity: nil,
                    transcript: "I am speaking."
                ),
                TranscriptionUtterance(
                    start: 5,
                    end: 8,
                    channel: 0,
                    speakerId: 2,
                    persistentSpeakerId: otherSpeakerId,
                    matchSimilarity: nil,
                    transcript: "Nate is speaking."
                )
            ],
            systemUtterances: [],
            duration: 90,
            processingTime: 3.0
        )
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
                    persistentSpeakerId: youSpeakerId,
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    newName: "You",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: youSpeakerId,
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    clipURL: clipURL,
                    sampleText: "I am speaking.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: [Float](repeating: 0.4, count: 256)
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("### Microphone (People in the Room)"))
        XCTAssertTrue(savedTranscript.contains("#### Local Speaker Breakdown"))
        XCTAssertTrue(savedTranscript.contains("- **You:** 1 utterances, ~3 words, 00:03"))
        XCTAssertTrue(savedTranscript.contains("- **Speaker 2:** 1 utterances, ~3 words, 00:03"))
        XCTAssertTrue(savedTranscript.contains("[00:01] [Mic/You] I am speaking."))
        XCTAssertTrue(savedTranscript.contains("[00:05] [Mic/Speaker 2] Nate is speaking."))
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: youSpeakerId)?.displayName, "You")
        XCTAssertNotNil(harness.speakerDB.getSpeaker(id: otherSpeakerId))
    }

    @MainActor
    func testHandleNamingCompleteSucceedsWhenMicOnlyTranscriptOmitsRemoteBreakdown() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.31, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("MicOnlyNoRemoteBreakdown_2026-04-10_15-01-23.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-mic-no-remote.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-no-remote.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-no-remote.wav")

        let transcript = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 1
        system_utterances: 0
        mic_speakers: 1
        system_speakers: 0
        total_word_count: 5
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(persistentSpeakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        # Meeting Recording - Apr 10, 2026 at 3:01 PM

        **Duration:** 1:30 | **Words:** 5 | **Utterances:** 1

        ---

        ---

        ## Channel & Speaker Analytics

        ### Microphone (People in the Room)
        - **Utterances:** 1
        - **Words:** ~5
        - **Speaking Time:** 00:03
        - **Speakers Detected:** 1

        #### Local Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~5 words, 00:03

        ### Meeting Audio (Remote Participants)
        - **Utterances:** 0
        - **Words:** ~0
        - **Speaking Time:** 00:00
        - **Speakers Detected:** 0

        ---

        ## Full Transcript

        [00:01] [Mic/Speaker 1] I am in the room.

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 1:30 | 5 words | 1 speakers*
        """

        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = TranscriptionResult(
            micUtterances: [
                TranscriptionUtterance(
                    start: 1,
                    end: 4,
                    channel: 0,
                    speakerId: 1,
                    persistentSpeakerId: persistentSpeakerId,
                    matchSimilarity: nil,
                    transcript: "I am in the room."
                )
            ],
            systemUtterances: [],
            duration: 90,
            processingTime: 3.0
        )
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
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    newName: "Michael",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    clipURL: clipURL,
                    sampleText: "I am in the room.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: [Float](repeating: 0.31, count: 256)
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains(#"name: "Michael""#), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("[00:01] [Mic/Michael] I am in the room."), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("- **Michael:** 1 utterances, ~5 words, 00:03"), savedTranscript)
        XCTAssertFalse(savedTranscript.contains("#### Remote Speaker Breakdown"), savedTranscript)
    }

    @MainActor
    func testHandleNamingCompleteCollapsedMicSpeakersToYouRemovesMicProfiles() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.45, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("MicCollapse_2026-04-10_15-01-23.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-collapse.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-collapse.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-collapse.wav")

        let transcript = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 1
        system_utterances: 0
        mic_speakers: 2
        system_speakers: 0
        total_word_count: 5
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(persistentSpeakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        # Meeting Recording - Apr 10, 2026 at 3:01 PM

        **Duration:** 1:30 | **Words:** 5 | **Utterances:** 1

        ---

        ## Summary

        *Paste into your favorite AI tool for summary generation*

        ---

        ## Channel & Speaker Analytics

        ### Microphone (People in the Room)
        - **Utterances:** 1
        - **Words:** ~5
        - **Speaking Time:** 00:03
        - **Speakers Detected:** 2

        #### Local Speaker Breakdown

        - **Speaker 1:** 1 utterances, ~5 words, 00:03

        ### Meeting Audio (Remote Participants)
        - **Utterances:** 0
        - **Words:** ~0
        - **Speaking Time:** 00:00
        - **Speakers Detected:** 0

        #### Remote Speaker Breakdown


        ---

        ## Full Transcript

        [00:01] [Mic/Speaker 1] I am in the room.

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: 1:30 | 5 words | 1 speakers*
        """

        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [],
            newlyCreatedMicProfileIds: [persistentSpeakerId],
            duration: 90,
            processingTime: 3.0
        )
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
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    newName: "You",
                    previousName: "Speaker 1",
                    action: .collapsedToMe
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    clipURL: clipURL,
                    sampleText: "I am in the room.",
                    currentName: "Speaker 1",
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: [Float](repeating: 0.45, count: 256)
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("### Microphone (You)"))
        XCTAssertTrue(savedTranscript.contains("[00:01] [Mic/You] I am in the room."))
        XCTAssertFalse(savedTranscript.contains("#### Local Speaker Breakdown"))
        XCTAssertFalse(savedTranscript.contains(#"channel: mic"#))
        XCTAssertNil(harness.speakerDB.getSpeaker(id: persistentSpeakerId))
    }

    @MainActor
    func testHandleNamingCompleteCollapsedMicSpeakersRestoresMatchedProfile() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let matchedProfile = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.35, count: 256),
            existingId: nil
        )
        harness.speakerDB.setDisplayName(id: matchedProfile.id, name: "Matt Vlasach")
        let matchedSnapshot = try XCTUnwrap(harness.speakerDB.getSpeaker(id: matchedProfile.id))

        _ = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.95, count: 256),
            existingId: matchedProfile.id
        )
        XCTAssertGreaterThan(
            harness.speakerDB.getSpeaker(id: matchedProfile.id)?.callCount ?? 0,
            matchedSnapshot.callCount
        )

        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Matched_Mic_Collapse.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-matched-collapse.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-matched-collapse.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-matched-collapse.wav")

        let transcript = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "1:30"
        sources: [mic, system_audio]
        speakers:
          - id: "1"
            channel: mic
            db_id: "\(matchedProfile.id.uuidString)"
            name: "Matt Vlasach"
            confidence: medium
            source: db_pending
        ---

        ## Channel & Speaker Analytics

        ### Microphone (People in the Room)
        - **Utterances:** 1
        - **Words:** ~5
        - **Speaking Time:** 00:03
        - **Speakers Detected:** 1

        #### Local Speaker Breakdown

        - **Matt Vlasach:** 1 utterances, ~5 words, 00:03

        ---

        ## Full Transcript

        [00:01] [Mic/Matt Vlasach] I am in the room.
        """

        try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
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
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    newName: "You",
                    previousName: "Matt Vlasach",
                    action: .collapsedToMe
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: TranscriptionResult(
                micUtterances: [],
                systemUtterances: [],
                duration: 90,
                processingTime: 3.0
            ),
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: matchedProfile.id,
                    diarizerSpeakerId: "1",
                    channel: .mic,
                    clipURL: clipURL,
                    sampleText: "I am in the room.",
                    currentName: "Matt Vlasach",
                    matchSimilarity: 0.9,
                    needsNaming: false,
                    needsConfirmation: true,
                    sessionEmbedding: [Float](repeating: 0.95, count: 256),
                    matchedProfileSnapshot: matchedSnapshot
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let restoredProfile = try XCTUnwrap(harness.speakerDB.getSpeaker(id: matchedProfile.id))
        XCTAssertEqual(restoredProfile.displayName, "Matt Vlasach")
        XCTAssertEqual(restoredProfile.callCount, matchedSnapshot.callCount)
        XCTAssertEqual(restoredProfile.disputeCount, matchedSnapshot.disputeCount + 1)

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains("[00:01] [Mic/You] I am in the room."))
        XCTAssertFalse(savedTranscript.contains(#"channel: mic"#))
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
        let clipURL = harness.paths.speakerClips.appendingPathComponent("speaker-failure.wav")
        let micURL = harness.paths.audioCaptures.appendingPathComponent("mic-failure.wav")
        let systemURL = harness.paths.audioCaptures.appendingPathComponent("system-failure.wav")
        let transcriptionResult = sampleTranscriptionResult(
            speakers: [
                MarkdownSpeaker(
                    id: "1",
                    persistentSpeakerId: persistentSpeakerId,
                    name: "Speaker 1",
                    confidence: "unknown",
                    source: "db_pending"
                )
            ],
            utterances: [
                MarkdownUtterance(
                    timestamp: "00:01",
                    source: "System",
                    label: "Speaker 1",
                    text: "Thanks for joining."
                )
            ]
        )

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
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: missingTranscriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
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

        XCTAssertNil(
            harness.speakerDB.getSpeaker(id: persistentSpeakerId)?.displayName,
            "speaker DB should stay untouched when transcript rewrite fails"
        )
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
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: renamedTranscriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
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
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: nil,
                    action: .named
                )
            ],
            transcriptURL: originalTranscriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
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
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: matchedProfile.id,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Matt Vlasach",
                text: "Thanks for joining."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
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
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: matchedProfile.id,
                    diarizerSpeakerId: "1",
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
    func testHandleNamingCompleteSucceedsWithoutJSONSidecar() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.35, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Meeting with Speaker 1.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-missing-sidecar.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-missing-sidecar.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-missing-sidecar.wav")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]

        let originalTranscript = sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
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
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: [Float](repeating: 0.35, count: 256)
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertNotEqual(savedTranscript, originalTranscript)
        XCTAssertTrue(savedTranscript.contains("Sarah Graham"))
    }

    @MainActor
    func testHandleNamingCompleteSucceedsAfterMeetingStylerRemovedRemoteBreakdown() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.36, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Styled_Meeting.md")
        let clipURL = tempDirectory.appendingPathComponent("speaker-styled.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-styled.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-styled.wav")
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: persistentSpeakerId,
                name: "Speaker 1",
                confidence: "unknown",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Speaker 1",
                text: "Thanks for joining."
            )
        ]
        let styledTranscript = """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        title: "Styled Meeting"
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
            channel: system
            db_id: "\(persistentSpeakerId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
        ---

        # Styled Meeting

        Recorded Apr 10, 2026 at 3:01 PM  •  1:30  •  5 words  •  1 turn

        ## Transcript

        **00:01**  [System/Speaker 1]
        Thanks for joining.
        """

        try styledTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
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
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Speaker 1",
                    action: .named
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: persistentSpeakerId,
                    diarizerSpeakerId: "1",
                    clipURL: clipURL,
                    sampleText: "Thanks for joining.",
                    currentName: nil,
                    matchSimilarity: nil,
                    needsNaming: true,
                    needsConfirmation: false,
                    sessionEmbedding: [Float](repeating: 0.36, count: 256)
                )
            ]
        )

        try await waitUntil {
            harness.manager.speakerNamingRequest == nil
                && harness.manager.displayStatus == .transcriptSaved
        }

        let savedTranscript = try String(contentsOf: transcriptURL, encoding: .utf8)
        XCTAssertTrue(savedTranscript.contains(#"name: "Sarah Graham""#), savedTranscript)
        XCTAssertTrue(savedTranscript.contains("**00:01**  [System/Sarah Graham]"), savedTranscript)
        XCTAssertFalse(savedTranscript.contains("#### Remote Speaker Breakdown"), savedTranscript)
        XCTAssertEqual(harness.speakerDB.getSpeaker(id: persistentSpeakerId)?.displayName, "Sarah Graham")
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
        let speakers = [
            MarkdownSpeaker(
                id: "1",
                persistentSpeakerId: matchedProfile.id,
                name: "Matt Vlasach",
                confidence: "medium",
                source: "db_pending"
            )
        ]
        let utterances = [
            MarkdownUtterance(
                timestamp: "00:01",
                source: "System",
                label: "Matt Vlasach",
                text: "Thanks for joining."
            )
        ]

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: speakers,
            utterances: utterances,
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        let transcriptionResult = sampleTranscriptionResult(speakers: speakers, utterances: utterances)
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
                    diarizerSpeakerId: "1",
                    newName: "Sarah Graham",
                    previousName: "Matt Vlasach",
                    action: .corrected
                )
            ],
            transcriptURL: transcriptURL,
            transcriptId: transcriptId,
            transcriptionResult: transcriptionResult,
            micURL: micURL,
            systemURL: systemURL,
            clips: [
                SpeakerNamingEntry(
                    id: matchedProfile.id,
                    diarizerSpeakerId: "1",
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
        XCTAssertEqual(
            rejectedProfile?.disputeCount,
            matchedSnapshot.disputeCount,
            "failed transcript rewrites should not partially commit dispute-count changes"
        )
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
        try FileManager.default.createDirectory(at: paths.speakerClips, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.logs, withIntermediateDirectories: true)

        let speakerDB = SpeakerDatabase(path: paths.speakerDB.path)
        let failedManager = FailedTranscriptionManager(paths: paths)
        let manager = TranscriptionTaskManager(
            failedTranscriptionManager: failedManager,
            speechToText: StubSpeechToTextEngine(),
            diarization: StubDiarizationEngine(),
            speakerStore: speakerDB,
            speakerClipsDirectory: paths.speakerClips,
            cleanupDirectories: [paths.audioCaptures, paths.speakerClips]
        )

        return TestHarness(paths: paths, speakerDB: speakerDB, manager: manager)
    }

    private func sampleTranscript(
        transcriptId: UUID,
        speakers: [MarkdownSpeaker],
        utterances: [MarkdownUtterance],
        breakdownEntries: [BreakdownEntry],
        title: String = "Meeting Recording - Apr 10, 2026 at 3:01 PM",
        duration: String = "1:30",
        totalWords: Int = 5
    ) -> String {
        let speakersYAML = speakers.map { speaker in
            """
              - id: "\(speaker.id)"
                db_id: "\(speaker.persistentSpeakerId.uuidString)"
                name: "\(speaker.name)"
                confidence: \(speaker.confidence)
                source: \(speaker.source)
            """
        }.joined(separator: "\n")
        let transcriptBody = utterances.map { utterance in
            "[\(utterance.timestamp)] [\(utterance.source)/\(utterance.label)] \(utterance.text)"
        }.joined(separator: "\n\n")
        let breakdownBody = breakdownEntries.map { entry in
            "- **\(entry.name):** \(entry.utterances) utterances, ~\(entry.wordCount) words, \(entry.duration)"
        }.joined(separator: "\n")

        return """
        ---
        transcript_id: "\(transcriptId.uuidString)"
        date: 2026-04-10
        time: 15:01:23
        duration: "\(duration)"
        processing_time: "3.0s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: 0
        system_utterances: \(utterances.count)
        mic_speakers: 0
        system_speakers: \(speakers.count)
        total_word_count: \(totalWords)
        speakers:
        \(speakersYAML)
        ---

        # \(title)

        **Duration:** \(duration) | **Words:** \(totalWords) | **Utterances:** \(utterances.count)

        ---

        ## Channel & Speaker Analytics

        ### Microphone (You)
        - **Utterances:** 0
        - **Words:** ~0
        - **Speaking Time:** 00:00

        ### Meeting Audio (Remote Participants)
        - **Utterances:** \(utterances.count)
        - **Words:** ~\(totalWords)
        - **Speaking Time:** 00:03
        - **Speakers Detected:** \(speakers.count)

        #### Remote Speaker Breakdown

        \(breakdownBody)

        ---

        ## Full Transcript

        \(transcriptBody)

        ---

        *Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: \(duration) | \(totalWords) words | \(speakers.count) speakers*
        """
    }

    private func sampleTranscriptionResult(
        speakers: [MarkdownSpeaker],
        utterances: [MarkdownUtterance],
        duration: TimeInterval = 90
    ) -> TranscriptionResult {
        let speakersById = Dictionary(uniqueKeysWithValues: speakers.compactMap { speaker in
            Int(speaker.id).map { ($0, speaker) }
        })
        let speakersByName = Dictionary(grouping: speakers) { normalizeSpeakerLabel($0.name) }

        let mappedUtterances = utterances.map { utterance -> TranscriptionUtterance in
            let channel = utterance.source.caseInsensitiveCompare("Mic") == .orderedSame ? 0 : 1
            let speakerId = utterance.diarizerSpeakerId
                ?? resolvedSpeakerId(
                    for: utterance,
                    channel: channel,
                    speakersByName: speakersByName
                )
            let persistentSpeakerId = speakersById[speakerId]?.persistentSpeakerId
            let start = timestampSeconds(for: utterance.timestamp)

            return TranscriptionUtterance(
                start: start,
                end: start + utterance.speakingSeconds,
                channel: channel,
                speakerId: speakerId,
                persistentSpeakerId: persistentSpeakerId,
                matchSimilarity: nil,
                transcript: utterance.text
            )
        }

        return TranscriptionResult(
            micUtterances: mappedUtterances.filter { $0.channel == 0 },
            systemUtterances: mappedUtterances.filter { $0.channel == 1 },
            duration: duration,
            processingTime: 3.0
        )
    }

    private func resolvedSpeakerId(
        for utterance: MarkdownUtterance,
        channel: Int,
        speakersByName: [String: [MarkdownSpeaker]]
    ) -> Int {
        if let parsedId = Int(utterance.label.replacingOccurrences(of: "Speaker ", with: "")) {
            return parsedId
        }

        let normalizedLabel = normalizeSpeakerLabel(utterance.label)
        if let match = speakersByName[normalizedLabel], match.count == 1, let id = Int(match[0].id) {
            return id
        }

        return channel == 0 ? 0 : 1
    }

    private func normalizeSpeakerLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func timestampSeconds(for timestamp: String) -> Double {
        let parts = timestamp.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 else { return 0 }
        return (parts[0] * 60) + parts[1]
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
