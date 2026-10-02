import Foundation

func testLiveMeetingTranscriptState() {
    runSuite("Live preview retains bounded sequenced text from both capture tracks") {
        var state = LiveMeetingTranscriptState(maximumSegments: 2, maximumCharacters: 100)
        state.append(text: "Mic words", startSeconds: 0, endSeconds: 4, source: .microphone)
        state.append(text: "Call words", startSeconds: 0, endSeconds: 4, source: .system)
        assertEqual(state.segments.map(\.source), [.microphone, .system])
        assertTrue(state.segments.allSatisfy(\.provisional))
        state.append(text: "More words", startSeconds: 4, endSeconds: 8, source: .microphone)
        assertEqual(state.segments.map(\.sequence), [2, 3])
        assertEqual(state.window(afterSequence: 2, limit: 1).map(\.text), ["More words"])
        assertEqual(state.window(afterSequence: 100, limit: 30).count, 0)
    }

    runSuite("Disabling sharing clears text while sequence remains monotonic") {
        var state = LiveMeetingTranscriptState(maximumCharacters: 20)
        state.append(text: String(repeating: "A", count: 200), startSeconds: 0, endSeconds: 1, source: .system)
        assertEqual(state.segments.first?.text.count, 20)
        state.clear()
        assertEqual(state.segments.count, 0)
        state.append(text: "new shared words", startSeconds: 2, endSeconds: 3, source: .system)
        assertEqual(state.segments.first?.sequence, 2)
        state.append(text: "another shared phrase", startSeconds: 3, endSeconds: 4, source: .system)
        assertTrue(state.segments.reduce(0, { $0 + $1.text.count }) <= 20)
    }

    runSuite("Only identical same-track overlapping prefixes are removed") {
        var state = LiveMeetingTranscriptState()
        state.append(text: "Please review the launch plan.", startSeconds: 0, endSeconds: 4, source: .system)
        state.append(text: "Launch plan, then send it tomorrow.", startSeconds: 3.5, endSeconds: 7.5, source: .system)
        assertEqual(state.segments.last?.text, "then send it tomorrow.")
        state.append(text: "send it tomorrow.", startSeconds: 3.5, endSeconds: 7.5, source: .microphone)
        assertEqual(state.segments.last?.text, "send it tomorrow.", "another source is never deduplicated")
        state.append(text: "Send it tomorrow. Please do.", startSeconds: 8, endSeconds: 12, source: .system)
        assertEqual(state.segments.last?.text, "Send it tomorrow. Please do.", "a later actual repetition must survive")
        var replies = LiveMeetingTranscriptState()
        replies.append(text: "yes", startSeconds: 0, endSeconds: 4, source: .system)
        replies.append(text: "yes", startSeconds: 3.5, endSeconds: 7.5, source: .system)
        assertEqual(replies.segments.count, 2, "short repeated replies are ambiguous and stay provisional")
    }

    runSuite("Empty and invalid transcript observations cannot become text") {
        var state = LiveMeetingTranscriptState()
        state.append(text: "  \n", startSeconds: 0, endSeconds: 1, source: .system)
        state.append(text: "invalid", startSeconds: .nan, endSeconds: 1, source: .system)
        assertEqual(state.latestSequence, 0)
    }

    runSuite("Both live tracks keep independent four-second windows with half-second overlap") {
        let inbox = LiveMeetingAudioInbox()
        let session = UUID()
        inbox.begin(sessionID: session, origin: 100, previewEpoch: 1)
        inbox.append(samples: [Float](repeating: 0.1, count: 64_000), source: .microphone, capturedAt: 104, expectedEpoch: 1)
        inbox.append(samples: [Float](repeating: 0.2, count: 64_000), source: .system, capturedAt: 104, expectedEpoch: 1)
        let mic = inbox.take()!
        let system = inbox.take()!
        assertEqual(mic.sessionID, session)
        assertEqual(mic.source, .microphone)
        assertEqual(system.source, .system)
        assertEqual(mic.startSeconds, 0)
        assertEqual(system.endSeconds, 4)
        inbox.append(samples: [Float](repeating: 0.3, count: 56_000), source: .microphone, capturedAt: 107.5, expectedEpoch: 1)
        let next = inbox.take()!
        assertEqual(next.startSeconds, 3.5)
        assertEqual(next.endSeconds, 7.5)
        assertEqual(next.samples.first, 0.1)
        assertEqual(next.samples.last, 0.3)
        inbox.finish()
        assertNil(inbox.take(), "an overlap-only tail must not repeat speech at Stop")
    }

    runSuite("Slow live inference drops old preview windows and stays bounded") {
        let inbox = LiveMeetingAudioInbox(windowSamples: 16_000, overlapSamples: 0, maximumWindows: 2)
        inbox.begin(sessionID: UUID(), origin: 0, previewEpoch: 1)
        inbox.append(samples: [Float](repeating: 0.2, count: 48_000), source: .system, capturedAt: 3, expectedEpoch: 1)
        assertEqual(inbox.pendingWindowCount, 2)
        assertEqual(inbox.dropCount, 1)
        assertEqual(inbox.take()?.startSeconds, 1)
        assertEqual(inbox.take()?.startSeconds, 2)
        inbox.cancel()
        inbox.append(samples: [Float](repeating: 0.2, count: 32_000), source: .system, capturedAt: 5, expectedEpoch: 1)
        assertNil(inbox.take(), "disabled sharing must not retain new audio")
    }

    runSuite("New calls discard old pending audio and stop flushes a partial phrase") {
        let inbox = LiveMeetingAudioInbox(windowSamples: 16_000, overlapSamples: 0)
        inbox.begin(sessionID: UUID(), origin: 0, previewEpoch: 1)
        inbox.append(samples: [Float](repeating: 0.2, count: 16_000), source: .microphone, capturedAt: 1, expectedEpoch: 1)
        let replacement = UUID()
        inbox.begin(sessionID: replacement, origin: 10, previewEpoch: 1)
        assertNil(inbox.take())
        inbox.append(samples: [Float](repeating: 0.3, count: 12_000), source: .system, capturedAt: 10.75, expectedEpoch: 1)
        assertNil(inbox.take())
        inbox.finish()
        let partial = inbox.take()!
        assertEqual(partial.sessionID, replacement)
        assertEqual(partial.source, .system)
        assertEqual(partial.endSeconds, 0.75)
    }

    runSuite("In-flight conversion cannot adopt a renewed sharing lease or another call") {
        let inbox = LiveMeetingAudioInbox(windowSamples: 16_000, overlapSamples: 0)
        let session = UUID()
        inbox.begin(sessionID: session, origin: 0, previewEpoch: 10)
        // A producer admitted under epoch 10 is still converting when sharing
        // is revoked. Re-enabling the same call must reject its eventual result.
        inbox.cancel()
        inbox.begin(sessionID: session, origin: 0, previewEpoch: 11)
        inbox.append(samples: [Float](repeating: 0.1, count: 16_000), source: .system,
            capturedAt: 1, expectedEpoch: 10)
        assertTrue(inbox.take() == nil, "old unshared audio cannot enter a renewed sharing period")
        inbox.append(samples: [Float](repeating: 0.2, count: 16_000), source: .system,
            capturedAt: 2, expectedEpoch: 11)
        assertEqual(inbox.take()?.samples.first, 0.2, "the current sharing lease remains usable")
        let replacement = UUID()
        inbox.begin(sessionID: replacement, origin: 10, previewEpoch: 12)
        inbox.append(samples: [Float](repeating: 0.3, count: 16_000), source: .microphone,
            capturedAt: 11, expectedEpoch: 11)
        assertTrue(inbox.take() == nil, "old call audio cannot be labeled with the new call's identity")
        inbox.append(samples: [Float](repeating: 0.4, count: 16_000), source: .microphone,
            capturedAt: 11, expectedEpoch: 12)
        assertEqual(inbox.take()?.sessionID, replacement)
    }
}
