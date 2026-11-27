import Foundation
import XCTest
@testable import TranscriptedCore

/// The v2 styled dialogue grammar (`[MM:SS] **Speaker:** text`): a bare label
/// gets its channel from the frontmatter `speakers:` rows, and passes that
/// qualify and compact labels round-trip. See docs/capture-format.md.
final class TranscriptFrontmatterDialogueTests: XCTestCase {
    private let document = """
    ---
    title: "Roadmap check-in"
    capture_id: "5E9A0000-0000-0000-0000-000000000001"
    capture_type: meeting
    format_version: 2
    transcript_style: styled
    speakers:
      - id: "0"
        channel: mic
        name: "Ana"
        confidence: high
        source: db_scan
      - id: "1"
        channel: system
        name: "Speaker 1"
        confidence: unknown
        source: db_pending
      - id: "2"
        channel: system
        name: "Ana"
        confidence: unknown
        source: db_pending
    ---

    # Roadmap check-in

    ## Transcript

    [00:01] **Mic/Ana:** Morning, everyone.

    [00:05] **Speaker 1:** Hi. Can you hear me?

    [00:09] **System/Ana:** Loud and clear.

    [01:00:02] **You:** Wrapping up.
    """

    func testParsesBareAndQualifiedLabels() {
        XCTAssertEqual(
            TranscriptFrontmatterDialogue.parseLine("[01:43] **You:** What? Yeah, I do."),
            .init(timestamp: "01:43", qualifier: nil, name: "You", text: "What? Yeah, I do.")
        )
        XCTAssertEqual(
            TranscriptFrontmatterDialogue.parseLine("[1:00:02] **System/Dana:** Sure."),
            .init(timestamp: "1:00:02", qualifier: .system, name: "Dana", text: "Sure.")
        )
        // A slash in a name is not a channel.
        XCTAssertEqual(
            TranscriptFrontmatterDialogue.parseLine("[00:02] **AC/DC:** Hey")?.name,
            "AC/DC"
        )
        XCTAssertNil(TranscriptFrontmatterDialogue.parseLine("[00:00] [Mic/You] Raw row."))
        XCTAssertNil(TranscriptFrontmatterDialogue.parseLine("**00:00**  [Mic/You]"))
        XCTAssertNil(TranscriptFrontmatterDialogue.parseLine("[soon] **You:** not a time"))
    }

    func testResolvesChannelsFromSpeakerRows() {
        let channels = TranscriptFrontmatterDialogue.speakerChannels(in: document)
        XCTAssertEqual(channels["Ana"], [.mic, .system])
        XCTAssertEqual(channels["Speaker 1"], [.system])

        XCTAssertEqual(TranscriptFrontmatterDialogue.resolvedChannel(forName: "Speaker 1", in: channels), .system)
        // No row: You is the mic, anyone else the call.
        XCTAssertEqual(TranscriptFrontmatterDialogue.resolvedChannel(forName: "You", in: channels), .mic)
        XCTAssertEqual(TranscriptFrontmatterDialogue.resolvedChannel(forName: "Lee", in: channels), .system)
        // Rows on both channels: the bare name can't say, so the label must.
        XCTAssertEqual(TranscriptFrontmatterDialogue.label(name: "Ana", channel: .mic, channels: channels), "Mic/Ana")
        XCTAssertEqual(TranscriptFrontmatterDialogue.label(name: "Ana", channel: .system, channels: channels), "Ana")
        XCTAssertEqual(TranscriptFrontmatterDialogue.label(name: "You", channel: .mic, channels: channels), "You")
        // A mic voice nobody listed is qualified rather than read as the call.
        XCTAssertEqual(TranscriptFrontmatterDialogue.label(name: "Lee", channel: .mic, channels: channels), "Mic/Lee")
    }

    func testQualifyThenCompactRoundTrips() {
        let qualified = TranscriptFrontmatterDialogue.qualifyingLabels(in: document)
        XCTAssertTrue(qualified.contains("[00:05] **System/Speaker 1:** Hi. Can you hear me?"), qualified)
        XCTAssertTrue(qualified.contains("[01:00:02] **Mic/You:** Wrapping up."), qualified)
        XCTAssertTrue(qualified.contains("[00:01] **Mic/Ana:** Morning, everyone."), qualified)

        let compacted = TranscriptFrontmatterDialogue.compactingLabels(in: qualified)
        // `System/Ana` compacts too: a bare `Ana` reads as the call.
        XCTAssertEqual(compacted, document.replacingOccurrences(of: "**System/Ana:**", with: "**Ana:**"))
    }

    func testBracketedLinesGiveRawRowsForReaders() {
        let bracketed = TranscriptFrontmatterDialogue.bracketedLines(in: document)
        XCTAssertTrue(bracketed.contains("[00:01] [Mic/Ana] Morning, everyone."), bracketed)
        XCTAssertTrue(bracketed.contains("[00:05] [System/Speaker 1] Hi. Can you hear me?"), bracketed)
        XCTAssertTrue(bracketed.contains("[00:09] [System/Ana] Loud and clear."), bracketed)
        XCTAssertTrue(bracketed.contains("[01:00:02] [Mic/You] Wrapping up."), bracketed)
        XCTAssertTrue(bracketed.hasPrefix("---\ntitle: \"Roadmap check-in\""))
    }

    func testFilesWithoutV2LinesPassThroughUnchanged() {
        let v1 = """
        ---
        capture_type: meeting
        ---

        ## Transcript

        **00:00**  [Mic/You]
        Thanks for making time today.
        """
        var edited = v1
        TranscriptFrontmatterDialogue.withQualifiedLabels(in: &edited) { _ in }
        XCTAssertEqual(edited, v1)
        XCTAssertEqual(TranscriptFrontmatterDialogue.bracketedLines(in: v1), v1)
    }

    func testOnlyTheTranscriptSectionIsRewritten() {
        let markdown = """
        ---
        capture_type: meeting
        ---

        # Notes

        ## Summary

        [00:01] **Quote:** not a transcript row.

        ## Transcript

        [00:02] **Speaker 1:** Hello.
        """
        let qualified = TranscriptFrontmatterDialogue.qualifyingLabels(in: markdown)
        XCTAssertTrue(qualified.contains("[00:01] **Quote:** not a transcript row."), qualified)
        XCTAssertTrue(qualified.contains("[00:02] **System/Speaker 1:** Hello."), qualified)
    }
}
