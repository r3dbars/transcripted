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
    func testHandleNamingCompletePublishesSuccessAfterTranscriptRewrite() async throws {
        let harness = try makeHarness()
        let transcriptId = UUID()
        let persistentSpeakerId = harness.speakerDB.addOrUpdateSpeaker(
            embedding: [Float](repeating: 0.25, count: 256),
            existingId: nil
        ).id
        let transcriptURL = harness.paths.transcripts.appendingPathComponent("Call_2026-04-10_15-01-23.md")
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let clipURL = tempDirectory.appendingPathComponent("speaker.wav")
        let micURL = tempDirectory.appendingPathComponent("mic.wav")
        let systemURL = tempDirectory.appendingPathComponent("system.wav")

        try sampleTranscript(
            transcriptId: transcriptId,
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
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        try writeSidecar(
            to: jsonURL,
            transcriptId: transcriptId,
            speakers: [
                AgentSpeaker(
                    id: "system_1",
                    persistentSpeakerId: persistentSpeakerId.uuidString,
                    name: "Speaker 1",
                    confidence: "unknown",
                    wordCount: 5,
                    speakingSeconds: 3.0
                )
            ],
            utterances: [
                AgentUtterance(start: 1.0, end: 4.0, speakerId: "system_1", text: "Thanks for joining.")
            ]
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
        let savedSidecar = try JSONDecoder().decode(AgentTranscript.self, from: Data(contentsOf: jsonURL))
        XCTAssertEqual(savedSidecar.speakers.first?.name, "Sarah Graham")
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
        let renamedJSONURL = renamedTranscriptURL.deletingPathExtension().appendingPathExtension("json")
        let clipURL = tempDirectory.appendingPathComponent("speaker-renamed.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-renamed.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-renamed.wav")

        try sampleTranscript(
            transcriptId: transcriptId,
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
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: renamedTranscriptURL, atomically: true, encoding: .utf8)
        try writeSidecar(
            to: renamedJSONURL,
            transcriptId: transcriptId,
            speakers: [
                AgentSpeaker(
                    id: "system_1",
                    persistentSpeakerId: persistentSpeakerId.uuidString,
                    name: "Speaker 1",
                    confidence: "unknown",
                    wordCount: 5,
                    speakingSeconds: 3.0
                )
            ],
            utterances: [
                AgentUtterance(start: 1.0, end: 4.0, speakerId: "system_1", text: "Thanks for joining.")
            ]
        )
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
        let savedSidecar = try JSONDecoder().decode(AgentTranscript.self, from: Data(contentsOf: renamedJSONURL))
        XCTAssertEqual(savedSidecar.speakers.first?.name, "Sarah Graham")
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
        let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
        let clipURL = tempDirectory.appendingPathComponent("speaker-correction.wav")
        let micURL = tempDirectory.appendingPathComponent("mic-correction.wav")
        let systemURL = tempDirectory.appendingPathComponent("system-correction.wav")

        try sampleTranscript(
            transcriptId: transcriptId,
            speakers: [
                MarkdownSpeaker(
                    id: "1",
                    persistentSpeakerId: matchedProfile.id,
                    name: "Matt Vlasach",
                    confidence: "medium",
                    source: "db_pending"
                )
            ],
            utterances: [
                MarkdownUtterance(
                    timestamp: "00:01",
                    source: "System",
                    label: "Matt Vlasach",
                    text: "Thanks for joining."
                )
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        ).write(to: transcriptURL, atomically: true, encoding: .utf8)
        try writeSidecar(
            to: jsonURL,
            transcriptId: transcriptId,
            speakers: [
                AgentSpeaker(
                    id: "system_1",
                    persistentSpeakerId: matchedProfile.id.uuidString,
                    name: "Matt Vlasach",
                    confidence: "medium",
                    wordCount: 5,
                    speakingSeconds: 3.0
                )
            ],
            utterances: [
                AgentUtterance(start: 1.0, end: 4.0, speakerId: "system_1", text: "Thanks for joining.")
            ]
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
        let savedSidecar = try JSONDecoder().decode(AgentTranscript.self, from: Data(contentsOf: jsonURL))
        XCTAssertEqual(savedSidecar.speakers.first?.name, "Sarah Graham")
        XCTAssertEqual(savedSidecar.speakers.first?.persistentSpeakerId, targetProfile.id.uuidString)

        let rejectedProfile = harness.speakerDB.getSpeaker(id: matchedProfile.id)
        XCTAssertEqual(rejectedProfile?.displayName, "Matt Vlasach")
        XCTAssertEqual(rejectedProfile?.disputeCount, matchedSnapshot.disputeCount + 1)

        let correctedProfile = harness.speakerDB.getSpeaker(id: targetProfile.id)
        XCTAssertEqual(correctedProfile?.displayName, "Sarah Graham")
        XCTAssertEqual(correctedProfile?.disputeCount, 0)
        XCTAssertGreaterThan(correctedProfile?.callCount ?? 0, targetBefore?.callCount ?? 0)
    }

    @MainActor
    func testHandleNamingCompletePublishesFailureWhenSidecarMissing() async throws {
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

        let originalTranscript = sampleTranscript(
            transcriptId: transcriptId,
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
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Speaker 1", utterances: 1, wordCount: 5, duration: "00:03")
            ]
        )
        try originalTranscript.write(to: transcriptURL, atomically: true, encoding: .utf8)
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
                    previousName: "Speaker 1",
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
                    sessionEmbedding: [Float](repeating: 0.35, count: 256)
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

        XCTAssertEqual(try String(contentsOf: transcriptURL, encoding: .utf8), originalTranscript)
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
            speakers: [
                MarkdownSpeaker(
                    id: "1",
                    persistentSpeakerId: matchedProfile.id,
                    name: "Matt Vlasach",
                    confidence: "medium",
                    source: "db_pending"
                )
            ],
            utterances: [
                MarkdownUtterance(
                    timestamp: "00:01",
                    source: "System",
                    label: "Matt Vlasach",
                    text: "Thanks for joining."
                )
            ],
            breakdownEntries: [
                BreakdownEntry(name: "Matt Vlasach", utterances: 1, wordCount: 5, duration: "00:03")
            ]
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

        ## Summary

        *Paste into your favorite AI tool for summary generation*

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

    private func writeSidecar(
        to url: URL,
        transcriptId: UUID,
        speakers: [AgentSpeaker],
        utterances: [AgentUtterance]
    ) throws {
        let transcript = AgentTranscript(
            version: "1.0",
            transcriptId: transcriptId.uuidString,
            recording: AgentRecording(
                date: "2026-04-10T15:01:23-0500",
                durationSeconds: 90,
                droppedSegments: 0,
                engines: AgentEngines(stt: "parakeet-tdt-v3", diarization: "pyannote-offline")
            ),
            speakers: speakers,
            utterances: utterances
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transcript).write(to: url, options: .atomic)
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
