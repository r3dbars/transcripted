import XCTest
@testable import TranscriptedCore

/// Writer side of the format-sync contract.
///
/// `TranscriptedCaptureKit.CaptureMarkdownParser` parses the Markdown that
/// `TranscriptSaver.formatTranscriptMarkdown` writes, but the kit intentionally
/// does not link Core (see `Sources/TranscriptedCore/CLAUDE.md` and
/// `Tools/TranscriptedCaptureKit/CLAUDE.md`), so the two can drift silently.
///
/// This test pins the exact structural tokens the kit keys on. Its sibling,
/// `CaptureMarkdownParserTests.testRoundTripParsesWriterDocument`, parses a
/// verbatim sample of this writer's output. If you change the written format,
/// both must change together.
@available(macOS 14.0, *)
final class TranscriptFormatterCaptureKitContractTests: XCTestCase {

    private static let captureId = UUID(uuidString: "2C356828-221B-43E8-B1BB-93E0C3360E2F")!
    private static let jennyDbId = UUID(uuidString: "80FB272B-6061-4FC4-8408-3F7A974C59DB")!

    private func makeMarkdown() -> String {
        let mic = TranscriptionUtterance(
            start: 0, end: 4, channel: 0, speakerId: 0,
            persistentSpeakerId: nil, matchSimilarity: nil,
            transcript: "Good morning everyone"
        )
        let system = TranscriptionUtterance(
            start: 5, end: 9, channel: 1, speakerId: 0,
            persistentSpeakerId: nil, matchSimilarity: nil,
            transcript: "Let us discuss the roadmap"
        )
        let result = TranscriptionResult(
            micUtterances: [mic],
            systemUtterances: [system],
            duration: 9,
            processingTime: 1.2
        )
        let mappings: [String: SpeakerMapping] = [
            "system_0": SpeakerMapping(
                speakerId: "0",
                identifiedName: "Jenny Wen",
                confidence: .high,
                isConfirmedIdentity: true
            )
        ]
        return TranscriptSaver.formatTranscriptMarkdown(
            result: result,
            transcriptId: Self.captureId,
            speakerMappings: mappings,
            speakerSources: ["system_0": "db_scan"],
            speakerDbIds: ["system_0": Self.jennyDbId],
            date: Date(timeIntervalSince1970: 1_775_000_000)
        )
    }

    // MARK: - Flat frontmatter the kit + Home scanner read

    func testFlatFrontmatterTokensSurviveRoundTrip() throws {
        let doc = makeMarkdown()
        let values = try XCTUnwrap(TranscriptFrontmatter.values(in: doc))

        XCTAssertEqual(values["capture_type"], "meeting", "kit reads capture_type")
        XCTAssertEqual(values["transcription_engine"], "parakeet_local", "kit reads transcription_engine -> sttEngine")
        XCTAssertEqual(values["diarization_engine"], "pyannote_offline", "kit reads diarization_engine")
        XCTAssertEqual(values["total_word_count"], "8")
        XCTAssertEqual(TranscriptFrontmatter.durationSeconds(from: values["duration"]) ?? -1, 9)
    }

    // MARK: - Channel-qualified speaker block the kit parses line-by-line

    func testSpeakerBlockEmitsExactTokensTheKitKeysOn() {
        let doc = makeMarkdown()

        // CaptureMarkdownParser.parseFrontmatterSpeakers matches these literal
        // prefixes after trimming; the leading "speakers:" header gates the block.
        XCTAssertTrue(doc.contains("\nspeakers:"), "speakers block header")
        XCTAssertTrue(doc.contains("\n  - id: \"0\""), "speaker id line")
        XCTAssertTrue(doc.contains("\n    channel: system"), "channel qualifier")
        XCTAssertTrue(doc.contains("\n    db_id: \"80FB272B-6061-4FC4-8408-3F7A974C59DB\""), "db_id line")
        XCTAssertTrue(doc.contains("\n    name: \"Jenny Wen\""), "name line")
        XCTAssertTrue(doc.contains("\n    confidence: high"), "confidence line")
    }

    // MARK: - Transcript body lines the kit's legacy parser expects

    func testTranscriptBodyLinesMatchLegacyRowFormat() {
        let doc = makeMarkdown()

        XCTAssertTrue(doc.contains("## Full Transcript\n\n"), "kit scans for this header")
        // [mm:ss] [Source/Label] text — unmapped mic speaker collapses to "You".
        XCTAssertTrue(doc.contains("[00:00] [Mic/You] Good morning everyone"))
        XCTAssertTrue(doc.contains("[00:05] [System/Jenny Wen] Let us discuss the roadmap"))
    }

    // Guards the regex the kit uses for legacy rows: ^\[ts\] \[source/label\] text.
    func testEveryTranscriptRowIsKitParseable() throws {
        let doc = makeMarkdown()
        let body = try XCTUnwrap(TranscriptFrontmatter.body(in: doc))
        let transcriptStart = try XCTUnwrap(body.range(of: "## Full Transcript\n\n"))
        let rows = body[transcriptStart.upperBound...]
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("[") }

        XCTAssertEqual(rows.count, 2)
        let regex = try NSRegularExpression(pattern: #"^\[[0-9:]+\] \[[^/]+/.+\] .+"#)
        for row in rows {
            let range = NSRange(row.startIndex..., in: row)
            XCTAssertNotNil(
                regex.firstMatch(in: row, range: range),
                "row not parseable by kit legacy regex: \(row)"
            )
        }
    }
}
