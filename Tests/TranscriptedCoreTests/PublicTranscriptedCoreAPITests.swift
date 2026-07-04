import XCTest
import TranscriptedCore

@available(macOS 14.0, *)
final class PublicTranscriptedCoreAPITests: XCTestCase {

    func testPublicCoreStoragePathsAndRecordingValidatorAreImportable() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PublicTranscriptedCoreAPITests-\(UUID().uuidString)", isDirectory: true)
        let paths = CoreStoragePaths(
            transcripts: root.appendingPathComponent("meetings", isDirectory: true),
            speakerDB: root.appendingPathComponent("speakers.sqlite"),
            statsDB: root.appendingPathComponent("stats.sqlite"),
            failedQueue: root.appendingPathComponent("failed.json"),
            speakerClips: root.appendingPathComponent("clips", isDirectory: true),
            audioCaptures: root.appendingPathComponent("recordings", isDirectory: true),
            logs: root.appendingPathComponent("logs", isDirectory: true)
        )

        XCTAssertEqual(paths.transcripts.lastPathComponent, "meetings")
        XCTAssertEqual(RecordingValidator.minimumDiskSpace, 1024 * 1024 * 1024)
        XCTAssertTrue(RecordingValidator.validateSavePath(paths.transcripts).isValid)
    }

    func testLegacyTranscriptStorageConformerCanOmitFormatOptions() {
        LegacyTranscriptStorage.didUseLegacySave = false
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [],
            duration: 0,
            processingTime: 0
        )

        _ = LegacyTranscriptStorage.saveTranscript(
            result,
            transcriptId: UUID(),
            speakerMappings: [:],
            speakerSources: [:],
            speakerDbIds: [:],
            directory: nil,
            meetingTitle: nil,
            healthInfo: nil,
            notifier: nil,
            speakerStore: nil,
            statsStore: nil,
            formatOptions: .default
        )

        XCTAssertTrue(LegacyTranscriptStorage.didUseLegacySave)
    }
}

@available(macOS 14.0, *)
private enum LegacyTranscriptStorage: TranscriptStorage {
    static var didUseLegacySave = false
    static var defaultSaveDirectory: URL { FileManager.default.temporaryDirectory }

    static func saveTranscript(
        _ result: TranscriptionResult,
        transcriptId: UUID,
        speakerMappings: [String: SpeakerMapping],
        speakerSources: [String: String],
        speakerDbIds: [String: UUID],
        directory: URL?,
        meetingTitle: String?,
        healthInfo: RecordingHealthInfo?,
        notifier: TranscriptNotifier?,
        speakerStore: (any SpeakerStore)?,
        statsStore: (any StatsStore)?
    ) -> URL? {
        didUseLegacySave = true
        return nil
    }

    static func updateSpeakerNames(
        transcriptURL: URL,
        updates: [SpeakerNameUpdate],
        transcriptionResult: TranscriptionResult,
        speakerStore: (any SpeakerStore)?
    ) -> Bool {
        false
    }

    static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String) {}
}
