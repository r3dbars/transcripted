import XCTest
@testable import TranscriptedCore

/// Promise: a saved meeting's `diarization_engine` and `voiceprint_model` name
/// the diarizer and voiceprint model that actually ran for it, read when the
/// diarizer ran, so a Nemotron load that fell back to pyannote reads pyannote.
@available(macOS 14.0, *)
@MainActor
extension TranscriptionTaskManagerMetadataTests {
    func testSavedMeetingRecordsNemotronBackendAndVoiceprintModel() async throws {
        let values = try await importAndReadFrontmatter(diarization: MetadataStubDiarizationEngine(
            segments: diarizationEngineTestSegments(),
            runDescriptor: DiarizationRunDescriptor(backend: .nemotron, voiceprintModel: "redimnet2-b4")
        ))

        XCTAssertEqual(values["diarization_engine"], "nemotron_offline")
        XCTAssertEqual(values["voiceprint_model"], "redimnet2-b4")
    }

    func testSavedMeetingRecordsPyannoteWhenNemotronFellBackDuringModelLoad() async throws {
        let values = try await importAndReadFrontmatter(diarization: MetadataStubDiarizationEngine(
            isReady: false,
            segments: diarizationEngineTestSegments(),
            runDescriptor: DiarizationRunDescriptor(backend: .nemotron, voiceprintModel: "redimnet2-b4"),
            runDescriptorAfterInitialize: DiarizationRunDescriptor(backend: .pyannote, voiceprintModel: "redimnet2-b4")
        ))

        XCTAssertEqual(values["diarization_engine"], "pyannote_offline")
        XCTAssertEqual(values["voiceprint_model"], "redimnet2-b4")
    }

    func testSavedMeetingOmitsVoiceprintModelWhenTheDiarizerNamesNone() async throws {
        let values = try await importAndReadFrontmatter(diarization: MetadataStubDiarizationEngine(
            segments: diarizationEngineTestSegments()
        ))

        XCTAssertEqual(values["diarization_engine"], "pyannote_offline")
        XCTAssertNil(values["voiceprint_model"])
    }

    private func diarizationEngineTestSegments() -> [SpeakerSegment] {
        [SpeakerSegment(
            speakerId: 1,
            startTime: 0,
            endTime: 2,
            embedding: [Float](repeating: 0.42, count: 256),
            qualityScore: 0.95
        )]
    }

    private func importAndReadFrontmatter(diarization: MetadataStubDiarizationEngine) async throws -> [String: String] {
        let manager = makeManager(
            speechToText: MetadataStubSpeechToTextEngine(transcript: "Synthetic diarization engine check."),
            diarization: diarization
        )
        let audioURL = tempDirectory.appendingPathComponent("diarization-engine-\(UUID().uuidString).wav")
        try writeMonoWAV(to: audioURL, duration: 2.5)

        manager.startImportedTranscription(
            audioURL: audioURL,
            outputFolder: tempDirectory.appendingPathComponent("transcripts"),
            meetingTitle: "Synthetic call"
        )
        try await waitUntil {
            manager.lastSavedTranscriptURL != nil && manager.activeTasks.isEmpty
        }

        let transcriptURL = try XCTUnwrap(manager.lastSavedTranscriptURL)
        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        return try XCTUnwrap(TranscriptFrontmatter.values(in: markdown))
    }
}
