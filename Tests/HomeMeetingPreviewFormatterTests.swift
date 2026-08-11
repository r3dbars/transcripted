import Foundation

func testHomeMeetingPreviewFormatter() {
    runSuite("HomeMeetingPreviewFormatter parses current styled meeting markdown") {
        let content = HomeMeetingPreviewContent.make(from: styledMeetingMarkdown())

        assertEqual(content.transcriptLines.count, 4, "Styled transcript blocks should become readable rows")
        assertEqual(content.transcriptLines.first?.time, "00:00", "First row should keep the timestamp")
        assertEqual(content.transcriptLines.first?.speaker, "Speaker 1", "Preview should show only the speaker name")
        assertEqual(content.transcriptLines.first?.identity.channel, .system, "Source should stay available without appearing in the name")
        assertEqual(
            content.transcriptLines.first?.identity.persistentSpeakerID,
            UUID(uuidString: "11111111-1111-1111-1111-111111111111"),
            "Frontmatter identity should follow the visible transcript row"
        )
        assertTrue(
            content.transcriptLines.first?.text.hasPrefix("touch screen. Yeah.") == true,
            "Text on the line after the timestamp should be attached to the row"
        )
        assertFalse(content.fallbackText.contains("capture_id:"), "Preview fallback should not expose YAML metadata")
    }

    runSuite("HomeMeetingPreviewFormatter parses legacy inline transcript rows") {
        let content = HomeMeetingPreviewContent.make(from: legacyInlineMarkdown())

        assertEqual(content.transcriptLines.count, 2, "Legacy inline transcript rows should still preview cleanly")
        assertEqual(content.transcriptLines[0].text, "Hello there.", "Inline text should stay on the row")
        assertEqual(content.transcriptLines[0].speaker, "You", "Mic source prefixes should not appear in the speaker name")
        assertEqual(content.transcriptLines[1].speaker, "Alex", "Obsidian speaker links should be cleaned for preview")
        assertEqual(content.transcriptLines[1].text, "Nice to meet you.", "Nested speaker links should not leak closing brackets into text")
    }

    runSuite("HomeMeetingSpeakerNamingPolicy groups voices and keeps saved-person identity") {
        let lines = HomeMeetingPreviewContent.make(from: styledMeetingMarkdown()).transcriptLines
        let drafts = HomeMeetingSpeakerNamingPolicy.drafts(from: lines)

        assertEqual(drafts.count, 3, "Same visible name on different channels/voice ids must stay separate")
        let micLinus = drafts.first {
            $0.identity.channel == .mic && $0.identity.diarizerSpeakerID == "0"
        }
        assertEqual(micLinus?.sampleTexts.count, 2, "A voice should carry up to two first-seen quotes")

        let selectedProfileID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        guard var selectedDraft = drafts.first else {
            assertionFailure("fixture should produce a speaker naming draft")
            return
        }
        selectedDraft.name = "Alex"
        selectedDraft.selectedProfileID = selectedProfileID
        let selectedAssignment = HomeMeetingSpeakerNamingPolicy.assignment(from: selectedDraft)
        assertEqual(
            selectedAssignment?.targetProfileID,
            selectedProfileID,
            "Dropdown selection must retain its UUID instead of degrading to display-name matching"
        )

        selectedDraft.selectedProfileID = nil
        selectedDraft.name = "  Jordan\nTest  "
        assertEqual(
            HomeMeetingSpeakerNamingPolicy.assignment(from: selectedDraft)?.newName,
            "Jordan Test",
            "Typed names should normalize whitespace before persistence"
        )

        selectedDraft.name = selectedDraft.identity.displayName
        assertTrue(
            HomeMeetingSpeakerNamingPolicy.assignment(from: selectedDraft) == nil,
            "An unchanged typed name should not create a write"
        )

        let profileA = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let profileB = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let profileC = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        func savedIdentity(_ name: String, id: UUID, voice: String) -> HomeMeetingSpeakerIdentity {
            HomeMeetingSpeakerIdentity(
                displayName: name,
                rawLabel: "System/\(name)",
                channel: .system,
                diarizerSpeakerID: voice,
                persistentSpeakerID: id
            )
        }
        let bIntoC = HomeMeetingSpeakerAssignment(
            identity: savedIdentity("B", id: profileB, voice: "2"),
            newName: "C",
            targetProfileID: profileC
        )
        let aIntoB = HomeMeetingSpeakerAssignment(
            identity: savedIdentity("A", id: profileA, voice: "1"),
            newName: "B",
            targetProfileID: profileB
        )
        let ordered = HomeMeetingSpeakerNamingPolicy.savedAssignmentsInCommitOrder([bIntoC, aIntoB])
        assertEqual(
            ordered?.compactMap(\.identity.persistentSpeakerID),
            [profileA, profileB],
            "Merge chains should commit leaf sources before a target profile is removed"
        )

        let localIdentity = HomeMeetingSpeakerIdentity(
            displayName: "Speaker 9",
            rawLabel: "System/Speaker 9",
            channel: .system,
            diarizerSpeakerID: "9",
            persistentSpeakerID: nil
        )
        let localLink = HomeMeetingSpeakerAssignment(
            identity: localIdentity,
            newName: "A",
            targetProfileID: profileA
        )
        assertEqual(
            HomeMeetingSpeakerNamingPolicy.remappingLocalTargets(
                [localLink],
                after: [aIntoB, bIntoC]
            )?.first?.targetProfileID,
            profileC,
            "A local row should link to the final surviving profile after a same-batch merge chain"
        )

        let cIntoA = HomeMeetingSpeakerAssignment(
            identity: savedIdentity("C", id: profileC, voice: "3"),
            newName: "A",
            targetProfileID: profileA
        )
        assertTrue(
            HomeMeetingSpeakerNamingPolicy.savedAssignmentsInCommitOrder([aIntoB, bIntoC, cIntoA]) == nil,
            "Cyclic saved-person merges should fail before any profile is changed"
        )
    }
}

private func styledMeetingMarkdown() -> String {
    """
    ---
    title: "Meeting with Linus"
    capture_id: "297F08B7-62AE-4291-9EA3-41EB0B17A64A"
    capture_type: meeting
    total_word_count: 117
    speakers:
      - id: "1"
        channel: system
        db_id: "11111111-1111-1111-1111-111111111111"
        name: "Speaker 1"
        source: db_pending
      - id: "0"
        channel: mic
        name: "Linus"
        source: user_manual
      - id: "2"
        channel: system
        name: "Linus"
        source: user_manual
    ---

    # Meeting with Linus

    Recorded Apr 25, 2026 at 12:18 PM  •  31 sec  •  117 words  •  4 turns

    ## Transcript

    **00:00**  [System/Speaker 1]
    touch screen. Yeah. It actually is that it took us this long.

    **00:00**  [Mic/Linus]
    Yeah. It actually is and it took us a bit long to get to Or if we have

    **00:12**  [Mic/Linus]
    Oh

    **00:26**  [System/Linus]
    Dude, this is incredible. I'm honestly impressed.
    """
}

private func legacyInlineMarkdown() -> String {
    """
    ---
    capture_type: meeting
    ---

    # Meeting Recording

    ## Full Transcript

    [00:01] [Mic/You] Hello there.

    [00:05] [System/[[Alex]]] Nice to meet you.

    *Generated by Transcripted with Parakeet*
    """
}
