import Foundation

/// Promises for the call app's name in review: it is a hint next to a
/// voice ("Call app showed: Maya"), never a prefill, never a label, and
/// never saved untouched. Old `name_source: call_app` files still read.
func testCallAppNameHint() {
    typealias Policy = NotchIslandSpeakerReviewPolicy

    runSuite("The call app's name never fills a name box; only the calendar 1:1 name does") {
        let entry = callAppHintEntry(callAppName: "Rina Okafor")
        assertNil(Policy.prefillName(for: entry), "a call-app name alone fills nothing")
        assertEqual(
            Policy.prefillName(for: entry, oneOnOneName: "Tomás Vidal"), "Tomás Vidal",
            "the calendar 1:1 name still fills in, call-app name or not"
        )
        assertNil(Policy.prefillName(for: entry, oneOnOneName: "Tomás Vidal", typed: "To"), "typed text stays")
        assertNil(Policy.prefillName(for: callAppHintEntry(callAppName: nil), oneOnOneName: "  "))
    }

    runSuite("An unnamed voice offers the call app's name as a tappable hint") {
        let hint = Policy.callAppHint(callAppShownName: "  Rina Okafor \n", state: .naming(.unknownVoice), currentName: nil)
        assertEqual(hint, .offer(name: "Rina Okafor"), "trimmed, and offered")
        assertEqual(hint?.text, "Call app showed: Rina Okafor")
        assertEqual(hint?.fillsName, "Rina Okafor", "a tap puts the name in the box")
        assertNil(Policy.callAppHint(callAppShownName: "   ", state: .naming(.unknownVoice), currentName: nil), "blank is no hint")
        assertNil(Policy.callAppHint(callAppShownName: nil, state: .naming(.unknownVoice), currentName: nil))
    }

    runSuite("A voiceprint guess keeps its question; the call app only agrees or differs") {
        let agrees = Policy.callAppHint(callAppShownName: "ana  LIMA", state: .asking, currentName: "Ana Lima")
        assertEqual(agrees, .agrees(name: "ana  LIMA"))
        assertEqual(agrees?.text, "Call app showed ana  LIMA too", "agreement is corroboration")
        assertNil(agrees?.fillsName, "nothing to tap: the guess is already the question")

        let differs = Policy.callAppHint(callAppShownName: "Rina Okafor", state: .asking, currentName: "Ana Lima")
        assertEqual(differs, .differs(name: "Rina Okafor"))
        assertEqual(differs?.text, "Call app showed: Rina Okafor")
        assertNil(differs?.fillsName, "a conflict never replaces the voiceprint's question")
    }

    runSuite("After No, the call app's name is offered unless it's the name just turned down") {
        assertEqual(
            Policy.callAppHint(callAppShownName: "Rina Okafor", state: .naming(.rejectedSuggestion), currentName: "Ana Lima"),
            .offer(name: "Rina Okafor")
        )
        assertNil(
            Policy.callAppHint(callAppShownName: "Ana Lima", state: .naming(.rejectedSuggestion), currentName: "Ana Lima"),
            "the person just said it isn't Ana Lima"
        )
    }

    runSuite("Answered, recognized and locked rows show no call-app hint") {
        let states: [Policy.RowState] = [.confirmed, .recognized, .named(.newPerson), .named(.savedPerson), .locked(.discarded), .locked(.keptAsYou)]
        for state in states {
            assertNil(Policy.callAppHint(callAppShownName: "Rina Okafor", state: state, currentName: nil), "\(state)")
        }
    }

    runSuite("Nothing in the box means nothing saved, even with a call-app name on the row") {
        assertNil(
            Policy.answerOnFinish(committed: nil, typed: "", suggestions: [], highlighted: nil, finish: .done),
            "an untouched hint is never in the box, so Done saves nothing"
        )
        assertEqual(
            Policy.answerOnFinish(committed: nil, typed: "Rina Okafor", suggestions: [], highlighted: nil, finish: .done),
            "Rina Okafor",
            "after a tap, the name in the box saves like a typed name"
        )
        assertNil(
            Policy.answerOnFinish(committed: nil, typed: "Tomás Vidal", suggestions: [], highlighted: nil, typedIsUntouchedPrefill: true, finish: .later),
            "Later never saves an untouched calendar name"
        )
        assertEqual(
            Policy.answerOnFinish(committed: nil, typed: "Tomás Vidal", suggestions: [], highlighted: nil, typedIsUntouchedPrefill: true, finish: .done),
            "Tomás Vidal",
            "the calendar 1:1 name keeps saving on Done"
        )
    }

    runSuite("The Speakers row drafts only a saved name and offers the call app's name as a hint") {
        assertNil(Policy.reviewRowDraft(currentDraft: "", savedName: nil), "a call-app name never drafts itself in")
        assertEqual(Policy.reviewRowDraft(currentDraft: "", savedName: " Ana Lima "), "Ana Lima")
        assertNil(Policy.reviewRowDraft(currentDraft: "Tom", savedName: "Ana Lima"), "a draft in progress is left alone")
        assertEqual(
            Policy.reviewRowCallAppHint(callAppShownName: "Rina Okafor", savedName: nil),
            .offer(name: "Rina Okafor")
        )
        assertNil(Policy.reviewRowCallAppHint(callAppShownName: "Rina Okafor", savedName: "Ana Lima"), "a saved name needs no hint")
        assertNil(Policy.reviewRowCallAppHint(callAppShownName: nil, savedName: nil))
    }

    runSuite("Who spoke? reads call_app_name as a hint and keeps the voice's own label") {
        let callId = UUID()
        let plainId = UUID()
        let markdown = """
        ---
        transcript_id: "\(UUID().uuidString)"
        title: "Planning sync"
        capture_type: meeting
        date: 2026-05-20
        time: 09:30:00
        speakers:
          - id: "1"
            channel: system
            db_id: "\(callId.uuidString)"
            name: "Speaker 1"
            confidence: unknown
            source: db_pending
            call_app_name: "Rina Okafor"
            call_app_agreement: no_voiceprint_guess
            call_app_seconds: 42.5
            call_app_share: 0.92
            call_app_coverage: 0.61
          - id: "2"
            channel: system
            db_id: "\(plainId.uuidString)"
            name: "Speaker 2"
            confidence: unknown
            source: db_pending
            call_app_withheld: names_disagree
        ---

        # Planning sync

        ## Transcript

        **00:01** [System/Speaker 1]
        Let's start with the budget.

        **00:09** [System/Speaker 2]
        Sounds good to me.
        """
        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: URL(fileURLWithPath: "/nonexistent-call-app-hint/Planning_sync.md"),
            profilesById: [callId: callAppHintProfile(id: callId), plainId: callAppHintProfile(id: plainId)],
            clipURLsByProfileID: [:]
        )
        let hinted = items.first { $0.speakerId == callId }
        let plain = items.first { $0.speakerId == plainId }
        assertEqual(items.count, 2, "both voices are still pending")
        assertEqual(hinted?.callAppShownName, "Rina Okafor", "call_app_name is the hint")
        assertEqual(hinted?.sourceName, "Speaker 1", "the label is still the placeholder")
        assertEqual(hinted?.sampleText, "Let's start with the budget.")
        assertNil(plain?.callAppShownName, "a withheld read has no name to hint")
        let card = SpeakerReviewQueueScanner.groupedByMeeting(SpeakerReviewQueueScanner.groupedByVoice(items))
        assertEqual(
            card.first?.voices.first { $0.id == callId }?.representative.callAppShownName, "Rina Okafor",
            "the Speakers Who spoke? card gets the hint too"
        )
    }

    runSuite("An old name_source: call_app file still reads, its name now only a hint") {
        let callId = UUID()
        let markdown = """
        ---
        title: "Older call"
        capture_type: meeting
        date: 2026-05-20
        time: 09:30:00
        speakers:
          - id: "1"
            channel: system
            db_id: "\(callId.uuidString)"
            name: "Rina Okafor"
            confidence: medium
            source: db_pending
            name_source: call_app
        ---

        ## Transcript

        **00:01** [System/Rina Okafor]
        Let's start with the budget.
        """
        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: URL(fileURLWithPath: "/nonexistent-call-app-hint/Older_call.md"),
            profilesById: [callId: callAppHintProfile(id: callId)],
            clipURLsByProfileID: [:]
        )
        assertEqual(items.count, 1, "still pending")
        assertEqual(items.first?.callAppShownName, "Rina Okafor")
        assertEqual(items.first?.sourceName, "Rina Okafor", "the old label reads as saved")
        assertEqual(items.first?.sampleText, "Let's start with the budget.")
    }

    runSuite("A real name without call-app keys is not a hint") {
        let id = UUID()
        let markdown = """
        ---
        title: "Hand-edited"
        capture_type: meeting
        date: 2026-05-20
        time: 09:30:00
        speakers:
          - id: "1"
            channel: system
            db_id: "\(id.uuidString)"
            name: "Rina Okafor"
            confidence: unknown
            source: db_pending
        ---

        ## Transcript

        **00:01** [System/Rina Okafor]
        Hello there.
        """
        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: URL(fileURLWithPath: "/nonexistent-call-app-hint/Hand_edited.md"),
            profilesById: [id: callAppHintProfile(id: id)],
            clipURLsByProfileID: [:]
        )
        assertEqual(items.count, 1)
        assertNil(items.first?.callAppShownName)
    }
}

private func callAppHintEntry(callAppName: String?) -> SpeakerNamingEntry {
    var entry = SpeakerNamingEntry(
        id: UUID(),
        diarizerSpeakerId: "1",
        channel: .system,
        clipURL: URL(fileURLWithPath: "/nonexistent-call-app-hint/clip.wav"),
        sampleText: "Sample.",
        currentName: nil,
        matchSimilarity: nil,
        needsNaming: true,
        needsConfirmation: false
    )
    entry.callAppShownName = callAppName
    return entry
}

private func callAppHintProfile(id: UUID) -> SpeakerProfile {
    SpeakerProfile(
        id: id,
        displayName: nil,
        nameSource: nil,
        embedding: [0.1, 0.2, 0.3],
        firstSeen: Date(timeIntervalSinceReferenceDate: 0),
        lastSeen: Date(timeIntervalSinceReferenceDate: 10),
        callCount: 1,
        confidence: 0.8,
        disputeCount: 0
    )
}
