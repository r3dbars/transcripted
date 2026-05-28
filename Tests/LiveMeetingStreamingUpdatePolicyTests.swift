import Foundation

func testLiveMeetingStreamingUpdatePolicy() {
    runSuite("LiveMeetingStreamingUpdatePolicy - skips empty and duplicate updates") {
        let now = Date(timeIntervalSince1970: 1_765_994_400)
        let state = LiveMeetingStreamingUpdateState(
            lastText: "hello world",
            lastAppendedAt: now.addingTimeInterval(-5)
        )

        assertEqual(
            LiveMeetingStreamingUpdatePolicy.normalizedText(" hello\nworld "),
            "hello world",
            "normalization should collapse whitespace"
        )
        assertFalse(
            LiveMeetingStreamingUpdatePolicy.shouldAppend(
                text: "   ",
                isFinal: false,
                now: now,
                state: state
            ),
            "empty updates should be ignored"
        )
        assertFalse(
            LiveMeetingStreamingUpdatePolicy.shouldAppend(
                text: "hello world",
                isFinal: true,
                now: now,
                state: state
            ),
            "duplicate updates should be ignored"
        )
    }

    runSuite("LiveMeetingStreamingUpdatePolicy - throttles partials but always accepts new final text") {
        let now = Date(timeIntervalSince1970: 1_765_994_400)
        let recentState = LiveMeetingStreamingUpdateState(
            lastText: "hello",
            lastAppendedAt: now.addingTimeInterval(-0.5)
        )

        assertFalse(
            LiveMeetingStreamingUpdatePolicy.shouldAppend(
                text: "hello there",
                isFinal: false,
                now: now,
                state: recentState,
                partialAppendInterval: 2.0
            ),
            "partial updates should be throttled"
        )
        assertTrue(
            LiveMeetingStreamingUpdatePolicy.shouldAppend(
                text: "hello there",
                isFinal: true,
                now: now,
                state: recentState,
                partialAppendInterval: 2.0
            ),
            "new final text should bypass partial throttling"
        )
        assertTrue(
            LiveMeetingStreamingUpdatePolicy.shouldAppend(
                text: "hello there again",
                isFinal: false,
                now: now,
                state: LiveMeetingStreamingUpdateState(
                    lastText: "hello there",
                    lastAppendedAt: now.addingTimeInterval(-3)
                ),
                partialAppendInterval: 2.0
            ),
            "partial updates should append after the throttle window"
        )
    }
}
