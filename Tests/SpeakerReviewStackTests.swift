import Foundation

// Promises for the "Review and name these people" stack on the Speakers page:
// only the top card is drawn, so every voice not on it must stay reachable from
// Everyone, a search must reach any voice, and Home must not count skipped calls.
func testSpeakerReviewStack() {
    runSuite("Voices on review cards below the top one stay listed in Everyone") {
        let fixture = ReviewStackFixture()
        let stack = fixture.stack()

        assertEqual(stack.calls.map(\.meetingTitle), ["Design sync", "Standup", "Retro"], "newest call is the open card")
        let everyone = stack.directory(fixture.profiles, isSearching: false).map(\.id)
        assertEqual(
            everyone,
            [fixture.bea, fixture.cal, fixture.dee, fixture.named],
            "only the open card's voice is left out; voices waiting on later cards stay in Everyone"
        )
        assertTrue(stack.isWaitingForReview(fixture.profile(fixture.bea)), "a voice on a later card is badged as waiting")
        assertTrue(stack.isWaitingForReview(fixture.profile(fixture.dee)), "so is one on the last card")
        assertFalse(stack.isWaitingForReview(fixture.profile(fixture.named)), "a named voice is never waiting")
    }

    runSuite("A search reaches a voice even when it sits on the open review card") {
        let fixture = ReviewStackFixture()
        let stack = fixture.stack()
        let matches = [fixture.profile(fixture.ada)]

        assertEqual(stack.directory(matches, isSearching: true).map(\.id), [fixture.ada], "search results are never hidden")
        assertTrue(stack.directory(matches, isSearching: false).isEmpty, "without a search the open card's voice sits in the card, not the list")
    }

    runSuite("Home counts only voices on calls that were not skipped") {
        let fixture = ReviewStackFixture()
        assertEqual(fixture.stack().voiceCount, 4, "four unnamed voices across three calls")

        let skipped = fixture.stack(skipping: [fixture.standupKey])
        assertEqual(skipped.voiceCount, 2, "skipping the two-voice call drops its voices from Home's count")
        assertEqual(skipped.calls.map(\.meetingTitle), ["Design sync", "Retro"], "the skipped call has no card")
        assertFalse(skipped.isWaitingForReview(fixture.profile(fixture.bea)), "a skipped call's voice is no longer waiting")
        assertTrue(
            skipped.directory(fixture.profiles, isSearching: false).map(\.id).contains(fixture.bea),
            "a skipped call's voice stays in Everyone"
        )

        let everythingSkipped = fixture.stack(skipping: [fixture.designKey, fixture.standupKey, fixture.retroKey])
        assertEqual(everythingSkipped.voiceCount, 0, "skip every call and Home stops asking")
        assertTrue(everythingSkipped.calls.isEmpty)
    }

    runSuite("Later moves a call to the back and the next call's voices take the open card") {
        let fixture = ReviewStackFixture()
        let stack = fixture.stack(later: [fixture.designKey])

        assertEqual(stack.calls.map(\.meetingTitle), ["Standup", "Retro", "Design sync"])
        assertEqual(
            stack.directory(fixture.profiles, isSearching: false).map(\.id),
            [fixture.ada, fixture.dee, fixture.named],
            "the new open card's voices leave Everyone and the call sent back returns to it"
        )
        assertTrue(stack.isWaitingForReview(fixture.profile(fixture.ada)))
        assertEqual(stack.voiceCount, 4, "Later doesn't change how many voices need a name")

        let twice = fixture.stack(later: [fixture.designKey, fixture.standupKey])
        assertEqual(twice.calls.map(\.meetingTitle), ["Retro", "Design sync", "Standup"], "calls sent back line up in the order sent")
    }

    runSuite("A voice already named never leaves Everyone, even on the open card") {
        let fixture = ReviewStackFixture()
        let renamedAda = makeStackProfile(id: fixture.ada, name: "Ada")
        let stack = fixture.stack()

        assertEqual(stack.directory([renamedAda], isSearching: false).map(\.id), [fixture.ada])
        assertFalse(stack.isWaitingForReview(renamedAda))
    }

    runSuite("Renaming a voice from Everyone names it the way its review card would") {
        let fixture = ReviewStackFixture()
        let queue = fixture.queue

        assertEqual(
            SpeakerReviewStack.reviewItemForRename(of: fixture.profile(fixture.dee), in: queue)?.speakerId,
            fixture.dee,
            "a voice waiting on a later card is named through its review row"
        )
        assertEqual(
            SpeakerReviewStack.reviewItemForRename(of: fixture.profile(fixture.bea), in: queue)?.meetingTitle,
            "Standup",
            "so is a voice whose call was skipped; skipping hides the card, not the unnamed transcript"
        )
        assertNil(
            SpeakerReviewStack.reviewItemForRename(of: makeStackProfile(id: fixture.dee, name: "Dee"), in: queue),
            "a voice that already has a name gets a plain rename"
        )
        assertNil(
            SpeakerReviewStack.reviewItemForRename(of: fixture.profile(fixture.named), in: queue),
            "a named person on no card gets a plain rename"
        )
        assertNil(
            SpeakerReviewStack.reviewItemForRename(of: makeStackProfile(id: UUID(), name: nil), in: queue),
            "an unnamed voice with no saved review row gets a plain rename"
        )
    }

    runSuite("With nothing to review Everyone lists every voice") {
        let fixture = ReviewStackFixture()
        let stack = SpeakerReviewStack.empty

        assertEqual(stack.directory(fixture.profiles, isSearching: false).count, fixture.profiles.count)
        assertEqual(stack.voiceCount, 0)
        assertTrue(stack.calls.isEmpty)
    }
}

/// Three calls, newest first: Design sync (Ada), Standup (Bea, Cal), Retro
/// (Dee). Plus one named person who is on no card.
private struct ReviewStackFixture {
    let ada = UUID()
    let bea = UUID()
    let cal = UUID()
    let dee = UUID()
    let named = UUID()
    private let designId = UUID()
    private let standupId = UUID()
    private let retroId = UUID()

    var designKey: String { designId.uuidString }
    var standupKey: String { standupId.uuidString }
    var retroKey: String { retroId.uuidString }

    var profiles: [SpeakerProfile] {
        [ada, bea, cal, dee].map { makeStackProfile(id: $0, name: nil) } + [makeStackProfile(id: named, name: "Priya")]
    }

    func profile(_ id: UUID) -> SpeakerProfile {
        profiles.first { $0.id == id }!
    }

    func stack(skipping skipped: Set<String> = [], later: [String] = []) -> SpeakerReviewStack {
        SpeakerReviewStack(voices: voices, skippedCallKeys: skipped, laterCallKeys: later)
    }

    var queue: [SpeakerPendingReviewItem] {
        [
            item(ada, call: designId, title: "Design sync", day: 3),
            item(bea, call: standupId, title: "Standup", day: 2),
            item(cal, call: standupId, title: "Standup", day: 2),
            item(dee, call: retroId, title: "Retro", day: 1),
        ]
    }

    private var voices: [SpeakerPendingVoiceGroup] {
        SpeakerReviewQueueScanner.groupedByVoice(queue)
    }

    private func item(_ speakerId: UUID, call: UUID, title: String, day: Double) -> SpeakerPendingReviewItem {
        let date = Date(timeIntervalSinceReferenceDate: day * 86_400)
        return SpeakerPendingReviewItem(
            speakerId: speakerId,
            diarizerSpeakerId: "1",
            channel: .system,
            transcriptURL: URL(fileURLWithPath: "/tmp/\(title).md"),
            transcriptId: call,
            meetingTitle: title,
            recordedAt: date,
            fallbackDate: date,
            sampleText: nil,
            clipURL: nil,
            retainedAudioSample: nil,
            callCount: 1,
            profile: makeStackProfile(id: speakerId, name: nil),
            sourceName: "Speaker"
        )
    }
}

private func makeStackProfile(id: UUID, name: String?) -> SpeakerProfile {
    SpeakerProfile(
        id: id,
        displayName: name,
        nameSource: name == nil ? nil : NameSource.userManual,
        embedding: [0.1, 0.2, 0.3],
        firstSeen: Date(timeIntervalSinceReferenceDate: 0),
        lastSeen: Date(timeIntervalSinceReferenceDate: 10),
        callCount: 1,
        confidence: 0.8,
        disputeCount: 0
    )
}
