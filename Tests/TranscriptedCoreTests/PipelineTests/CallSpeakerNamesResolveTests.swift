import XCTest
@testable import TranscriptedCore

/// Promises for the whole call-app naming step after classification
/// (`TranscriptionTaskManager.callSpeakerNames`), and for renames of a saved
/// call-named transcript:
/// - imports never get call-app names;
/// - a voiceprint that suggests someone else (from classification knowledge
///   or from the voice's profile) keeps the call name off that voice;
/// - a voice with no review row gets no call name;
/// - no two call-audio voices end up shown under the same name: two voices
///   the call app named the same are both withheld, and so is a call name
///   another voice already shows (an auto-accepted voiceprint name);
/// - naming one of two rows that share a name never renames the other's
///   body labels;
/// - renaming or merging a person in Settings drops `name_source`.
@available(macOS 14.0, *)
final class CallSpeakerNamesResolveTests: XCTestCase {
    private typealias Policy = CallSpeakerAttributionPolicy
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallSpeakerNamesResolveTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    // MARK: - Fixtures

    private let profile1 = UUID()
    private let profile2 = UUID()

    /// Voice 1 talks 0–10 s, voice 2 talks 10–20 s; both have profiles.
    private func utterances(voice2Profile: UUID?? = .none) -> [TranscriptionUtterance] {
        let second: UUID? = voice2Profile ?? profile2
        return [
            TranscriptionUtterance(start: 0, end: 10, channel: 1, speakerId: 1, persistentSpeakerId: profile1, matchSimilarity: nil, transcript: "one"),
            TranscriptionUtterance(start: 10, end: 20, channel: 1, speakerId: 2, persistentSpeakerId: second, matchSimilarity: nil, transcript: "two"),
        ]
    }

    /// The call app showed `first` talking 0–10 s and `second` 10–20 s.
    private func activity(_ first: String, _ second: String) -> CallSpeakerActivity {
        CallSpeakerActivity(
            intervals: [
                CallSpeakerActivity.Interval(name: first, start: 0, end: 10),
                CallSpeakerActivity.Interval(name: second, start: 10, end: 20),
            ],
            rosterNames: [first, second],
            selfNames: [],
            sawSpeakingIndicator: true
        )
    }

    private func knowledge(_ speakerId: String, name: String) -> TranscriptionTaskManager.SpeakerClassificationKnowledge {
        TranscriptionTaskManager.SpeakerClassificationKnowledge(
            speakerId: speakerId,
            profile: SpeakerProfile(
                id: UUID(), displayName: name, nameSource: NameSource.userManual, embedding: [],
                firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0),
                callCount: 3, confidence: 0.9, disputeCount: 0
            ),
            similarity: 0.6,
            secondSimilarity: nil,
            averageSimilarity: nil,
            secondAverageSimilarity: nil
        )
    }

    private struct Run {
        var names: [String: String]
        var applied: TranscriptionTaskManager.CallSpeakerNamesApplied?
        var mappings: [String: SpeakerMapping]
        var sources: [String: String]
    }

    private func run(
        isImport: Bool = false,
        activity: CallSpeakerActivity,
        utterances: [TranscriptionUtterance],
        dbKnowledge: [TranscriptionTaskManager.SpeakerClassificationKnowledge] = [],
        autoAcceptedIds: Set<String> = [],
        reviewIds: Set<String> = ["1", "2"],
        profileNames: [UUID: String] = [:],
        mappings: [String: SpeakerMapping] = [:],
        sources: [String: String] = [:]
    ) -> Run {
        var mappings = mappings
        var sources = sources
        let resolved = TranscriptionTaskManager.callSpeakerNames(
            isImport: isImport,
            activity: activity,
            systemUtterances: utterances,
            dbKnowledge: dbKnowledge,
            autoAcceptedIds: autoAcceptedIds,
            reviewIds: reviewIds,
            profileName: { profileNames[$0] },
            speakerMappings: &mappings,
            speakerSources: &sources
        )
        return Run(names: resolved?.applied.namesBySpeakerId ?? [:], applied: resolved?.applied, mappings: mappings, sources: sources)
    }

    // MARK: - Resolving names

    func testTwoClearVoicesBothGetTheirCallNames() {
        let result = run(activity: activity("Alex Kim", "Blair Ng"), utterances: utterances())
        XCTAssertEqual(result.names, ["1": "Alex Kim", "2": "Blair Ng"])
        XCTAssertEqual(result.mappings["system_1"]?.displayName, "Alex Kim")
        XCTAssertEqual(result.sources["system_1"], "db_pending")
    }

    func testImportsNeverGetCallNames() {
        let result = run(isImport: true, activity: activity("Alex Kim", "Blair Ng"), utterances: utterances())
        XCTAssertNil(result.applied)
        XCTAssertTrue(result.names.isEmpty)
        XCTAssertTrue(result.mappings.isEmpty)
    }

    func testVoiceprintKnowledgeSuggestingSomeoneElseWithholds() {
        let result = run(
            activity: activity("Alex Kim", "Blair Ng"),
            utterances: utterances(),
            dbKnowledge: [knowledge("1", name: "Jordan Lee")]
        )
        XCTAssertEqual(result.names, ["2": "Blair Ng"])
        XCTAssertEqual(result.applied?.voiceprintConflicts, 1)
    }

    func testProfileNameSuggestingSomeoneElseWithholds() {
        // No classification knowledge for voice 2: its profile's name is the
        // voiceprint suggestion.
        let result = run(
            activity: activity("Alex Kim", "Blair Ng"),
            utterances: utterances(),
            profileNames: [profile2: "Casey Diaz"]
        )
        XCTAssertEqual(result.names, ["1": "Alex Kim"])
        XCTAssertEqual(result.applied?.voiceprintConflicts, 1)
    }

    func testProfileNameAgreeingKeepsTheCallName() {
        let result = run(
            activity: activity("Alex Kim", "Blair Ng"),
            utterances: utterances(),
            profileNames: [profile2: "blair  ng"]
        )
        XCTAssertEqual(result.names, ["1": "Alex Kim", "2": "Blair Ng"])
    }

    func testVoiceWithoutAReviewRowIsSkipped() {
        // Voice 2 has no voiceprint profile, so the pipeline gives it no
        // review row: nothing would ever confirm or correct a call name.
        let result = run(
            activity: activity("Alex Kim", "Blair Ng"),
            utterances: utterances(voice2Profile: .some(nil)),
            reviewIds: ["1"]
        )
        XCTAssertEqual(result.names, ["1": "Alex Kim"])
        XCTAssertNil(result.mappings["system_2"])
        XCTAssertEqual(result.applied?.noReviewRowSkipped, 1)
    }

    func testTwoVoicesWithTheSameCallNameAreBothWithheld() {
        // The diarizer split one person into two voices (or two people share
        // a display name): one body label would cover both voices.
        let result = run(activity: activity("Alex Kim", "alex  kim"), utterances: utterances())
        XCTAssertTrue(result.names.isEmpty)
        XCTAssertEqual(result.applied?.withheld, ["1": .nameShared, "2": .nameShared])
        XCTAssertNil(result.mappings["system_1"]?.shownNameSource)
        XCTAssertNil(result.mappings["system_2"]?.shownNameSource)
    }

    func testCallNameEqualToAnAutoAcceptedVoiceIsWithheld() {
        // Voice 1 is auto-accepted by voiceprint as Alex Kim; the call app
        // also names voice 2 Alex Kim.
        let mappings = ["system_1": SpeakerMapping(speakerId: "1", identifiedName: "Alex Kim", confidence: .high, isConfirmedIdentity: true)]
        let result = run(
            activity: activity("Blair Ng", "ALEX KIM"),
            utterances: utterances(),
            autoAcceptedIds: ["1"],
            reviewIds: ["2"],
            mappings: mappings,
            sources: ["system_1": "db"]
        )
        XCTAssertTrue(result.names.isEmpty)
        XCTAssertEqual(result.applied?.withheld, ["2": .nameShared])
        XCTAssertEqual(result.mappings["system_1"]?.displayName, "Alex Kim")
        XCTAssertEqual(result.mappings["system_2"]?.displayName ?? "Speaker 2", "Speaker 2")
    }

    // MARK: - Renaming a saved file

    func testNamingOneOfTwoSameNamedRowsLeavesTheOtherVoiceBody() throws {
        // A transcript where two system voices are shown under one name (an
        // older call-named file). Naming voice 1 must not rename voice 2.
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: TranscriptionResult(micUtterances: [], systemUtterances: utterances(), duration: 20, processingTime: 1),
            transcriptId: UUID(),
            speakerMappings: [
                "system_1": SpeakerMapping(speakerId: "1", identifiedName: "Alex Kim", confidence: .medium, shownNameSource: .callApp),
                "system_2": SpeakerMapping(speakerId: "2", identifiedName: "Alex Kim", confidence: .medium, shownNameSource: .callApp),
            ],
            speakerSources: ["system_1": "db_pending", "system_2": "db_pending"],
            speakerDbIds: ["system_1": profile1, "system_2": profile2],
            date: Date(timeIntervalSince1970: 1_775_000_000),
            formatOptions: TranscriptFormatOptions(audioSources: [.systemAudio])
        )
        let url = temporaryDirectory.appendingPathComponent("Call_2026-04-01_09-00-00.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[System/Alex Kim] two"), markdown)

        XCTAssertTrue(try TranscriptSaver.updateDeferredSpeakerNames(
            [TranscriptSaver.DeferredSpeakerNameUpdate(transcriptURL: url, dbId: profile1, diarizerSpeakerId: "1", channel: .system)],
            newName: "Alexandra Kim"
        ))

        let saved = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(saved.contains("[System/Alex Kim] two"), saved)
        XCTAssertFalse(saved.contains("[System/Alexandra Kim] two"), saved)
        let rows = TranscriptSaver.parseFrontmatterSpeakerRows(in: saved.components(separatedBy: "\n"))
        XCTAssertEqual(rows.first { $0.dbId == profile1 }?.name, "Alexandra Kim")
        XCTAssertEqual(rows.first { $0.dbId == profile2 }?.name, "Alex Kim")
    }

    func testSettingsRenameAndMergeDropNameSource() {
        var content = """
        ---
        speakers:
          - id: "1"
            channel: system
            db_id: "\(profile1.uuidString)"
            name: "Alex Kim"
            confidence: medium
            source: db_pending
            name_source: call_app
          - id: "2"
            channel: system
            db_id: "\(profile2.uuidString)"
            name: "Blair Ng"
            confidence: medium
            source: db_pending
            name_source: call_app
        ---

        [00:00] [System/Alex Kim] one
        [00:10] [System/Blair Ng] two
        """

        XCTAssertTrue(TranscriptSaver.applyRetroactiveRename(in: &content, dbId: profile1, newName: "Alexandra Kim", fileName: "x.md"))

        let rows = TranscriptSaver.parseFrontmatterSpeakerRows(in: content.components(separatedBy: "\n"))
        let renamed = rows.first { $0.dbId == profile1 }
        XCTAssertEqual(renamed?.name, "Alexandra Kim")
        XCTAssertNil(renamed?.nameSourceLineIndex, content)
        // The other person's row keeps its marker.
        XCTAssertNotNil(rows.first { $0.dbId == profile2 }?.nameSourceLineIndex, content)
        XCTAssertEqual(content.components(separatedBy: "name_source: call_app").count - 1, 1, content)
        XCTAssertTrue(content.contains("[System/Alexandra Kim] one"), content)
    }
}
