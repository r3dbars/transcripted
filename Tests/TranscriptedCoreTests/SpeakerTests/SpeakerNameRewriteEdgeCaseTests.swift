import Foundation
import XCTest
@testable import TranscriptedCore

/// Edge cases behind "Failed to finalize speaker names" (APPLE-MACOS-1R) in
/// `TranscriptSaver.updateSpeakerNames`. Each used to either fail the whole
/// save or put a wrong label on a row.
///
/// Fixtures are real writer output, not hand-typed Markdown: the raw form comes
/// from `TranscriptFormatter`, and the styled form from a local mirror of the
/// app-side `MeetingTranscriptStyler` (Sources/Meeting, not linkable from this
/// package). A save can land on either form, since the restyle runs async.
@available(macOS 14.0, *)
final class SpeakerNameRewriteEdgeCaseTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerNameRewriteEdgeCaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - Edge cases

    /// A label with `]` makes the styler end the label early and push the rest
    /// into the text, so a whitespace-only utterance still gets a styled row
    /// (text `]`). The old count check then failed, and so did the fallback,
    /// because the styled header no longer carries the full label.
    func testBracketLabelWithWhitespaceOnlyUtteranceRenamesEveryRow() throws {
        let fixture = Fixture(
            utterances: [
                utterance(1, .system, 1, "Can everyone hear me?"),
                utterance(4, .system, 1, "   "),
                utterance(7, .system, 2, "Yes, loud and clear."),
            ],
            speakers: [
                speaker(.system, 1, confirmedName: "Pat [PM]"),
                speaker(.system, 2),
            ]
        )
        let names = ["system_1": "Pat Morgan", "system_2": "Jamie"]

        try assertStyledRewrite(fixture, names: names, expectedStyledRows: 3)
        try assertRawRewrite(fixture, names: names)
    }

    /// The raw parser ends a label at the first "] ", so renaming a speaker
    /// whose old name contains "] " used to move the name's tail into the text
    /// ("[System/Sarah] Smith] hello").
    func testOldLabelContainingBracketSpaceKeepsRowTextIntact() throws {
        let fixture = Fixture(
            utterances: [
                utterance(1, .system, 1, "Hello there."),
                utterance(5, .system, 2, "Hi Bob."),
                utterance(9, .system, 1, "Shall we start?"),
            ],
            speakers: [
                speaker(.system, 1, confirmedName: "Bob [Sales] Smith"),
                speaker(.system, 2),
            ]
        )
        let names = ["system_1": "Sarah", "system_2": "Jamie"]

        let updated = try assertRawRewrite(fixture, names: names)
        XCTAssertFalse(updated.contains("Smith] Hello"), updated)
        try assertStyledRewrite(fixture, names: names, expectedStyledRows: 3)
    }

    /// The styler strips `**` from an entry's first line, so an utterance whose
    /// text is just `**` renders as empty and is dropped. The old styled pass
    /// required one row per visible utterance and failed.
    func testStarOnlyUtteranceDroppedByStylerDoesNotFailTheSave() throws {
        let fixture = Fixture(
            utterances: [
                utterance(1, .system, 1, "Morning."),
                utterance(4, .system, 1, "**"),
                utterance(7, .system, 2, "Hi."),
                utterance(10, .mic, 0, "Let's start."),
            ],
            speakers: [
                speaker(.system, 1),
                speaker(.system, 2),
            ]
        )
        let names = ["system_1": "Ana", "system_2": "Ben"]

        try assertStyledRewrite(fixture, names: names, expectedStyledRows: 3)
        try assertRawRewrite(fixture, names: names)
    }

    /// Interior newlines are folded into one styled line, a text that starts
    /// with a blank line loses its styled row entirely, and `\r`, U+2028, and
    /// U+2029 are not row separators for either writer. None of them may fail
    /// the save or shift a label onto a neighboring row.
    func testLineBreaksInsideUtteranceTextDoNotShiftRows() throws {
        let fixture = Fixture(
            utterances: [
                utterance(1, .system, 1, "first line\nsecond line"),
                utterance(4, .system, 2, "one\rtwo"),
                utterance(7, .system, 1, "left\u{2028}right"),
                utterance(10, .system, 2, "para\u{2029}graph"),
                utterance(13, .system, 1, "\n\nstarted after a blank line"),
                utterance(16, .system, 2, "ends here"),
            ],
            speakers: [
                speaker(.system, 1),
                speaker(.system, 2),
            ]
        )
        let names = ["system_1": "Ana", "system_2": "Ben"]

        try assertStyledRewrite(fixture, names: names, expectedStyledRows: 5)
        try assertRawRewrite(fixture, names: names)
    }

    /// Speakers who are not part of this update keep the name the frontmatter
    /// has for them in the regenerated breakdown. That name used to be read
    /// without YAML unescaping, so `"` and `\` came back as `\"` and `\\`.
    func testBreakdownKeepsEscapedNamesOfSpeakersNotBeingRenamed() throws {
        let fixture = quotedNameFixture()
        let names = ["system_3": "Sarah"]

        let updated = try assertRawRewrite(fixture, names: names)
        XCTAssertTrue(updated.contains(#"- **Dwayne "The Rock" Johnson:** 1 utterances"#), updated)
        XCTAssertTrue(updated.contains(#"- **R\D Team:** 1 utterances"#), updated)
        XCTAssertTrue(updated.contains("- **Sarah:** 1 utterances"), updated)
        XCTAssertFalse(updated.contains(#"\"The Rock\" Johnson:**"#), updated)
        XCTAssertFalse(updated.contains(#"R\\D Team:**"#), updated)
    }

    /// The scoped fallback (used when the full rewrite cannot line rows up with
    /// the result) searches for the old label by name. With an escaped name it
    /// searched for a label that is not in the body and failed the save.
    func testScopedFallbackFindsLabelOfEscapedName() throws {
        let fixture = quotedNameFixture()
        let drifted = quotedNameFixture(offset: 30)
        let url = try write(rawTranscript(fixture), named: "quoted-fallback.md")

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: updates(["system_1": "Dwayne Johnson"], fixture: fixture),
            transcriptionResult: drifted.result
        )

        XCTAssertTrue(didUpdate)
        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("[00:01] [System/Dwayne Johnson] Welcome, everyone.\n"), updated)
        XCTAssertFalse(updated.contains(#"[System/Dwayne "The Rock" Johnson]"#), updated)
        XCTAssertTrue(updated.contains(#"[00:04] [System/R\D Team] Thanks for having us.\n"#), updated)
        XCTAssertEqual(
            TranscriptSaver.currentSpeakerName(in: updated, diarizerSpeakerId: "1", channel: .system),
            "Dwayne Johnson"
        )
        XCTAssertEqual(
            TranscriptSaver.currentSpeakerName(in: updated, diarizerSpeakerId: "2", channel: .system),
            #"R\D Team"#
        )
    }

    /// A mic speaker without a mapping is written as `[Mic/You]` with no
    /// frontmatter row. The full rewrite still relabels exactly that speaker's
    /// rows, and the same diarizer id on the system channel is left alone.
    func testMicRowWithoutFrontmatterEntryIsRelabeled() throws {
        let fixture = micWithoutEntryFixture()
        let names = ["mic_0": "Alex", "mic_1": "Jordan"]

        let updated = try assertRawRewrite(fixture, names: names)
        XCTAssertTrue(updated.contains("- **Alex:** 1 utterances"), updated)
        XCTAssertTrue(updated.contains("- **Jordan:** 1 utterances"), updated)
        XCTAssertEqual(
            TranscriptSaver.currentSpeakerName(in: updated, diarizerSpeakerId: "1", channel: .system),
            "Speaker 1"
        )
        try assertStyledRewrite(fixture, names: names, expectedStyledRows: 3)
    }

    /// When the full rewrite cannot run, the fallback has no old name for the
    /// entry-less mic speaker (its label is "You", not "Speaker 0"). It must
    /// refuse and leave the file untouched rather than guess.
    func testMicRowWithoutFrontmatterEntryFailsClosedInScopedFallback() throws {
        let fixture = micWithoutEntryFixture()
        let drifted = micWithoutEntryFixture(offset: 30)
        let original = rawTranscript(fixture)
        let url = try write(original, named: "mic-without-entry-fallback.md")

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: updates(["mic_0": "Alex", "mic_1": "Jordan"], fixture: fixture),
            transcriptionResult: drifted.result
        )

        XCTAssertFalse(didUpdate)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
    }

    /// Two rows the styler kept can only be told apart by text when they share
    /// a second and a source. If one of them could be the dropped `**` row, the
    /// rewrite must not guess which speaker the remaining row belongs to.
    func testAmbiguousStyledRowFailsClosedInsteadOfGuessing() throws {
        let fixture = Fixture(
            utterances: [
                utterance(1.2, .system, 1, "Right."),
                utterance(1.7, .system, 2, "**"),
                utterance(5, .system, 2, "Next item."),
            ],
            speakers: [
                speaker(.system, 1),
                speaker(.system, 2),
            ]
        )
        let styled = try restyled(rawTranscript(fixture))
        XCTAssertEqual(try styledRows(in: styled).count, 2)
        let url = try write(styled, named: "ambiguous-styled.md")

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: updates(["system_1": "Ana", "system_2": "Ben"], fixture: fixture),
            transcriptionResult: fixture.result
        )

        XCTAssertFalse(didUpdate)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), styled)
    }

    // MARK: - End to end

    /// Formatter -> (optional restyle) -> review Save, for a meeting with local
    /// and remote speakers, a suggested name being corrected, and diarizer ids
    /// shared across channels. Every row must carry its speaker's new name.
    func testFormatterOutputRoundTripsThroughRewriteInBothForms() throws {
        let fixture = Fixture(
            utterances: [
                utterance(0, .mic, 0, "Thanks for making time today."),
                utterance(3, .system, 0, "Happy to help."),
                utterance(3.5, .mic, 1, "I'll take notes."),
                utterance(8, .system, 1, "Can we start with the roadmap?"),
                utterance(14, .system, 2, "Sure, I have the numbers."),
                utterance(21, .mic, 0, "Great, go ahead."),
                utterance(27, .system, 0, "Q3 looks tight."),
                utterance(33, .system, 2, "Agreed, we should cut scope."),
                utterance(61, .mic, 1, "Noted."),
                utterance(65, .system, 1, "Let's sync next week."),
            ],
            speakers: [
                speaker(.mic, 0),
                speaker(.mic, 1),
                speaker(.system, 0, confirmedName: "Matt"),
                speaker(.system, 1),
                speaker(.system, 2),
            ]
        )
        let names = [
            "mic_0": "Justin",
            "mic_1": "Priya",
            "system_0": "Matthew",
            "system_1": "Sarah",
            "system_2": "Lee",
        ]

        let raw = try assertRawRewrite(fixture, names: names)
        XCTAssertTrue(raw.contains("- **Justin:** 2 utterances"), raw)
        XCTAssertTrue(raw.contains("- **Priya:** 2 utterances"), raw)
        XCTAssertTrue(raw.contains("- **Matthew:** 2 utterances"), raw)
        XCTAssertTrue(raw.contains("- **Sarah:** 2 utterances"), raw)
        XCTAssertTrue(raw.contains("- **Lee:** 2 utterances"), raw)
        XCTAssertFalse(raw.contains("/Speaker "), raw)
        XCTAssertFalse(raw.contains("- **Speaker "), raw)
        XCTAssertFalse(raw.contains(#"name: "Speaker "#), raw)
        XCTAssertFalse(raw.contains("[System/Matt]"), raw)

        try assertStyledRewrite(fixture, names: names, expectedStyledRows: 10)
    }

    // MARK: - Fixtures

    private struct Fixture {
        let result: TranscriptionResult
        let mappings: [String: SpeakerMapping]
        let dbIds: [String: UUID]

        init(
            utterances: [TranscriptionUtterance],
            speakers: [(key: String, mapping: SpeakerMapping, dbId: UUID)]
        ) {
            result = TranscriptionResult(
                micUtterances: utterances.filter { $0.channel == 0 },
                systemUtterances: utterances.filter { $0.channel == 1 },
                duration: 90,
                processingTime: 3
            )
            mappings = Dictionary(uniqueKeysWithValues: speakers.map { ($0.key, $0.mapping) })
            dbIds = Dictionary(uniqueKeysWithValues: speakers.map { ($0.key, $0.dbId) })
        }
    }

    private func utterance(
        _ start: Double,
        _ channel: UtteranceChannel,
        _ speakerId: Int,
        _ text: String
    ) -> TranscriptionUtterance {
        TranscriptionUtterance(
            start: start,
            end: start + 2,
            channel: channel == .mic ? 0 : 1,
            speakerId: speakerId,
            persistentSpeakerId: nil,
            matchSimilarity: nil,
            transcript: text
        )
    }

    /// A frontmatter speaker row: a generic placeholder ("Speaker N") unless a
    /// confirmed name is given. Each gets a stable fake db id so the review
    /// update can point at it.
    private func speaker(
        _ channel: UtteranceChannel,
        _ speakerId: Int,
        confirmedName: String? = nil
    ) -> (key: String, mapping: SpeakerMapping, dbId: UUID) {
        let mapping = SpeakerMapping(
            speakerId: String(speakerId),
            identifiedName: confirmedName,
            confidence: confirmedName == nil ? nil : .high,
            isConfirmedIdentity: confirmedName != nil
        )
        return (channel.speakerKey(diarizerSpeakerId: String(speakerId)), mapping, UUID())
    }

    private func quotedNameFixture(offset: Double = 0) -> Fixture {
        Fixture(
            utterances: [
                utterance(1 + offset, .system, 1, "Welcome, everyone."),
                utterance(4 + offset, .system, 2, "Thanks for having us."),
                utterance(8 + offset, .system, 3, "Glad to be here."),
            ],
            speakers: [
                speaker(.system, 1, confirmedName: #"Dwayne "The Rock" Johnson"#),
                speaker(.system, 2, confirmedName: #"R\D Team"#),
                speaker(.system, 3),
            ]
        )
    }

    /// Two local speakers from the room mic: mic_0 has no mapping (so no
    /// frontmatter row and a `You` label), mic_1 has a placeholder row. A
    /// remote speaker reuses diarizer id 1 on the system channel.
    private func micWithoutEntryFixture(offset: Double = 0) -> Fixture {
        Fixture(
            utterances: [
                utterance(1 + offset, .mic, 0, "I can take this one."),
                utterance(4 + offset, .mic, 1, "Me too."),
                utterance(8 + offset, .system, 1, "Great, thanks both."),
            ],
            speakers: [
                speaker(.mic, 1),
                speaker(.system, 1),
            ]
        )
    }

    private func rawTranscript(_ fixture: Fixture) -> String {
        TranscriptSaver.formatTranscriptMarkdown(
            result: fixture.result,
            transcriptId: UUID(),
            speakerMappings: fixture.mappings,
            speakerSources: fixture.mappings.mapValues { _ in "db_pending" },
            speakerDbIds: fixture.dbIds,
            date: Date(timeIntervalSince1970: 1_775_833_283)
        )
    }

    private func updates(_ names: [String: String], fixture: Fixture) -> [SpeakerNameUpdate] {
        names.keys.sorted().map { key -> SpeakerNameUpdate in
            let parts = key.split(separator: "_", maxSplits: 1).map(String.init)
            return SpeakerNameUpdate(
                persistentSpeakerId: fixture.dbIds[key] ?? UUID(),
                diarizerSpeakerId: parts[1],
                channel: parts[0] == "mic" ? .mic : .system,
                newName: names[key] ?? "",
                previousName: fixture.mappings[key]?.displayName,
                action: .named
            )
        }
    }

    private func write(_ markdown: String, named name: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent(name)
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Assertions

    /// Save names on the raw (just-formatted) transcript and check every row
    /// line is exactly `[ts] [Source/<expected>] <original text>`.
    @discardableResult
    private func assertRawRewrite(
        _ fixture: Fixture,
        names: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let url = try write(rawTranscript(fixture), named: "raw-\(UUID().uuidString).md")

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: updates(names, fixture: fixture),
            transcriptionResult: fixture.result
        )
        XCTAssertTrue(didUpdate, "raw rewrite failed", file: file, line: line)

        let updated = try String(contentsOf: url, encoding: .utf8)
        for utterance in fixture.result.allUtterances {
            let key = speakerKey(of: utterance)
            let label = names[key] ?? originalLabel(of: utterance, fixture: fixture)
            let row = "[\(timestamp(utterance.start))] [\(source(of: utterance))/\(label)] \(utterance.transcript)\n\n"
            XCTAssertTrue(
                updated.contains(row),
                "missing row \(row.debugDescription)\n\(updated)",
                file: file,
                line: line
            )
        }
        assertFrontmatterNames(names, in: updated, fixture: fixture, file: file, line: line)
        return updated
    }

    /// Save names on the restyled transcript and check that every styled row
    /// kept its timestamp, source, and text, and carries its speaker's new name.
    @discardableResult
    private func assertStyledRewrite(
        _ fixture: Fixture,
        names: [String: String],
        expectedStyledRows: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> String {
        let styled = try restyled(rawTranscript(fixture))
        let before = try styledRows(in: styled)
        XCTAssertEqual(before.count, expectedStyledRows, styled, file: file, line: line)
        let url = try write(styled, named: "styled-\(UUID().uuidString).md")

        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: updates(names, fixture: fixture),
            transcriptionResult: fixture.result
        )
        XCTAssertTrue(didUpdate, "styled rewrite failed\n\(styled)", file: file, line: line)

        let updated = try String(contentsOf: url, encoding: .utf8)
        let after = try styledRows(in: updated)
        XCTAssertEqual(after.count, before.count, updated, file: file, line: line)
        for (old, new) in zip(before, after) {
            let key = try XCTUnwrap(
                speakerKey(ofStyledRow: old, in: fixture.result),
                "no unique utterance for \(old)",
                file: file,
                line: line
            )
            XCTAssertEqual(new.timestamp, old.timestamp, file: file, line: line)
            XCTAssertEqual(new.source, old.source, file: file, line: line)
            XCTAssertEqual(new.text, old.text, file: file, line: line)
            XCTAssertEqual(new.label, names[key] ?? old.label, updated, file: file, line: line)
        }
        assertFrontmatterNames(names, in: updated, fixture: fixture, file: file, line: line)
        return updated
    }

    private func assertFrontmatterNames(
        _ names: [String: String],
        in markdown: String,
        fixture: Fixture,
        file: StaticString,
        line: UInt
    ) {
        for (key, name) in names where fixture.mappings[key] != nil {
            let parts = key.split(separator: "_", maxSplits: 1).map(String.init)
            XCTAssertEqual(
                TranscriptSaver.currentSpeakerName(
                    in: markdown,
                    diarizerSpeakerId: parts[1],
                    channel: parts[0] == "mic" ? .mic : .system
                ),
                name,
                "frontmatter name for \(key)",
                file: file,
                line: line
            )
        }
    }

    private func speakerKey(of utterance: TranscriptionUtterance) -> String {
        let channel: UtteranceChannel = utterance.channel == 0 ? .mic : .system
        return channel.speakerKey(diarizerSpeakerId: String(utterance.speakerId))
    }

    private func speakerKey(ofStyledRow row: StyledRow, in result: TranscriptionResult) -> String? {
        let matches = result.allUtterances.filter {
            timestamp($0.start) == row.timestamp && source(of: $0) == row.source
        }
        guard matches.count == 1 else { return nil }
        return speakerKey(of: matches[0])
    }

    /// The label `TranscriptFormatter` writes for an utterance.
    private func originalLabel(of utterance: TranscriptionUtterance, fixture: Fixture) -> String {
        if let mapping = fixture.mappings[speakerKey(of: utterance)] {
            return mapping.displayName
        }
        return utterance.channel == 0 ? "You" : "Speaker \(utterance.speakerId)"
    }

    private func timestamp(_ seconds: Double) -> String {
        String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }

    private func source(of utterance: TranscriptionUtterance) -> String {
        utterance.channel == 0 ? "Mic" : "System"
    }

    // MARK: - Styled form

    private struct StyledRow: CustomStringConvertible {
        let timestamp: String
        let source: String
        let label: String
        let text: String

        var description: String { "\(timestamp) \(source)/\(label)" }
    }

    private static let styledRowHeaderRegex = try! NSRegularExpression(
        pattern: #"^\*\*([0-9:]+)\*\*  \[(Mic|System)/(.*)\]$"#
    )

    private func styledRows(in markdown: String) throws -> [StyledRow] {
        let start = try XCTUnwrap(markdown.range(of: "## Transcript\n\n"))
        var rows: [StyledRow] = []
        for chunk in markdown[start.upperBound...].components(separatedBy: "\n\n") {
            let lines = chunk.components(separatedBy: "\n")
            guard let header = lines.first else { continue }
            let nsHeader = header as NSString
            guard let match = Self.styledRowHeaderRegex.firstMatch(
                in: header,
                range: NSRange(location: 0, length: nsHeader.length)
            ) else { continue }
            rows.append(StyledRow(
                timestamp: nsHeader.substring(with: match.range(at: 1)),
                source: nsHeader.substring(with: match.range(at: 2)),
                label: nsHeader.substring(with: match.range(at: 3)),
                text: lines.dropFirst().joined(separator: "\n")
            ))
        }
        return rows
    }

    // MARK: - MeetingTranscriptStyler mirror

    // Mirrors the body produced by `MeetingTranscriptStyler.restyleTranscript`
    // (Sources/Meeting/MeetingTranscriptStyler.swift). The entry parsing below
    // tracks `transcriptBlocks`, `parseTranscriptEntries`,
    // `parseTranscriptEntry`, and `parseBracketedSpeakerLabel` line for line;
    // keep it in sync if the styler changes. The title/detail lines only need
    // the shape the speaker rewrite looks for.

    private typealias StyledEntry = (timestamp: String, label: String, text: String)

    private static let stylerTimestampRegex = try! NSRegularExpression(pattern: #"^\[?([0-9:]+)\]?\s+"#)

    private func restyled(_ raw: String) throws -> String {
        let document = try XCTUnwrap(TranscriptFrontmatter.document(in: raw))
        let entries = stylerEntries(from: document.body)
        let transcriptBlock = entries.isEmpty
            ? "_No transcript captured._"
            : entries.map { "**\($0.timestamp)**  [\($0.label)]\n\($0.text)" }.joined(separator: "\n\n")

        var frontmatterLines = document.lines.filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("title:") && !trimmed.hasPrefix("transcript_style:")
        }
        frontmatterLines.append("transcript_style: styled")
        let frontmatter = (["---", "title: \"Weekly Sync\""] + frontmatterLines + ["---"])
            .joined(separator: "\n")

        let body = """
        # Weekly Sync

        Recorded Apr 10, 2026 at 3:01 PM  •  1 min, 30 sec  •  \(entries.count) turns

        ## Transcript

        \(transcriptBlock)
        """
        return frontmatter + "\n\n" + body + "\n"
    }

    private func stylerEntries(from body: String) -> [StyledEntry] {
        for block in stylerTranscriptBlocks(in: body) {
            let entries = stylerParseEntries(from: block)
            if !entries.isEmpty { return entries }
        }
        return stylerParseEntries(from: body.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func stylerTranscriptBlocks(in body: String) -> [String] {
        ["## Full Transcript\n\n", "## Transcript\n\n"].compactMap { marker -> String? in
            guard let start = body.range(of: marker) else { return nil }
            let remaining = String(body[start.upperBound...])
            let end = ["\n---\n", "\n*Generated by ", "\n## "]
                .compactMap { remaining.range(of: $0)?.lowerBound }
                .min() ?? remaining.endIndex
            return String(remaining[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func stylerParseEntries(from block: String) -> [StyledEntry] {
        block
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .compactMap { stylerParseEntry(from: $0) }
    }

    private func stylerParseEntry(from chunk: String) -> StyledEntry? {
        let lines = chunk
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard let firstLine = lines.first else { return nil }
        let normalizedHeader = firstLine
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let nsHeader = normalizedHeader as NSString
        guard let match = Self.stylerTimestampRegex.firstMatch(
            in: normalizedHeader,
            range: NSRange(location: 0, length: nsHeader.length)
        ), match.numberOfRanges >= 2 else {
            return nil
        }

        let timestamp = nsHeader.substring(with: match.range(at: 1))
        let headerTailStart = normalizedHeader.index(
            normalizedHeader.startIndex,
            offsetBy: match.range.location + match.range.length
        )
        guard let parsedLabel = stylerBracketedLabel(in: String(normalizedHeader[headerTailStart...])) else {
            return nil
        }

        let inlineTail = parsedLabel.tail.trimmingCharacters(in: .whitespaces)
        let textLines = inlineTail.isEmpty ? Array(lines.dropFirst()) : [inlineTail] + Array(lines.dropFirst())
        let text = textLines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return (timestamp: timestamp, label: parsedLabel.label, text: text)
    }

    private func stylerBracketedLabel(in value: String) -> (label: String, tail: String)? {
        let characters = Array(value)
        guard characters.first == "[" else { return nil }

        var label = ""
        var index = 1
        var wikiLinkDepth = 0

        while index < characters.count {
            let character = characters[index]
            let next: Character? = index + 1 < characters.count ? characters[index + 1] : nil

            if character == "[", next == "[" {
                wikiLinkDepth += 1
                label.append("[[")
                index += 2
                continue
            }

            if character == "]", next == "]", wikiLinkDepth > 0 {
                wikiLinkDepth -= 1
                label.append("]]")
                index += 2
                continue
            }

            if character == "]", wikiLinkDepth == 0 {
                return (label, String(characters.dropFirst(index + 1)))
            }

            label.append(character)
            index += 1
        }

        return nil
    }
}
