import XCTest
@testable import TranscriptedCore

/// Promises for call-app speaker names after voiceprint classification:
/// - a voiceprint auto-accepted name always wins;
/// - a voice whose voiceprint suggests someone else keeps today's placeholder;
/// - an applied name shows in the body but the speaker stays in review
///   (`source: db_pending`, `name_source: call_app`), and only on voices that
///   get a review row;
/// - review rows carry the name as a prefill;
/// - deferring the review keeps the name; naming the voice replaces it in the
///   body and drops `name_source`.
@available(macOS 14.0, *)
final class CallSpeakerNamesPipelineTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CallSpeakerNamesPipelineTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        temporaryDirectory = nil
    }

    private func outcome(_ names: [String: String]) -> CallSpeakerAttributionPolicy.Outcome {
        CallSpeakerAttributionPolicy.Outcome(names: names)
    }

    // MARK: - Applying names

    func testAutoAcceptedVoiceprintNameWins() {
        var mappings = ["system_1": SpeakerMapping(speakerId: "1", identifiedName: "Jordan Lee", confidence: .high, isConfirmedIdentity: true)]
        var sources = ["system_1": "db"]

        let applied = TranscriptionTaskManager.applyCallSpeakerNames(
            outcome(["1": "Alex Kim"]),
            autoAcceptedIds: ["1"],
            reviewIds: [],
            voiceprintNames: [:],
            speakerMappings: &mappings,
            speakerSources: &sources
        )

        XCTAssertEqual(mappings["system_1"]?.displayName, "Jordan Lee")
        XCTAssertNil(mappings["system_1"]?.shownNameSource)
        XCTAssertEqual(sources["system_1"], "db")
        XCTAssertTrue(applied.namesBySpeakerId.isEmpty)
        XCTAssertEqual(applied.autoAcceptedSkipped, 1)
    }

    func testConflictingVoiceprintSuggestionWithholdsTheCallName() {
        var mappings = ["system_1": SpeakerMapping(speakerId: "1")]
        var sources = ["system_1": "db_pending"]

        let applied = TranscriptionTaskManager.applyCallSpeakerNames(
            outcome(["1": "Alex Kim"]),
            autoAcceptedIds: [],
            reviewIds: ["1"],
            voiceprintNames: ["1": "Jordan Lee"],
            speakerMappings: &mappings,
            speakerSources: &sources
        )

        XCTAssertEqual(mappings["system_1"]?.displayName, "Speaker 1")
        XCTAssertNil(mappings["system_1"]?.shownNameSource)
        XCTAssertTrue(applied.namesBySpeakerId.isEmpty)
        XCTAssertEqual(applied.voiceprintConflicts, 1)
    }

    func testAgreeingVoiceprintSuggestionKeepsTheCallName() {
        var mappings = ["system_1": SpeakerMapping(speakerId: "1")]
        var sources = ["system_1": "db_pending"]

        let applied = TranscriptionTaskManager.applyCallSpeakerNames(
            outcome(["1": "Alex Kim"]),
            autoAcceptedIds: [],
            reviewIds: ["1"],
            voiceprintNames: ["1": " alex  KIM "],
            speakerMappings: &mappings,
            speakerSources: &sources
        )

        XCTAssertEqual(mappings["system_1"]?.displayName, "Alex Kim")
        XCTAssertEqual(applied.namesBySpeakerId, ["1": "Alex Kim"])
    }

    // MARK: - Saved transcript

    func testSavedTranscriptShowsTheNameButKeepsItInReview() {
        let profileId = UUID()
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 0, end: 4, channel: 1, speakerId: 1, persistentSpeakerId: profileId, matchSimilarity: nil, transcript: "hello from alex"),
                TranscriptionUtterance(start: 5, end: 9, channel: 1, speakerId: 2, persistentSpeakerId: nil, matchSimilarity: nil, transcript: "hello from blair"),
            ],
            duration: 10,
            processingTime: 1
        )
        var mappings = ["system_1": SpeakerMapping(speakerId: "1")]
        var sources = ["system_1": "db_pending"]
        _ = TranscriptionTaskManager.applyCallSpeakerNames(
            outcome(["1": "Alex Kim", "2": "Blair Ng"]),
            autoAcceptedIds: [],
            reviewIds: ["1"],
            voiceprintNames: [:],
            speakerMappings: &mappings,
            speakerSources: &sources
        )

        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(),
            speakerMappings: mappings,
            speakerSources: sources,
            speakerDbIds: ["system_1": profileId],
            date: Date(timeIntervalSince1970: 1_775_000_000),
            formatOptions: TranscriptFormatOptions(audioSources: [.systemAudio], includeObsidianMetadata: true)
        )

        XCTAssertTrue(markdown.contains("[System/Alex Kim] hello from alex"), markdown)
        // Voice 2 has no voiceprint profile, so no review row: no call name.
        XCTAssertTrue(markdown.contains("[System/Speaker 2] hello from blair"), markdown)
        XCTAssertTrue(markdown.contains("- **Alex Kim:**"), markdown)
        let alexRow = speakerRow(id: "1", in: markdown)
        XCTAssertTrue(alexRow.contains(#"name: "Alex Kim""#), alexRow)
        XCTAssertTrue(alexRow.contains("source: db_pending"), alexRow)
        XCTAssertTrue(alexRow.contains("name_source: call_app"), alexRow)
        XCTAssertTrue(alexRow.contains("confidence: medium"), alexRow)
        XCTAssertTrue(alexRow.contains(profileId.uuidString), alexRow)
        let blairRow = speakerRow(id: "2", in: markdown)
        XCTAssertFalse(blairRow.contains("Blair Ng"), blairRow)
        XCTAssertFalse(blairRow.contains("name_source"), blairRow)
        // Unconfirmed: never a wiki link or a speaker tag.
        XCTAssertFalse(markdown.contains("[[Alex Kim]]"), markdown)
        XCTAssertFalse(markdown.contains("speaker/alex-kim"), markdown)
    }

    func testVoiceprintNamesWriteNoNameSource() {
        let result = TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 0, end: 4, channel: 1, speakerId: 1, persistentSpeakerId: nil, matchSimilarity: nil, transcript: "hi"),
            ],
            duration: 4,
            processingTime: 1
        )
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: UUID(),
            speakerMappings: ["system_1": SpeakerMapping(speakerId: "1", identifiedName: "Jordan Lee", confidence: .high, isConfirmedIdentity: true)],
            speakerSources: ["system_1": "db"],
            date: Date(timeIntervalSince1970: 1_775_000_000)
        )
        XCTAssertFalse(markdown.contains("name_source"), markdown)
    }

    func testReviewRowsCarryTheCallNameAsPrefill() {
        let clip = temporaryDirectory.appendingPathComponent("clip.wav")
        let system = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "1", channel: .system, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)
        let otherSystem = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "2", channel: .system, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)
        let mic = SpeakerNamingEntry(id: UUID(), diarizerSpeakerId: "1", channel: .mic, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)

        let entries = TranscriptionTaskManager.withCallAppSuggestedNames([system, otherSystem, mic], ["1": "Alex Kim"])

        XCTAssertEqual(entries.map(\.callAppSuggestedName), ["Alex Kim", nil, nil])
    }

    // MARK: - Review outcomes on the saved file

    func testDeferredReviewKeepsTheCallName() throws {
        let alexId = UUID()
        let otherId = UUID()
        let url = try savedCallNamedTranscript(alexId: alexId, otherId: otherId)
        let clip = temporaryDirectory.appendingPathComponent("clip.wav")
        var alexEntry = SpeakerNamingEntry(id: alexId, diarizerSpeakerId: "1", channel: .system, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)
        alexEntry.callAppSuggestedName = "Alex Kim"
        let otherEntry = SpeakerNamingEntry(id: otherId, diarizerSpeakerId: "2", channel: .system, clipURL: clip, sampleText: "", currentName: nil, matchSimilarity: nil, needsNaming: true, needsConfirmation: false)

        XCTAssertTrue(TranscriptSaver.markSpeakerReviewDeferred(
            transcriptURL: url,
            entries: [alexEntry, otherEntry],
            redirectedSpeakerIdsByKey: [:]
        ))

        let markdown = try String(contentsOf: url, encoding: .utf8)
        let alexRow = speakerRow(id: "1", in: markdown)
        XCTAssertTrue(alexRow.contains(#"name: "Alex Kim""#), alexRow)
        XCTAssertTrue(alexRow.contains("source: db_pending"), alexRow)
        XCTAssertTrue(alexRow.contains("name_source: call_app"), alexRow)
        XCTAssertEqual(alexRow.components(separatedBy: "name_source:").count - 1, 1, alexRow)
        let otherRow = speakerRow(id: "2", in: markdown)
        XCTAssertTrue(otherRow.contains(#"name: "Speaker 2""#), otherRow)
        XCTAssertFalse(otherRow.contains("name_source"), otherRow)
        XCTAssertTrue(markdown.contains("[System/Alex Kim] hello from alex"), markdown)
    }

    func testNamingInReviewReplacesTheCallNameAndDropsNameSource() throws {
        let alexId = UUID()
        let url = try savedCallNamedTranscript(alexId: alexId, otherId: UUID())

        XCTAssertTrue(TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: [SpeakerNameUpdate(persistentSpeakerId: alexId, diarizerSpeakerId: "1", newName: "Alexandra Kim", action: .named)],
            transcriptionResult: callResult(alexId: alexId, otherId: nil)
        ))

        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[System/Alexandra Kim] hello from alex"), markdown)
        XCTAssertFalse(markdown.contains("[System/Alex Kim]"), markdown)
        let alexRow = speakerRow(id: "1", in: markdown)
        XCTAssertTrue(alexRow.contains(#"name: "Alexandra Kim""#), alexRow)
        XCTAssertTrue(alexRow.contains("source: user_manual"), alexRow)
        XCTAssertFalse(alexRow.contains("name_source"), alexRow)
    }

    func testNamingFromSettingsReplacesTheCallNameAndDropsNameSource() throws {
        let alexId = UUID()
        let url = try savedCallNamedTranscript(alexId: alexId, otherId: UUID())

        XCTAssertTrue(try TranscriptSaver.updateDeferredSpeakerNames(
            [TranscriptSaver.DeferredSpeakerNameUpdate(transcriptURL: url, dbId: alexId, diarizerSpeakerId: "1", channel: .system)],
            newName: "Alexandra Kim"
        ))

        let markdown = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(markdown.contains("[System/Alexandra Kim] hello from alex"), markdown)
        let alexRow = speakerRow(id: "1", in: markdown)
        XCTAssertTrue(alexRow.contains(#"name: "Alexandra Kim""#), alexRow)
        XCTAssertTrue(alexRow.contains("source: user_manual"), alexRow)
        XCTAssertFalse(alexRow.contains("name_source"), alexRow)
    }

    // MARK: - Fixtures

    private func callResult(alexId: UUID, otherId: UUID?) -> TranscriptionResult {
        TranscriptionResult(
            micUtterances: [],
            systemUtterances: [
                TranscriptionUtterance(start: 0, end: 4, channel: 1, speakerId: 1, persistentSpeakerId: alexId, matchSimilarity: nil, transcript: "hello from alex"),
                TranscriptionUtterance(start: 5, end: 9, channel: 1, speakerId: 2, persistentSpeakerId: otherId, matchSimilarity: nil, transcript: "hello from someone"),
            ],
            duration: 10,
            processingTime: 1
        )
    }

    /// A transcript saved the way the pipeline saves one: voice 1 shown under
    /// its call-app name, voice 2 a plain placeholder in review.
    private func savedCallNamedTranscript(alexId: UUID, otherId: UUID) throws -> URL {
        var mappings = ["system_1": SpeakerMapping(speakerId: "1"), "system_2": SpeakerMapping(speakerId: "2")]
        var sources = ["system_1": "db_pending", "system_2": "db_pending"]
        _ = TranscriptionTaskManager.applyCallSpeakerNames(
            outcome(["1": "Alex Kim"]),
            autoAcceptedIds: [],
            reviewIds: ["1"],
            voiceprintNames: [:],
            speakerMappings: &mappings,
            speakerSources: &sources
        )
        let markdown = TranscriptSaver.formatTranscriptMarkdown(
            result: callResult(alexId: alexId, otherId: otherId),
            transcriptId: UUID(),
            speakerMappings: mappings,
            speakerSources: sources,
            speakerDbIds: ["system_1": alexId, "system_2": otherId],
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
