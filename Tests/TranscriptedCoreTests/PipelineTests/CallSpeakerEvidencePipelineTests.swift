import XCTest
@testable import TranscriptedCore

/// Promises for call-app speaker evidence after voiceprint classification:
/// - a call-app name never changes a speaker's label, name, confidence,
///   confirmation or `source:`; an unknown voice stays "Speaker N" and a
///   voiceprint guess or name stays exactly as the voiceprint left it;
/// - the saved frontmatter carries the call app's name next to the voice
///   (`call_app_name`), its strength, and how it compares with the
///   voiceprint (`agrees`, `conflicts`, `no_voiceprint_guess`);
/// - withheld reads are saved as a reason without a name;
/// - review rows carry the name only as a hint;
/// - deferring or naming in review keeps the evidence, and nothing in it
///   is ever a label;
/// - old files with `name_source: call_app` still parse and rename cleanly.
@available(macOS 14.0, *)
final class CallSpeakerEvidencePipelineTests: XCTestCase {
    private typealias Policy = CallSpeakerAttributionPolicy
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallSpeakerEvidencePipelineTests-\(UUID().uuidString)", isDirectory: true)
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

    /// Voice 1 talks 0–10 s, voice 2 talks 10–20 s.
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

    private func placeholders() -> [String: SpeakerMapping] {
        ["system_1": SpeakerMapping(speakerId: "1"), "system_2": SpeakerMapping(speakerId: "2")]
    }

    private func run(
        isImport: Bool = false,
        activity: CallSpeakerActivity,
        utterances: [TranscriptionUtterance],
        dbKnowledge: [TranscriptionTaskManager.SpeakerClassificationKnowledge] = [],
        profileNames: [UUID: String] = [:],
        mappings: [String: SpeakerMapping]
    ) -> (recorded: TranscriptionTaskManager.CallSpeakerEvidenceRecorded?, mappings: [String: SpeakerMapping]) {
        var mappings = mappings
        let resolved = TranscriptionTaskManager.callSpeakerEvidence(
            isImport: isImport,
            activity: activity,
            systemUtterances: utterances,
            dbKnowledge: dbKnowledge,
            profileName: { profileNames[$0] },
            speakerMappings: &mappings
        )
        return (resolved?.recorded, mappings)
    }

    // MARK: - Labels never change

    func testCallAppNameNeverLabelsAnUnknownVoice() {
        let result = run(activity: activity("Alex Kim", "Blair Ng"), utterances: utterances(), mappings: placeholders())

        for id in ["1", "2"] {
            let mapping = result.mappings["system_\(id)"]
            XCTAssertEqual(mapping?.displayName, "Speaker \(id)")
            XCTAssertNil(mapping?.identifiedName)
            XCTAssertNil(mapping?.confidence)
            XCTAssertEqual(mapping?.isConfirmedIdentity, false)
        }
        XCTAssertEqual(result.mappings["system_1"]?.callAppEvidence?.name, "Alex Kim")
        XCTAssertEqual(result.mappings["system_1"]?.callAppEvidence?.agreement, .noVoiceprintGuess)
        XCTAssertEqual(result.mappings["system_2"]?.callAppEvidence?.name, "Blair Ng")
        XCTAssertEqual(result.recorded?.hintNamesBySpeakerId, ["1": "Alex Kim", "2": "Blair Ng"])
    }

    func testConflictNeverDisplacesTheVoiceprintName() {
        var mappings = placeholders()
        mappings["system_1"] = SpeakerMapping(speakerId: "1", identifiedName: "Jordan Lee", confidence: .high, isConfirmedIdentity: true)
        let result = run(activity: activity("Alex Kim", "Blair Ng"), utterances: utterances(), mappings: mappings)

        let jordan = result.mappings["system_1"]
        XCTAssertEqual(jordan?.displayName, "Jordan Lee")
        XCTAssertEqual(jordan?.identifiedName, "Jordan Lee")
        XCTAssertEqual(jordan?.confidence, .high)
        XCTAssertEqual(jordan?.isConfirmedIdentity, true)
        XCTAssertEqual(jordan?.callAppEvidence?.name, "Alex Kim", "both answers are kept")
        XCTAssertEqual(jordan?.callAppEvidence?.agreement, .conflicts)
        XCTAssertEqual(result.recorded?.agreements[.conflicts], 1)
    }

    func testAgreementWithALikelyGuessIsRecordedButNeverPromotes() {
        var mappings = placeholders()
        mappings["system_1"] = SpeakerMapping(speakerId: "1", identifiedName: "Alex Kim (likely)", confidence: .medium)
        let result = run(activity: activity("alex  KIM", "Blair Ng"), utterances: utterances(), mappings: mappings)

        let alex = result.mappings["system_1"]
        XCTAssertEqual(alex?.displayName, "Alex Kim (likely)", "the hedge stays")
        XCTAssertEqual(alex?.confidence, .medium)
        XCTAssertEqual(alex?.isConfirmedIdentity, false, "agreement never confirms")
        XCTAssertEqual(alex?.callAppEvidence?.agreement, .agrees)
    }

    func testVoiceprintGuessFromKnowledgeOrProfileIsTheComparison() {
        // Voice 1's hidden voiceprint suggestion comes from classification
        // knowledge; voice 2's from its profile.
        let result = run(
            activity: activity("Alex Kim", "Blair Ng"),
            utterances: utterances(),
            dbKnowledge: [knowledge("1", name: "Jordan Lee")],
            profileNames: [profile2: "blair ng"],
            mappings: placeholders()
        )
        XCTAssertEqual(result.mappings["system_1"]?.callAppEvidence?.agreement, .conflicts)
        XCTAssertEqual(result.mappings["system_2"]?.callAppEvidence?.agreement, .agrees)
        XCTAssertEqual(result.mappings["system_1"]?.displayName, "Speaker 1")
        XCTAssertEqual(result.mappings["system_2"]?.displayName, "Speaker 2")
    }

    func testTwoVoicesMayCarryTheSameCallNameWithoutEitherBeingRenamed() {
        let result = run(activity: activity("Alex Kim", "alex kim"), utterances: utterances(), mappings: placeholders())
        XCTAssertNotNil(result.mappings["system_1"]?.callAppEvidence?.name)
        XCTAssertNotNil(result.mappings["system_2"]?.callAppEvidence?.name)
        XCTAssertEqual(result.mappings["system_1"]?.displayName, "Speaker 1")
        XCTAssertEqual(result.mappings["system_2"]?.displayName, "Speaker 2")
    }

    func testAVoiceWithoutASpeakerRowGetsNoRowJustForEvidence() {
        var mappings = placeholders()
        mappings["system_2"] = nil
        let result = run(activity: activity("Alex Kim", "Blair Ng"), utterances: utterances(voice2Profile: .some(nil)), mappings: mappings)
        XCTAssertNil(result.mappings["system_2"])
        XCTAssertEqual(result.recorded?.noSpeakerRow, 1)
    }

    func testImportsGetNoEvidence() {
        let result = run(isImport: true, activity: activity("Alex Kim", "Blair Ng"), utterances: utterances(), mappings: placeholders())
        XCTAssertNil(result.recorded)
        XCTAssertNil(result.mappings["system_1"]?.callAppEvidence)
    }

    func testWithheldReadsSaveTheReasonWithoutAName() {
        var mappings = placeholders()
        let recorded = TranscriptionTaskManager.recordCallSpeakerEvidence(
            Policy.Outcome(withheld: ["1": .namesDisagree, "2": .noEvidence]),
            voiceprintNames: [:],
            speakerMappings: &mappings
        )
        XCTAssertEqual(mappings["system_1"]?.callAppEvidence, CallAppSpeakerEvidence(withheld: .namesDisagree))
        XCTAssertNil(mappings["system_2"]?.callAppEvidence, "no evidence is nothing to say")
        XCTAssertEqual(recorded.withheldRecorded, 1)
        XCTAssertTrue(recorded.hintNamesBySpeakerId.isEmpty)
        XCTAssertEqual(mappings["system_1"]?.displayName, "Speaker 1")
    }

    func testPolicyReportsHowStrongTheEvidenceWas() {
        let outcome = Policy.attribute(
            activity: activity("Alex Kim", "Blair Ng"),
            clusters: TranscriptionTaskManager.callSpeakerClusters(from: utterances())
        )
        XCTAssertEqual(outcome.evidence["1"], Policy.Evidence(seconds: 10, share: 1, coverage: 1))
        XCTAssertEqual(Set(outcome.evidence.keys), Set(outcome.names.keys))
    }

    func testReviewRowsCarryTheNameOnlyAsAHint() {
        let clip = temporaryDirectory.appendingPathComponent("clip.wav")
        let system = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "1", channel: .system, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)
        let otherSystem = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "2", channel: .system, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)
        let mic = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "1", channel: .mic, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)

        let entries = TranscriptionTaskManager.withCallAppHints([system, otherSystem, mic], ["1": "Alex Kim"])

        XCTAssertEqual(entries.map(\.callAppShownName), ["Alex Kim", nil, nil])
        XCTAssertEqual(entries.map(\.currentName), [nil, nil, nil], "the hint is not a name")
        XCTAssertEqual(entries.map(\.needsNaming), [true, true, true])
    }

    // MARK: - Saved transcript

    func testSavedTranscriptKeepsLabelsAndCarriesTheEvidence() throws {
        var mappings = placeholders()
        mappings["system_2"] = SpeakerMapping(speakerId: "2", identifiedName: "Jordan Lee", confidence: .high, isConfirmedIdentity: true)
        let result = run(activity: activity("Alex Kim", "Blair Ng"), utterances: utterances(), mappings: mappings)
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: TranscriptionResult(micUtterances: [], systemUtterances: utterances(), duration: 20, processingTime: 1),
            transcriptId: UUID(),
            speakerMappings: result.mappings,
            speakerSources: ["system_1": "db_pending", "system_2": "db"],
            speakerDbIds: ["system_1": profile1, "system_2": profile2],
            date: Date(timeIntervalSince1970: 1_775_000_000),
            formatOptions: TranscriptFormatOptions(audioSources: [.systemAudio], includeObsidianMetadata: true)
        )

        XCTAssertTrue(markdown.contains("[System/Speaker 1] one"), markdown)
        XCTAssertTrue(markdown.contains("[System/[[Jordan Lee]]] two"), "the voiceprint name keeps its link: \(markdown)")
        XCTAssertFalse(markdown.contains("[System/Alex Kim]"), markdown)
        XCTAssertFalse(markdown.contains("[System/Blair Ng]"), markdown)
        XCTAssertFalse(markdown.contains("name_source"), markdown)
        XCTAssertFalse(markdown.contains("speaker/alex-kim"), markdown)
        XCTAssertFalse(markdown.contains("[[Alex Kim]]"), markdown)

        let unknown = speakerRow(id: "1", in: markdown)
        XCTAssertTrue(unknown.contains(#"name: "Speaker 1""#), unknown)
        XCTAssertTrue(unknown.contains("source: db_pending"), unknown)
        XCTAssertTrue(unknown.contains("confidence: unknown"), unknown)
        XCTAssertTrue(unknown.contains(#"call_app_name: "Alex Kim""#), unknown)
        XCTAssertTrue(unknown.contains("call_app_agreement: no_voiceprint_guess"), unknown)
        XCTAssertTrue(unknown.contains("call_app_seconds: 10.0"), unknown)
        XCTAssertTrue(unknown.contains("call_app_share: 1.00"), unknown)
        XCTAssertTrue(unknown.contains("call_app_coverage: 1.00"), unknown)

        let conflict = speakerRow(id: "2", in: markdown)
        XCTAssertTrue(conflict.contains(#"name: "Jordan Lee""#), conflict)
        XCTAssertTrue(conflict.contains("source: db"), conflict)
        XCTAssertTrue(conflict.contains(#"call_app_name: "Blair Ng""#), conflict)
        XCTAssertTrue(conflict.contains("call_app_agreement: conflicts"), conflict)
    }

    func testMicRowsNeverCarryCallAppEvidence() {
        let mapping = SpeakerMapping(speakerId: "1", callAppEvidence: .named("Alex Kim", strength: nil, voiceprintName: nil))
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: TranscriptionResult(
                micUtterances: [TranscriptionUtterance(start: 0, end: 2, channel: 0, speakerId: 1, persistentSpeakerId: nil, matchSimilarity: nil, transcript: "hi")],
                systemUtterances: [],
                duration: 2,
                processingTime: 1
            ),
            transcriptId: UUID(),
            speakerMappings: ["mic_1": mapping],
            speakerSources: ["mic_1": "db_pending"],
            date: Date(timeIntervalSince1970: 1_775_000_000)
        )
        XCTAssertFalse(markdown.contains("call_app_"), markdown)
    }

    func testDeferredReviewKeepsPlaceholderAndEvidence() throws {
        let url = try savedTranscript()
        let clip = temporaryDirectory.appendingPathComponent("clip.wav")
        var entry = SpeakerNamingEntry(id: profile1, diarizerSpeakerId: "1", channel: .system, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)
        entry.callAppShownName = "Alex Kim"

        XCTAssertTrue(TranscriptSaver.markSpeakerReviewDeferred(transcriptURL: url, entries: [entry], redirectedSpeakerIdsByKey: [:]))

        let markdown = try String(contentsOf: url, encoding: .utf8)
        let row = speakerRow(id: "1", in: markdown)
        XCTAssertTrue(row.contains(#"name: "Speaker 1""#), row)
        XCTAssertTrue(row.contains("source: db_pending"), row)
        XCTAssertTrue(row.contains(#"call_app_name: "Alex Kim""#), row)
        XCTAssertFalse(row.contains("name_source"), row)
        XCTAssertTrue(markdown.contains("[System/Speaker 1] one"), markdown)
    }

    func testNamingInReviewUsesTheTypedNameAndKeepsTheEvidence() throws {
        let url = try savedTranscript()

        XCTAssertTrue(TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: [SpeakerNameUpdate(persistentSpeakerId: profile1, diarizerSpeakerId: "1", newName: "Alexandra Kim", action: .named)],
            transcriptionResult: TranscriptionResult(micUtterances: [], systemUtterances: utterances(), duration: 20, processingTime: 1)
        ))

        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[System/Alexandra Kim] one"), markdown)
        let row = speakerRow(id: "1", in: markdown)
        XCTAssertTrue(row.contains(#"name: "Alexandra Kim""#), row)
        XCTAssertTrue(row.contains("source: user_manual"), row)
        XCTAssertTrue(row.contains(#"call_app_name: "Alex Kim""#), "the call app's read stays as history: \(row)")
    }

    // MARK: - Old files

    func testLegacyCallAppRowsStillRenameAndDropNameSource() {
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

        let before = TranscriptSaver.parseFrontmatterSpeakerRows(in: content.components(separatedBy: "\n"))
        XCTAssertEqual(before.count, 2)
        XCTAssertNotNil(before.first { $0.dbId == profile1 }?.nameSourceLineIndex)

        XCTAssertTrue(TranscriptSaver.applyRetroactiveRename(in: &content, dbId: profile1, newName: "Alexandra Kim", fileName: "x.md"))

        let rows = TranscriptSaver.parseFrontmatterSpeakerRows(in: content.components(separatedBy: "\n"))
        XCTAssertEqual(rows.first { $0.dbId == profile1 }?.name, "Alexandra Kim")
        XCTAssertNil(rows.first { $0.dbId == profile1 }?.nameSourceLineIndex, content)
        XCTAssertNotNil(rows.first { $0.dbId == profile2 }?.nameSourceLineIndex, content)
        XCTAssertTrue(content.contains("[System/Alexandra Kim] one"), content)
        XCTAssertTrue(content.contains("[System/Blair Ng] two"), content)
    }

    func testLegacyRowsSharingANameRenameOnlyTheNamedVoice() throws {
        let markdown = """
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
            name: "Alex Kim"
            confidence: medium
            source: db_pending
            name_source: call_app
        ---

        [00:00] [System/Alex Kim] one
        [00:10] [System/Alex Kim] two
        """
        let url = temporaryDirectory.appendingPathComponent("Call_2026-04-01_09-00-00.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)

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

    // MARK: - Helpers

    /// A transcript saved the way the pipeline saves one now: voice 1 an
    /// unknown placeholder in review with call-app evidence.
    private func savedTranscript() throws -> URL {
        let result = run(activity: activity("Alex Kim", "Blair Ng"), utterances: utterances(), mappings: placeholders())
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: TranscriptionResult(micUtterances: [], systemUtterances: utterances(), duration: 20, processingTime: 1),
            transcriptId: UUID(),
            speakerMappings: result.mappings,
            speakerSources: ["system_1": "db_pending", "system_2": "db_pending"],
            speakerDbIds: ["system_1": profile1, "system_2": profile2],
            date: Date(timeIntervalSince1970: 1_775_000_000),
            formatOptions: TranscriptFormatOptions(audioSources: [.systemAudio])
        )
        let url = temporaryDirectory.appendingPathComponent("Call_2026-04-01_09-00-00.md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The frontmatter `speakers:` row for a system voice, as text.
    private func speakerRow(id: String, in markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        guard let start = lines.firstIndex(of: #"  - id: "\#(id)""#) else { return "" }
        var row = [lines[start]]
        for line in lines[(start + 1)...] {
            if line.hasPrefix("  - ") || !line.hasPrefix("    ") { break }
            row.append(line)
        }
        return row.joined(separator: "\n")
    }
}
