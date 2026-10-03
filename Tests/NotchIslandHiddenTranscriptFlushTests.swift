import Foundation

func testNotchIslandHiddenTranscriptFlush() {
    runSuite("A closed drop-down's live transcript catches up at most every 5 s") {
        func flushes(now: TimeInterval, last: TimeInterval?, trim: Int = 0, rendered: Int = 0) -> Bool {
            NotchIslandPresentation.flushesHiddenTranscript(
                now: now, lastFlush: last, trimGeneration: trim, renderedTrimGeneration: rendered
            )
        }
        assertTrue(flushes(now: 100, last: nil), "the first hidden update catches up")
        assertFalse(flushes(now: 4.9, last: 0), "an update under 5 s after the last catch-up waits")
        assertTrue(flushes(now: 5, last: 0), "an update 5 s after the last catch-up applies")
        assertTrue(flushes(now: 600, last: 0), "a long quiet stretch catches up on the next update")
    }

    runSuite("A closed drop-down leaves a trimmed transcript's rebuild for the open") {
        assertFalse(
            NotchIslandPresentation.flushesHiddenTranscript(now: 100, lastFlush: nil, trimGeneration: 1, renderedTrimGeneration: 0),
            "a trim rebuild waits for the open even on the first update"
        )
        assertFalse(
            NotchIslandPresentation.flushesHiddenTranscript(now: 100, lastFlush: 0, trimGeneration: 2, renderedTrimGeneration: 1),
            "a trim rebuild waits for the open however long it has been"
        )
    }
}
