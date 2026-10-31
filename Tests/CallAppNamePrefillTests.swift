import Foundation

func testCallAppNamePrefill() {
    typealias Policy = NotchIslandSpeakerReviewPolicy

    runSuite("An unnamed voice's box fills with the call app's name, ahead of the calendar 1:1 name") {
        let entry = callAppPrefillEntry(callAppName: "Rina Okafor")
        assertEqual(
            Policy.prefillName(for: entry, oneOnOneName: "Tomás Vidal"),
            Policy.Prefill(name: "Rina Okafor", source: .callApp),
            "the name the call app showed wins over the calendar invitee"
        )
        assertEqual(
            Policy.prefillName(for: callAppPrefillEntry(callAppName: "  Rina Okafor \n")),
            Policy.Prefill(name: "Rina Okafor", source: .callApp),
            "a call-app name is trimmed"
        )
        assertEqual(Policy.prefillNote(for: .callApp), "From the call", "the line under it says where it came from")
    }

    runSuite("Without a call-app name the calendar 1:1 name still fills in, and with neither nothing does") {
        assertEqual(
            Policy.prefillName(for: callAppPrefillEntry(callAppName: nil), oneOnOneName: "Tomás Vidal"),
            Policy.Prefill(name: "Tomás Vidal", source: .calendar)
        )
        assertEqual(
            Policy.prefillName(for: callAppPrefillEntry(callAppName: "   "), oneOnOneName: "Tomás Vidal"),
            Policy.Prefill(name: "Tomás Vidal", source: .calendar),
            "a blank call-app name is no name"
        )
        assertEqual(Policy.prefillNote(for: .calendar), Policy.prefillNote, "the calendar keeps its own note")
        assertNil(Policy.prefillName(for: callAppPrefillEntry(callAppName: nil)), "nothing to fill in")
        assertNil(Policy.prefillName(for: callAppPrefillEntry(callAppName: nil), oneOnOneName: "  "))
    }

    runSuite("A call-app name never replaces what someone typed") {
        let entry = callAppPrefillEntry(callAppName: "Rina Okafor")
        assertNil(Policy.prefillName(for: entry, oneOnOneName: "Tomás Vidal", typed: "Ri"), "typed text stays")
        assertEqual(
            Policy.prefillName(for: entry, typed: "   ")?.name, "Rina Okafor",
            "whitespace only is an empty box"
        )
    }

    runSuite("A call-app name only fills a voice that's asked for a name and has no voiceprint guess") {
        assertNil(
            Policy.prefillName(for: callAppPrefillEntry(callAppName: "Rina Okafor", currentName: "Ana Lima", needsNaming: false, needsConfirmation: true)),
            "a voiceprint guess (Is this Ana Lima?) keeps its own question"
        )
        assertNil(
            Policy.prefillName(for: callAppPrefillEntry(callAppName: "Rina Okafor", needsNaming: false)),
            "a voice not up for naming gets nothing"
        )
    }

    runSuite("The Speakers row fills its box from the call app only when it has nothing better") {
        assertEqual(
            Policy.reviewRowDraft(currentDraft: "", savedName: nil, callAppSuggestedName: "Rina Okafor"),
            Policy.RowDraft(name: "Rina Okafor", isFromCall: true)
        )
        assertEqual(
            Policy.reviewRowDraft(currentDraft: "", savedName: "Ana Lima", callAppSuggestedName: "Rina Okafor"),
            Policy.RowDraft(name: "Ana Lima", isFromCall: false),
            "a saved name still fills the box, as before"
        )
        assertNil(
            Policy.reviewRowDraft(currentDraft: "Tom", savedName: nil, callAppSuggestedName: "Rina Okafor"),
            "a draft in progress is left alone"
        )
        assertNil(Policy.reviewRowDraft(currentDraft: "", savedName: nil, callAppSuggestedName: nil))
    }

    runSuite("Who spoke? reads a call-app name and still lists that voice as pending") {
        let callId = UUID()
        let legacyId = UUID()
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
            name: "Rina Okafor"
            confidence: medium
            source: db_pending
            name_source: call_app
          - id: "2"
            channel: system
            db_id: "\(legacyId.uuidString)"
            name: "Speaker 2"
            confidence: unknown
            source: db_pending
        ---

        # Planning sync

        ## Transcript

        **00:01** [System/Rina Okafor]
        Let's start with the budget.

        **00:09** [System/Speaker 2]
        Sounds good to me.
        """
        let url = URL(fileURLWithPath: "/nonexistent-call-app-prefill/Planning_sync.md")
        // No profile clips: #2273 reads the quote from a clip sidecar when a
        // clip URL is present, so a fake path would hide the labeled line.
        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: url,
            profilesById: [
                callId: callAppPrefillProfile(id: callId),
                legacyId: callAppPrefillProfile(id: legacyId),
            ],
            clipURLsByProfileID: [:]
        )
        let named = items.first { $0.speakerId == callId }
        let legacy = items.first { $0.speakerId == legacyId }
        assertEqual(items.count, 2, "a db_pending voice with a real call-app name is still pending")
        assertEqual(named?.callAppSuggestedName, "Rina Okafor", "name_source call_app exposes the name as a suggestion")
        assertEqual(named?.sampleText, "Let's start with the budget.", "the sample still comes from its labeled line")
        assertNil(legacy?.callAppSuggestedName, "a legacy Speaker N voice has no suggestion")
        assertEqual(legacy?.sourceName, "Speaker 2", "a legacy voice reads exactly as before")
        assertEqual(legacy?.sampleText, "Sounds good to me.")
        let whoSpoke = SpeakerReviewQueueScanner.groupedByMeeting(
            SpeakerReviewQueueScanner.groupedByVoice(items)
        )
        let cardVoice = whoSpoke.first?.voices.first { $0.id == callId }
        assertEqual(
            cardVoice?.representative.callAppSuggestedName, "Rina Okafor",
            "the Speakers Who spoke? card still sees the call-app name"
        )
    }

    runSuite("A real name without name_source is not treated as a call-app suggestion") {
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
            transcriptURL: URL(fileURLWithPath: "/nonexistent-call-app-prefill/Hand_edited.md"),
            profilesById: [id: callAppPrefillProfile(id: id)],
            clipURLsByProfileID: [:]
        )
        assertEqual(items.count, 1, "still pending, as today")
        assertNil(items.first?.callAppSuggestedName, "no name_source, no suggestion")
        assertEqual(items.first?.sourceName, "Rina Okafor")
    }
}

private func callAppPrefillEntry(
    callAppName: String?,
    currentName: String? = nil,
    needsNaming: Bool = true,
    needsConfirmation: Bool = false
) -> SpeakerNamingEntry {
    var entry = SpeakerNamingEntry(
        id: UUID(),
        diarizerSpeakerId: "1",
        channel: .system,
        clipURL: URL(fileURLWithPath: "/nonexistent-call-app-prefill/clip.wav"),
        sampleText: "Sample.",
        currentName: currentName,
        matchSimilarity: nil,
        needsNaming: needsNaming,
        needsConfirmation: needsConfirmation
    )
    entry.callAppSuggestedName = callAppName
    return entry
}

private func callAppPrefillProfile(id: UUID) -> SpeakerProfile {
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
