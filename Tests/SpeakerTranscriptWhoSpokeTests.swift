import Foundation

/// Promises of a meeting's "Who spoke?" card built from its transcript (the
/// Meetings card's "Who spoke?" when the review queue has nothing for it):
///   - every voice in the transcript is on it once; a voice still called
///     "Speaker 2" is asked, a named one is shown by name;
///   - answers save as the same transcript assignments the quick fix makes:
///     a typed name renames, a saved person picked links to them, the mic's
///     You links to the saved You, and nothing unchanged is saved;
///   - "Not a person" has no transcript meaning, so it saves nothing.
func testSpeakerTranscriptWhoSpoke() {
    typealias Policy = SpeakerTranscriptWhoSpokePolicy

    let danaID = UUID(uuidString: "00000000-0000-0000-0000-0000000000D1")!
    let ownerID = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
    let jordanID = UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")!

    let dana = HomeMeetingSpeakerIdentity(
        displayName: "Dana Ito", rawLabel: "Dana Ito", channel: .system,
        diarizerSpeakerID: "0", persistentSpeakerID: danaID
    )
    let unnamed = HomeMeetingSpeakerIdentity(
        displayName: "Speaker 2", rawLabel: "Speaker 2", channel: .system,
        diarizerSpeakerID: "2", persistentSpeakerID: nil
    )
    let micVoice = HomeMeetingSpeakerIdentity(
        displayName: "Speaker 1", rawLabel: "Speaker 1", channel: .mic,
        diarizerSpeakerID: "1", persistentSpeakerID: nil
    )
    let lines = [
        HomeMeetingTranscriptLine(time: "0:01", identity: dana, text: "Let's start with the roadmap."),
        HomeMeetingTranscriptLine(time: "0:05", identity: unnamed, text: "I can take the design review."),
        HomeMeetingTranscriptLine(time: "0:09", identity: dana, text: "Great, thanks."),
        HomeMeetingTranscriptLine(time: "0:12", identity: micVoice, text: "Sounds good to me."),
    ]

    runSuite("Every voice in the transcript is on the card once, asked only while it has no name") {
        let voices = Policy.voices(in: lines)
        assertEqual(voices.map(\.identity.displayName), ["Dana Ito", "Speaker 2", "Speaker 1"], "first heard first, once each")
        assertEqual(voices.map(\.asks), [false, true, true])
        assertTrue(Policy.isUnnamed("Speaker"), "a bare Speaker label is unnamed")
        assertTrue(Policy.isUnnamed("  "), "an empty label is unnamed")
        assertTrue(Policy.isUnnamed("Unknown voice"))
        assertFalse(Policy.isUnnamed("Speakerman"), "a real name that starts with Speaker is a name")
        assertFalse(Policy.isUnnamed("You"))
    }

    runSuite("Answers save as the quick fix's transcript assignments") {
        let unnamedRow = UUID()
        let micRow = UUID()
        let identities = [danaID: dana, unnamedRow: unnamed, micRow: micVoice]
        let updates = [
            SpeakerReviewUpdate(persistentSpeakerId: unnamedRow, diarizerSpeakerId: "2", newName: "Maya Chen", action: .named),
            SpeakerReviewUpdate(persistentSpeakerId: micRow, diarizerSpeakerId: "1", channel: .mic, newName: "You", action: .collapsedToMe),
            SpeakerReviewUpdate(persistentSpeakerId: danaID, diarizerSpeakerId: "0", newName: "", action: .merged(targetProfileId: jordanID)),
        ]
        let assignments = Policy.assignments(
            for: updates,
            identities: identities,
            savedNames: [jordanID: "Jordan Lee", ownerID: "You"],
            ownerID: ownerID
        )
        assertEqual(assignments, [
            HomeMeetingSpeakerAssignment(identity: unnamed, newName: "Maya Chen", targetProfileID: nil),
            HomeMeetingSpeakerAssignment(identity: micVoice, newName: "You", targetProfileID: ownerID),
            HomeMeetingSpeakerAssignment(identity: dana, newName: "Jordan Lee", targetProfileID: jordanID),
        ], "a typed name renames, the mic's You links to the saved You, a pick keeps that person's name")
    }

    runSuite("Nothing unchanged, unknown or thrown away is saved") {
        let unnamedRow = UUID()
        let identities = [danaID: dana, unnamedRow: unnamed]
        let assignments = Policy.assignments(
            for: [
                SpeakerReviewUpdate(persistentSpeakerId: danaID, diarizerSpeakerId: "0", newName: "Dana Ito", action: .corrected),
                SpeakerReviewUpdate(persistentSpeakerId: danaID, diarizerSpeakerId: "0", newName: "Dana", action: .merged(targetProfileId: danaID)),
                SpeakerReviewUpdate(persistentSpeakerId: unnamedRow, diarizerSpeakerId: "2", newName: "Speaker 2", action: .discardedFromDatabase),
                SpeakerReviewUpdate(persistentSpeakerId: UUID(), diarizerSpeakerId: "9", newName: "Ghost", action: .named),
            ],
            identities: identities,
            savedNames: [:],
            ownerID: nil
        )
        assertEqual(assignments, [], "the same name, a repeat for the same voice, Not a person and a row the card never had")

        let renamedSelf = Policy.assignments(
            for: [SpeakerReviewUpdate(persistentSpeakerId: danaID, diarizerSpeakerId: "0", newName: "Dana I.", action: .merged(targetProfileId: danaID))],
            identities: identities,
            savedNames: [:],
            ownerID: nil
        )
        assertEqual(renamedSelf, [HomeMeetingSpeakerAssignment(identity: dana, newName: "Dana I.", targetProfileID: nil)],
                    "picking the voice's own person with a new spelling is a rename")
    }
}
