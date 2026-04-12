import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class AgentOutputTests: XCTestCase {

    func testRemoveLegacyAgentHelperFilesDeletesLegacyDocsOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AgentOutputTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let agentURL = root.appendingPathComponent("AGENT.md")
        let claudeURL = root.appendingPathComponent("CLAUDE.md")
        let indexURL = root.appendingPathComponent("transcripted.json")

        try "agent".write(to: agentURL, atomically: true, encoding: .utf8)
        try "claude".write(to: claudeURL, atomically: true, encoding: .utf8)
        try "{}".write(to: indexURL, atomically: true, encoding: .utf8)

        AgentOutput.removeLegacyAgentHelperFiles(from: root)

        XCTAssertFalse(FileManager.default.fileExists(atPath: agentURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: claudeURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
    }

    func testTranscriptSaverWritesMarkdownSidecarAndIndex() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TranscriptSaverArtifactTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let persistentSpeakerId = UUID()
        let result = TranscriptionResult(
            micUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 1.2,
                    channel: 0,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Thanks for joining."
                )
            ],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 1.5,
                    end: 4.2,
                    channel: 1,
                    speakerId: 1,
                    persistentSpeakerId: persistentSpeakerId,
                    matchSimilarity: 0.92,
                    transcript: "Happy to help."
                )
            ],
            duration: 5,
            processingTime: 0.25
        )

        let speakerStore = TestSpeakerStore(
            speakers: [
                SpeakerProfile(
                    id: persistentSpeakerId,
                    displayName: "Alex",
                    nameSource: NameSource.userManual,
                    embedding: [Float](repeating: 0.5, count: 256),
                    firstSeen: Date(timeIntervalSince1970: 0),
                    lastSeen: Date(timeIntervalSince1970: 0),
                    callCount: 3,
                    confidence: 0.9,
                    disputeCount: 0
                )
            ]
        )

        let savedURL = TranscriptSaver.saveTranscript(
            result,
            transcriptId: UUID(),
            speakerMappings: [
                "system_1": SpeakerMapping(
                    speakerId: "1",
                    identifiedName: "Alex",
                    confidence: .high,
                    isConfirmedIdentity: true
                )
            ],
            speakerSources: ["1": "user_manual"],
            speakerDbIds: ["1": persistentSpeakerId],
            directory: root,
            healthInfo: .perfect,
            speakerStore: speakerStore,
            statsStore: TestStatsStore()
        )

        XCTAssertNotNil(savedURL)

        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let markdownFiles = files.filter { $0.pathExtension == "md" }
        let jsonFiles = files.filter { $0.pathExtension == "json" && $0.lastPathComponent != "transcripted.json" }
        let indexURL = root.appendingPathComponent("transcripted.json")

        XCTAssertEqual(markdownFiles.count, 1)
        XCTAssertEqual(jsonFiles.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: indexURL.path))
        XCTAssertEqual(markdownFiles[0].deletingPathExtension().lastPathComponent, jsonFiles[0].deletingPathExtension().lastPathComponent)

        let sidecarData = try Data(contentsOf: jsonFiles[0])
        let sidecar = try JSONSerialization.jsonObject(with: sidecarData) as? [String: Any]
        let speakers = sidecar?["speakers"] as? [[String: Any]]
        XCTAssertEqual(speakers?.count, 2)
        XCTAssertEqual(speakers?.last?["persistent_speaker_id"] as? String, persistentSpeakerId.uuidString)

        let indexData = try Data(contentsOf: indexURL)
        let index = try JSONSerialization.jsonObject(with: indexData) as? [String: Any]
        let transcripts = index?["transcripts"] as? [[String: Any]]
        XCTAssertEqual(transcripts?.count, 1)
        XCTAssertEqual(transcripts?.first?["filename"] as? String, markdownFiles[0].deletingPathExtension().lastPathComponent)
    }
}

@available(macOS 14.0, *)
private final class TestSpeakerStore: SpeakerStore {
    private let speakers: [SpeakerProfile]

    init(speakers: [SpeakerProfile]) {
        self.speakers = speakers
    }

    func matchSpeaker(embedding: [Float], threshold: Double) -> SpeakerMatchResult? { nil }
    func addOrUpdateSpeaker(embedding: [Float], existingId: UUID?) -> SpeakerProfile { speakers[0] }
    func getSpeaker(id: UUID) -> SpeakerProfile? { speakers.first { $0.id == id } }
    func allSpeakers() -> [SpeakerProfile] { speakers }
    func setDisplayName(id: UUID, name: String, source: String) {}
    func restoreProfile(_ profile: SpeakerProfile) {}
    func deleteSpeaker(id: UUID) {}
    func mergeProfiles(sourceId: UUID, into targetId: UUID) {}
    func mergeProfilesByName() {}
    func mergeDuplicates() {}
    func pruneWeakProfiles() {}
    func incrementDisputeCount(id: UUID) {}
    func resetDisputeCount(id: UUID) {}
    func findProfilesByName(_ name: String) -> [SpeakerProfile] { [] }
}

@available(macOS 14.0, *)
private final class TestStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}
    func getTotalRecordingsCount() -> Int { 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }
    func recordingExists(transcriptPath: String) -> Bool { false }
}
