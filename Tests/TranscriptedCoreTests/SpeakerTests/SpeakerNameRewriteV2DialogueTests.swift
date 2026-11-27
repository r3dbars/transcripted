import Foundation
import XCTest
@testable import TranscriptedCore

/// Speaker naming and renames on `format_version: 2` styled meetings, whose
/// rows are `[MM:SS] **Speaker:** text` with the channel in the frontmatter.
/// One row may stand for several merged same-speaker utterances.
@available(macOS 14.0, *)
final class SpeakerNameRewriteV2DialogueTests: XCTestCase {
    private var tempDirectory: URL!
    private let dbSpeaker1 = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let dbSpeaker2 = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeakerNameRewriteV2DialogueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
    }

    // MARK: - Naming after review

    func testNamingAReviewedVoiceRewritesMergedV2Rows() throws {
        let url = try write(styledV2())
        let didUpdate = TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: [update(.system, "1", "Dana", dbId: dbSpeaker1)],
            transcriptionResult: result()
        )
        XCTAssertTrue(didUpdate)

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("[00:00] **You:** Thanks for making time today."), updated)
        XCTAssertTrue(updated.contains("[00:04] **Dana:** Happy to help. Let's get started."), updated)
        XCTAssertTrue(updated.contains("[00:20] **Speaker 2:** I have a question."), updated)
        XCTAssertTrue(updated.contains("[00:30] **Dana:** Go ahead."), updated)
        XCTAssertFalse(updated.contains("Speaker 1:**"), updated)
        XCTAssertFalse(updated.contains("**System/"), updated)
        XCTAssertEqual(TranscriptSaver.currentSpeakerName(in: updated, diarizerSpeakerId: "1", channel: .system), "Dana")
    }

    func testNamingACallVoiceLikeTheMicVoiceQualifiesBothSides() throws {
        let url = try write(styledV2(micRowName: "Ana"))
        XCTAssertTrue(TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: [update(.system, "2", "Ana", dbId: dbSpeaker2)],
            transcriptionResult: result()
        ))

        let updated = try String(contentsOf: url, encoding: .utf8)
        // The same name on both channels: the mic side spells its channel out
        // and a bare `Ana` still reads as the call.
        XCTAssertTrue(updated.contains("[00:00] **Mic/Ana:** Thanks for making time today."), updated)
        XCTAssertTrue(updated.contains("[00:20] **Ana:** I have a question."), updated)
        let channels = TranscriptFrontmatterDialogue.speakerChannels(in: updated)
        let rows = updated.components(separatedBy: "\n").compactMap(TranscriptFrontmatterDialogue.parseLine)
        XCTAssertEqual(
            rows.map { TranscriptFrontmatterDialogue.channel(of: $0, in: channels) },
            [.mic, .system, .system, .system]
        )
    }

    // MARK: - Settings rename by profile

    func testRenamingAPersonRewritesV2Labels() throws {
        var content = styledV2(speaker1Name: "Dana", speaker1Source: "db")
        let changed = TranscriptSaver.applyRetroactiveRename(
            in: &content,
            dbId: dbSpeaker1,
            newName: "Dana Reyes",
            fileName: "meeting.md"
        )
        XCTAssertTrue(changed)
        XCTAssertTrue(content.contains("[00:04] **Dana Reyes:** Happy to help."), content)
        XCTAssertTrue(content.contains("[00:30] **Dana Reyes:** Go ahead."), content)
        XCTAssertTrue(content.contains("[00:00] **You:** Thanks"), content)
        XCTAssertTrue(content.contains("name: \"Dana Reyes\""), content)
    }

    func testKeepAsYouCollapsesV2MicLabels() throws {
        let url = try write(styledV2(micRowName: "Speaker 0"))
        XCTAssertTrue(TranscriptSaver.collapseMicSpeakersToYou(
            transcriptURL: url,
            collapsedUpdates: [update(.mic, "0", "You", dbId: UUID())]
        ))

        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("[00:00] **You:** Thanks for making time today."), updated)
        XCTAssertFalse(updated.contains("Speaker 0"), updated)
        XCTAssertTrue(updated.contains("[00:20] **Speaker 2:** I have a question."), updated)
    }

    func testV1StyledRowsStillRewrite() throws {
        let v1 = styledV2()
            .replacingOccurrences(of: "[00:00] **You:** ", with: "**00:00**  [Mic/You]\n")
            .replacingOccurrences(of: "[00:04] **Speaker 1:** ", with: "**00:04**  [System/Speaker 1]\n")
            .replacingOccurrences(of: "[00:20] **Speaker 2:** ", with: "**00:20**  [System/Speaker 2]\n")
            .replacingOccurrences(of: "[00:30] **Speaker 1:** ", with: "**00:30**  [System/Speaker 1]\n")
        let url = try write(v1)
        XCTAssertTrue(TranscriptSaver.updateSpeakerNames(
            transcriptURL: url,
            updates: [update(.system, "1", "Dana", dbId: dbSpeaker1)],
            transcriptionResult: result()
        ))
        let updated = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(updated.contains("**00:04**  [System/Dana]\nHappy to help."), updated)
        XCTAssertTrue(updated.contains("**00:30**  [System/Dana]\nGo ahead."), updated)
    }

    // MARK: - Fixtures

    /// Utterances behind `styledV2()`: the call voice's 00:04 and 00:07 lines
    /// were merged into one row.
    private func result() -> TranscriptionResult {
        let utterances = [
            utterance(0, .mic, 0, "Thanks for making time today."),
            utterance(4, .system, 1, "Happy to help."),
            utterance(7, .system, 1, "Let's get started."),
            utterance(20, .system, 2, "I have a question."),
            utterance(30, .system, 1, "Go ahead."),
        ]
        return TranscriptionResult(
            micUtterances: utterances.filter { $0.channel == 0 },
            systemUtterances: utterances.filter { $0.channel == 1 },
            duration: 40,
            processingTime: 1
        )
    }

    private func styledV2(
        micRowName: String? = nil,
        speaker1Name: String = "Speaker 1",
        speaker1Source: String = "db_pending"
    ) -> String {
        let micRow = micRowName.map {
            """

              - id: "0"
                channel: mic
                name: "\($0)"
                confidence: unknown
                source: db_pending
            """
        } ?? ""
        let micLabel = micRowName.map { $0 == "Ana" ? "Ana" : "Mic/\($0)" } ?? "You"
        return """
        ---
        title: "Vendor sync"
        capture_id: "5E9A0000-0000-0000-0000-0000000000AB"
        capture_type: meeting
        format_version: 2
        transcript_style: styled
        date: 2026-04-07
        time: 09:14:00
        duration: "0:40"
        total_word_count: 18
        speakers:\(micRow)
          - id: "1"
            channel: system
            db_id: "\(dbSpeaker1.uuidString)"
            name: "\(speaker1Name)"
            confidence: unknown
            source: \(speaker1Source)
          - id: "2"
            channel: system
            db_id: "\(dbSpeaker2.uuidString)"
            name: "Speaker 2"
            confidence: unknown
            source: db_pending
        ---

        # Vendor sync

        Recorded Apr 7, 2026 at 9:14 AM  •  40 sec  •  18 words  •  4 turns

        ## Transcript

        [00:00] **\(micLabel):** Thanks for making time today.

        [00:04] **\(speaker1Name):** Happy to help. Let's get started.

        [00:20] **Speaker 2:** I have a question.

        [00:30] **\(speaker1Name):** Go ahead.

        """
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

    private func update(_ channel: UtteranceChannel, _ id: String, _ name: String, dbId: UUID) -> SpeakerNameUpdate {
        SpeakerNameUpdate(
            persistentSpeakerId: dbId,
            diarizerSpeakerId: id,
            channel: channel,
            newName: name,
            previousName: nil,
            action: .named
        )
    }

    private func write(_ markdown: String) throws -> URL {
        let url = tempDirectory.appendingPathComponent("\(UUID().uuidString).md")
        try markdown.write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
