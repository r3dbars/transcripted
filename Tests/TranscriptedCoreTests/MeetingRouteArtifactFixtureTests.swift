import XCTest
@testable import TranscriptedCore

@available(macOS 14.0, *)
final class MeetingRouteArtifactFixtureTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeetingRouteArtifactFixtureTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        super.tearDown()
    }

    func testTranscriptSaverAndAudioArchiverProduceSyntheticRouteArtifacts() throws {
        let scratch = tempRoot.appendingPathComponent("scratch", isDirectory: true)
        let meetings = tempRoot.appendingPathComponent("meetings", isDirectory: true)
        let retainedAudioRoot = meetings.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

        let micURL = scratch.appendingPathComponent("webrtc-shared-mic.wav")
        let systemURL = scratch.appendingPathComponent("webrtc-system-audio.wav")
        try Data("synthetic mic audio only".utf8).write(to: micURL)
        try Data("synthetic system audio only".utf8).write(to: systemURL)

        let result = TranscriptionResult(
            micUtterances: [
                TranscriptionUtterance(
                    start: 0,
                    end: 2,
                    channel: 0,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Transcripted route fixture one two three."
                )
            ],
            systemUtterances: [
                TranscriptionUtterance(
                    start: 0.5,
                    end: 2.5,
                    channel: 1,
                    speakerId: 0,
                    persistentSpeakerId: nil,
                    matchSimilarity: nil,
                    transcript: "Synthetic system audio fixture tone."
                )
            ],
            duration: 3,
            processingTime: 0.2
        )

        let transcriptURL = try XCTUnwrap(
            TranscriptSaver.saveTranscript(
                result,
                transcriptId: UUID(uuidString: "00000000-0000-0000-0000-000000000500")!,
                directory: meetings,
                meetingTitle: "Synthetic Route Fixture",
                healthInfo: RecordingHealthInfo(
                    captureQuality: .good,
                    audioGaps: 1,
                    deviceSwitches: 2,
                    gapDescriptions: ["synthetic route-change gap"]
                ),
                statsStore: MeetingRouteArtifactNoopStatsStore(),
                recordingDate: Date(timeIntervalSince1970: 1_750_000_000),
                transcriptionEngine: .parakeetLocal,
                formatOptions: TranscriptFormatOptions(audioSources: [.microphone, .systemAudio])
            )
        )

        let markdown = try String(contentsOf: transcriptURL, encoding: .utf8)
        let values = try XCTUnwrap(TranscriptFrontmatter.values(in: markdown))
        XCTAssertEqual(values["capture_type"], "meeting")
        XCTAssertEqual(values["sources"], "[mic, system_audio]")
        XCTAssertEqual(values["capture_quality"], "good")
        XCTAssertEqual(values["audio_gaps"], "1")
        XCTAssertEqual(values["device_switches"], "2")
        XCTAssertTrue(markdown.contains("Transcripted route fixture one two three."))
        XCTAssertTrue(markdown.contains("Synthetic system audio fixture tone."))
        XCTAssertFalse(markdown.contains("/Users/"), "route fixture transcript must not leak local paths")

        let retained = try RecordingAudioArchiver.archive(
            micURL: micURL,
            systemURL: systemURL,
            transcriptURL: transcriptURL,
            archiveRoot: retainedAudioRoot
        )

        XCTAssertEqual(retained.directory.lastPathComponent, "\(transcriptURL.deletingPathExtension().lastPathComponent)_audio")
        XCTAssertEqual(retained.micURL?.lastPathComponent, "microphone.wav")
        XCTAssertEqual(retained.systemURL?.lastPathComponent, "system_audio.wav")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(retained.micURL)), Data("synthetic mic audio only".utf8))
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(retained.systemURL)), Data("synthetic system audio only".utf8))
    }
}

@available(macOS 14.0, *)
private final class MeetingRouteArtifactNoopStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}

    func getTotalRecordingsCount() -> Int { 0 }

    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }

    func recordingExists(transcriptPath: String) -> Bool { false }
}
