import Foundation

func testSpeakerReviewSession() {
    runSuite("A naming save belongs only to the review visit that submitted it") {
        let fixture = ReviewSessionFixture()
        let call = fixture.stack.calls[0]
        var session = SpeakerReviewSession()
        let closedToken = session.visitToken
        assertFalse(session.record(fixture.savedVoice, on: call, visit: closedToken))
        session.open()
        let submittedToken = session.visitToken
        session.close()
        assertFalse(session.record(fixture.savedVoice, on: call, visit: submittedToken))
        session.open()
        assertFalse(session.record(fixture.savedVoice, on: call, visit: submittedToken), "reopening the same call does not revive its old callback")
        assertTrue(session.record(fixture.savedVoice, on: call, visit: session.visitToken))
        assertEqual(session.namedVoices(on: call).map(\.name), ["Ada"])
    }

    runSuite("A saved voice stays on its card while the queue catches up") {
        let fixture = ReviewSessionFixture()
        let call = fixture.stack.calls[0]
        var session = SpeakerReviewSession()
        session.open()
        session.record(fixture.savedVoice, on: call, visit: session.visitToken)
        assertEqual(session.currentCall(in: fixture.stack.calls)?.id, call.id)
        assertTrue(session.pendingVoices(on: call, in: fixture.stack.calls).isEmpty, "the stale queue cannot render the saved voice as unnamed too")
        assertEqual(session.namedVoices(on: call).map(\.confirmedAfter), [3], "the session keeps the actual result, including a multi-meeting save")
        assertEqual(session.callCount(in: fixture.stack.calls), 2)
    }

    runSuite("A completed card stays visible without hiding the next call's voices") {
        let fixture = ReviewSessionFixture()
        let call = fixture.stack.calls[0]
        var session = SpeakerReviewSession()
        session.open()
        session.record(fixture.savedVoice, on: call, visit: session.visitToken)
        let refreshed = fixture.stack(skipping: [call.id])
        assertEqual(session.currentCall(in: refreshed.calls)?.id, call.id)
        assertEqual(session.callCount(in: refreshed.calls), 2, "the done card and waiting call both count")
        assertTrue(session.pendingVoices(on: call, in: refreshed.calls).isEmpty)
        assertEqual(refreshed.directory(fixture.profiles, isSearching: false, heldCallID: session.heldCall?.id).map(\.id), fixture.profiles.map(\.id))
    }

    runSuite("Next advances a finished review and rejects saves from its previous card") {
        let fixture = ReviewSessionFixture()
        let call = fixture.stack.calls[0]
        var session = SpeakerReviewSession()
        session.open()
        let submittedToken = session.visitToken
        session.record(fixture.savedVoice, on: call, visit: submittedToken)
        let refreshed = fixture.stack(skipping: [call.id])
        session.finish(call, total: session.callCount(in: refreshed.calls))
        assertTrue(session.isOpen)
        assertNil(session.heldCall)
        assertTrue(session.namedVoices(on: call).isEmpty)
        assertEqual(session.currentCall(in: refreshed.calls)?.id, fixture.secondCallID.uuidString)
        assertFalse(session.record(fixture.savedVoice, on: call, visit: submittedToken))
    }

    runSuite("Done closes the last finished call and clears its celebration") {
        let fixture = ReviewSessionFixture()
        let call = fixture.stack.calls[0]
        var session = SpeakerReviewSession()
        session.open()
        session.record(fixture.savedVoice, on: call, visit: session.visitToken)
        session.finish(call, total: session.callCount(in: []))
        assertFalse(session.isOpen)
        assertNil(session.currentCall(in: []))
        assertTrue(session.namedVoices.isEmpty)
        assertEqual(session.callCount(in: []), 0)
    }

    runSuite("Later drops the held card and moves its pending work behind the next call") {
        let fixture = ReviewSessionFixture()
        let call = fixture.stack.calls[0]
        var session = SpeakerReviewSession()
        session.open()
        let submittedToken = session.visitToken
        session.record(fixture.savedVoice, on: call, visit: submittedToken)
        session.leave(call)
        let later = fixture.stack(later: [call.id])
        assertTrue(session.isOpen)
        assertNil(session.heldCall)
        assertTrue(session.namedVoices(on: call).isEmpty)
        assertEqual(session.currentCall(in: later.calls)?.id, fixture.secondCallID.uuidString)
        assertEqual(later.calls.last?.id, call.id)
        assertEqual(session.callCount(in: later.calls), 2)
        assertFalse(session.record(fixture.savedVoice, on: call, visit: submittedToken))
        assertTrue(later.directory(fixture.profiles, isSearching: false, heldCallID: session.heldCall?.id).contains { $0.id == fixture.firstVoiceID })
    }

    runSuite("Skipping a call leaves its voice reachable and rejects its pending saves") {
        let fixture = ReviewSessionFixture()
        let call = fixture.stack.calls[0]
        var session = SpeakerReviewSession()
        session.open()
        let submittedToken = session.visitToken
        session.leave(call)
        let skipped = fixture.stack(skipping: [call.id])
        assertTrue(session.isOpen)
        assertEqual(session.currentCall(in: skipped.calls)?.id, fixture.secondCallID.uuidString)
        assertEqual(session.callCount(in: skipped.calls), 1)
        assertFalse(session.record(fixture.savedVoice, on: call, visit: submittedToken))
        assertTrue(skipped.directory(fixture.profiles, isSearching: false).contains { $0.id == fixture.firstVoiceID })
    }

    runSuite("Closing review clears saved rows and shows every voice in the directory") {
        let fixture = ReviewSessionFixture()
        let call = fixture.stack.calls[0]
        var session = SpeakerReviewSession()
        session.open()
        session.record(fixture.savedVoice, on: call, visit: session.visitToken)
        session.close()
        assertFalse(session.isOpen)
        assertNil(session.heldCall)
        assertTrue(session.namedVoices.isEmpty)
        assertEqual(fixture.stack.directory(fixture.profiles, isSearching: !session.isOpen, heldCallID: session.heldCall?.id).map(\.id), fixture.profiles.map(\.id))
        session.open()
        assertEqual(session.pendingVoices(on: call, in: fixture.stack.calls).map(\.id), [fixture.firstVoiceID])
    }
}

private struct ReviewSessionFixture {
    let firstCallID = UUID()
    let secondCallID = UUID()
    let firstVoiceID = UUID()
    let secondVoiceID = UUID()

    var savedVoice: SpeakerReviewNamedVoice {
        .init(voiceID: firstVoiceID, personID: firstVoiceID, name: "Ada", confirmedBefore: 0,
              confirmedAfter: 3, requiredMeetings: 5, isNewPerson: true, isTrusted: false)
    }

    var stack: SpeakerReviewStack { stack() }

    func stack(skipping: Set<String> = [], later: [String] = []) -> SpeakerReviewStack {
        let items = [item(voice: firstVoiceID, call: firstCallID, day: 2), item(voice: secondVoiceID, call: secondCallID, day: 1)]
        return SpeakerReviewStack(voices: SpeakerReviewQueueScanner.groupedByVoice(items), skippedCallKeys: skipping, laterCallKeys: later)
    }

    var profiles: [SpeakerProfile] { [profile(firstVoiceID), profile(secondVoiceID)] }

    private func profile(_ id: UUID) -> SpeakerProfile {
        .init(id: id, displayName: nil, nameSource: nil, embedding: [0.1, 0.2, 0.3],
              firstSeen: Date(timeIntervalSinceReferenceDate: 0), lastSeen: Date(timeIntervalSinceReferenceDate: 10),
              callCount: 1, confidence: 0.8, disputeCount: 0)
    }

    private func item(voice: UUID, call: UUID, day: Double) -> SpeakerPendingReviewItem {
        let date = Date(timeIntervalSinceReferenceDate: day * 86_400)
        return .init(speakerId: voice, diarizerSpeakerId: "1", channel: .system,
                     transcriptURL: URL(fileURLWithPath: "/tmp/speaker-review-session-fixture.md"), transcriptId: call,
                     meetingTitle: "Fixture call", recordedAt: date, fallbackDate: date,
                     sampleText: nil, clipURL: nil, retainedAudioSample: nil, callCount: 1,
                     profile: profile(voice), sourceName: "Speaker")
    }
}
