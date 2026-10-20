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

    runSuite("HomeMeetingTranscriptLine turns row clock times into audio offsets") {
        let lines = HomeMeetingPreviewContent.make(from: styledMeetingMarkdown()).transcriptLines
        assertEqual(lines.map(\.startSeconds), [0, 0, 12, 26], "Clickable timestamps should seek to the row's own time")

        assertEqual(HomeMeetingTranscriptClock.seconds(from: "01:05"), 65, "MM:SS should parse")
        assertEqual(HomeMeetingTranscriptClock.seconds(from: "1:02:03"), 3723, "H:MM:SS should parse")
        assertEqual(HomeMeetingTranscriptClock.seconds(from: "75:00"), 4500, "Long meetings can run past 60 minutes in MM:SS")
        assertEqual(HomeMeetingTranscriptClock.seconds(from: "125:30"), 7530, "The transcript writer uses 3-digit minutes past 100 minutes")
        assertNil(HomeMeetingTranscriptClock.seconds(from: "00:60"), "Seconds must stay under 60")
        assertNil(HomeMeetingTranscriptClock.seconds(from: "1:60:00"), "Minutes must stay under 60 when hours are shown")
        assertNil(HomeMeetingTranscriptClock.seconds(from: "12"), "A bare number is not a clock time")
        assertNil(HomeMeetingTranscriptClock.seconds(from: ""), "An empty time is not clickable")
        assertNil(HomeMeetingTranscriptClock.seconds(from: "99999999999999999999:00"), "Oversized values must not overflow")
        assertEqual(HomeMeetingTranscriptClock.seconds(from: "00:05.4"), 5.4, "A fractional second must seek to that offset, not the whole second")
        assertEqual(HomeMeetingTranscriptClock.seconds(from: "1:02:03.25"), 3723.25, "H:MM:SS.frac should keep the fraction")
        assertNil(HomeMeetingTranscriptClock.seconds(from: "00:05."), "A trailing dot is not a usable clock")
        assertNil(HomeMeetingTranscriptClock.seconds(from: "00:05.1234"), "Fraction is capped at milliseconds")
    }

    runSuite("HomeMeetingSpeakerNamingPolicy leads with the quote speaker review would play") {
        let speakerId = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let markdown = """
        ---
        capture_type: meeting
        speakers:
          - id: "1"
            channel: system
            db_id: "\(speakerId.uuidString)"
            name: "Speaker 1"
            source: db_pending
        ---

        ## Transcript

        **00:01** [System/Speaker 1]
        Hi.

        **00:20** [System/Speaker 1]
        We should finish the pricing memo.

        **00:32** [System/Someone else]
        Thanks for joining.
        """
        let lines = HomeMeetingPreviewContent.make(from: markdown).transcriptLines
        let drafts = HomeMeetingSpeakerNamingPolicy.drafts(from: lines)
        guard let draft = drafts.first(where: { $0.identity.persistentSpeakerID == speakerId }) else {
            assertionFailure("fixture should produce a naming draft for the pending voice")
            return
        }
        assertEqual(
            draft.sampleTexts,
            ["We should finish the pricing memo.", "Hi."],
            "Who is this? must show the played sentence first, not the greeting that happens to be first in the file"
        )
        let sample = SpeakerReviewSamplePolicy.sample(
            matching: draft.identity, in: lines, meetingDuration: 120
        )
        assertEqual(sample?.mixedWindow?.text, draft.sampleTexts.first)
        assertEqual(sample?.mixedWindow?.startTime, 20)
    }

    runSuite("Home meeting rows retain hour clocks and legacy playback offsets") {
        let clocks: [(String, Double)] = [
            ("59:59", 3599), ("60:00", 3600), ("1:00:00", 3600),
            ("01:00:00", 3600), ("01:00:01", 3601),
            ("24:00:00", 86400), ("6000:00", 360000), ("100:00:00", 360000),
        ]
        for styled in [false, true] {
            let rows = clocks.map { clock in
                styled
                    ? "**\(clock.0)**  [System/Speaker 0]\nSynthetic text."
                    : "[\(clock.0)] [System/Speaker 0] Synthetic text."
            }.joined(separator: "\n\n")
            let content = HomeMeetingPreviewContent.make(from: "## \(styled ? "Transcript" : "Full Transcript")\n\n\(rows)")
            assertEqual(content.transcriptLines.map(\.time), clocks.map { $0.0 })
            assertEqual(content.transcriptLines.map(\.startSeconds), clocks.map { Optional($0.1) })
        }
    }

    runSuite("HomeMeetingSpeakerNamingPolicy groups voices and keeps saved-person identity") {
        let lines = HomeMeetingPreviewContent.make(from: styledMeetingMarkdown()).transcriptLines
        let drafts = HomeMeetingSpeakerNamingPolicy.drafts(from: lines)

        assertEqual(drafts.count, 3, "Same visible name on different channels/voice ids must stay separate")
        let micLinus = drafts.first {
            $0.identity.channel == .mic && $0.identity.diarizerSpeakerID == "0"
        }
        assertEqual(micLinus?.sampleTexts.count, 2, "A voice should carry up to two first-seen quotes")
        assertEqual(
            micLinus?.sampleTexts.first,
            "Yeah. It actually is and it took us a bit long to get to Or if we have",
            "the longer first-seen line is already the representative quote"
        )

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

    // A 1.1.72 CLI retest: a meeting the app didn't record (CLI import
    // or an older file) has numbered speakers with no db_id. Naming that voice
    // from Home must not pretend a saved person exists — assignmentPlan can
    // only rewrite this transcript. A voiceprint, if any, has to be enrolled
    // separately from retained audio.
    runSuite("Naming an unlinked imported voice stays transcript-local") {
        let importedVoice = HomeMeetingSpeakerIdentity(
            displayName: "Speaker 2",
            rawLabel: "System/Speaker 2",
            channel: .system,
            diarizerSpeakerID: "2",
            persistentSpeakerID: nil
        )
        let assignment = HomeMeetingSpeakerAssignment(
            identity: importedVoice,
            newName: "Priya",
            targetProfileID: nil
        )
        let line = HomeMeetingTranscriptLine(
            time: "00:00",
            identity: importedVoice,
            text: "Hello from an imported meeting."
        )
        let plan = HomeMeetingSpeakerNamingPolicy.assignmentPlan(
            for: [assignment],
            transcriptLines: [line],
            availableProfileIDs: []
        )
        assertEqual(plan?.localAssignments.count, 1, "an unlinked CLI/imported voice has no saved profile to edit")
        assertEqual(plan?.savedAssignments.count, 0, "Home must not route an unlinked name through the speaker store")
        assertEqual(plan?.localAssignments.first?.targetProfileID, nil, "typed names stay transcript-only until a voiceprint is enrolled")
        assertEqual(
            HomeMeetingSpeakerNamingCopy.transcriptOnlyNoVoiceprint,
            "Named in this transcript only, no voiceprint saved"
        )
        let enrolledID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let linked = HomeMeetingSpeakerVoiceprintSave.linking(assignment, to: enrolledID)
        assertEqual(linked.targetProfileID, enrolledID, "a later enrollment should attach the new person to this row")
        assertEqual(linked.newName, "Priya")
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
