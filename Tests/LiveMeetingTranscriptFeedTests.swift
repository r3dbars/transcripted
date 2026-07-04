import Foundation

@MainActor
func testLiveMeetingTranscriptFeed() async {
    func entry(
        source: LiveMeetingCodexSource,
        text: String,
        isFinal: Bool,
        at seconds: TimeInterval = 1
    ) -> LiveMeetingCodexTranscriptEntry {
        LiveMeetingCodexTranscriptEntry(
            source: source,
            text: text,
            timestampSeconds: seconds,
            createdAt: Date(timeIntervalSince1970: seconds),
            isFinal: isFinal
        )
    }

    runSuite("LiveMeetingTranscriptFeed — begin/live phase transitions") {
        let feed = LiveMeetingTranscriptFeed()
        assertEqual(feed.phase, .idle, "a fresh feed starts idle")

        feed.beginStarting()
        assertEqual(feed.phase, .starting)

        feed.markLive()
        assertEqual(feed.phase, .live)
    }

    runSuite("LiveMeetingTranscriptFeed — markLive does not revive deferred or failed phases") {
        let feed = LiveMeetingTranscriptFeed()
        feed.beginDeferred(note: "late join")
        feed.markLive()
        assertEqual(feed.phase, .deferred("late join"), "a deferred session has no live ASR to go live")

        feed.markFailed(note: "asr died")
        feed.markLive()
        assertEqual(feed.phase, .failed("asr died"), "failure is terminal for this recording")
    }

    runSuite("LiveMeetingTranscriptFeed — sidecar append recovery restores live phase") {
        let feed = LiveMeetingTranscriptFeed()
        feed.beginStarting()
        feed.markLive()
        let note = "Microphone live sidecar stopped updating. The final transcript still saves normally."
        feed.markFailed(note: note)
        feed.recoverFromSidecarAppendFailure(note: note)
        assertEqual(feed.phase, .live, "append recovery should clear the drawer failure")

        feed.markFailed(note: "Microphone live transcription stopped. The final transcript still saves normally.")
        feed.recoverFromSidecarAppendFailure(note: note)
        assertEqual(
            feed.phase,
            .failed("Microphone live transcription stopped. The final transcript still saves normally."),
            "append recovery should not clear unrelated ASR failures"
        )
    }

    runSuite("LiveMeetingTranscriptFeed — partials replace per source, finals accumulate") {
        let feed = LiveMeetingTranscriptFeed()
        feed.beginStarting()
        feed.markLive()

        feed.ingest(entry(source: .microphone, text: "hel", isFinal: false))
        feed.ingest(entry(source: .microphone, text: "hello eve", isFinal: false))
        feed.ingest(entry(source: .system, text: "hi th", isFinal: false))
        assertEqual(feed.finalEntries.count, 0)
        assertEqual(
            feed.partialEntries[.microphone]?.text, "hello eve",
            "a newer mic partial should replace the older one instead of stacking"
        )
        assertEqual(feed.partialEntries[.system]?.text, "hi th")

        feed.ingest(entry(source: .microphone, text: "hello everyone", isFinal: true))
        assertEqual(feed.finalEntries.map(\.text), ["hello everyone"])
        assertNil(
            feed.partialEntries[.microphone],
            "a final line should clear that source's pending partial"
        )
        assertEqual(
            feed.partialEntries[.system]?.text, "hi th",
            "the other source's partial should survive"
        )
    }

    runSuite("LiveMeetingTranscriptFeed — final entries stay capped") {
        let feed = LiveMeetingTranscriptFeed()
        feed.beginStarting()
        feed.markLive()

        let overflow = LiveMeetingTranscriptFeed.maxFinalEntries + 5
        for index in 0..<overflow {
            feed.ingest(entry(source: .microphone, text: "line \(index)", isFinal: true, at: TimeInterval(index)))
        }
        assertEqual(feed.finalEntries.count, LiveMeetingTranscriptFeed.maxFinalEntries)
        assertEqual(
            feed.finalEntries.first?.text, "line 5",
            "the oldest finals should drop once the cap is reached"
        )
    }

    runSuite("LiveMeetingTranscriptFeed — entries are ignored when idle or stopped") {
        let feed = LiveMeetingTranscriptFeed()
        feed.ingest(entry(source: .microphone, text: "ghost", isFinal: true))
        assertEqual(feed.finalEntries.count, 0, "an idle feed should not accept entries")

        feed.beginStarting()
        feed.markLive()
        feed.ingest(entry(source: .microphone, text: "kept", isFinal: true))
        feed.ingest(entry(source: .system, text: "pending", isFinal: false))
        feed.finish()
        assertEqual(feed.phase, .stopped)
        assertEqual(feed.finalEntries.map(\.text), ["kept"], "finals stay readable after stop")
        assertTrue(feed.partialEntries.isEmpty, "stopping clears provisional partials")

        feed.ingest(entry(source: .microphone, text: "late", isFinal: true))
        assertEqual(feed.finalEntries.map(\.text), ["kept"], "a stopped feed should not accept entries")
    }

    runSuite("LiveMeetingTranscriptFeed — begin and reset clear prior content") {
        let feed = LiveMeetingTranscriptFeed()
        feed.beginStarting()
        feed.markLive()
        feed.ingest(entry(source: .microphone, text: "old", isFinal: true))

        feed.beginStarting()
        assertEqual(feed.finalEntries.count, 0, "a new recording starts with a clean drawer")

        feed.markLive()
        feed.ingest(entry(source: .microphone, text: "new", isFinal: true))
        feed.reset()
        assertEqual(feed.phase, .idle)
        assertEqual(feed.finalEntries.count, 0)
        assertTrue(feed.partialEntries.isEmpty)
    }
}
