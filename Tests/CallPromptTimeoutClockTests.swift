import Foundation

func testCallPromptTimeoutClock() {
    let t0 = Date(timeIntervalSince1970: 1_000_000)

    runSuite("A call prompt's timeout runs its full length once shown") {
        var clock = CallPromptTimeoutClock()
        assertEqual(clock.start(timeout: 30, now: t0), .run(seconds: 30))
        assertEqual(clock.deadline, t0.addingTimeInterval(30))
        assertFalse(clock.isHeld)
    }

    runSuite("A call prompt waiting behind a dictation doesn't use up its time") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        assertEqual(
            clock.setOnScreen(false, now: t0.addingTimeInterval(5)),
            .hold,
            "a dictation covering the prompt stops its timeout"
        )
        assertEqual(clock.heldRemaining, 25)
        // A long dictation: far longer than the whole timeout.
        assertEqual(
            clock.setOnScreen(true, now: t0.addingTimeInterval(125)),
            .run(seconds: 25),
            "back on screen it picks up with the time it had left"
        )
        assertEqual(clock.deadline, t0.addingTimeInterval(150))
    }

    runSuite("A call prompt that arrives during a dictation keeps its whole timeout") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        // The island reports the new prompt as off screen right away.
        assertEqual(clock.setOnScreen(false, now: t0), .hold)
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(90)), .run(seconds: 30))
    }

    runSuite("A newer call prompt behind the same dictation stays held") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setOnScreen(false, now: t0.addingTimeInterval(2))
        assertEqual(
            clock.start(timeout: 30, now: t0.addingTimeInterval(10)),
            .hold,
            "the island only reports changes, so a replacement must not start running while still covered"
        )
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(40)), .run(seconds: 30))
    }

    runSuite("Hovering the island holds the call prompt's timeout") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        assertEqual(clock.setHovered(true, now: t0.addingTimeInterval(10)), .hold)
        assertEqual(clock.setHovered(false, now: t0.addingTimeInterval(60)), .run(seconds: 20))
    }

    runSuite("The call prompt's timeout runs only when it is both on screen and not hovered") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        assertEqual(clock.setHovered(true, now: t0.addingTimeInterval(4)), .hold)
        assertEqual(clock.setOnScreen(false, now: t0.addingTimeInterval(6)), .keepGoing, "already held")
        assertEqual(clock.setHovered(false, now: t0.addingTimeInterval(8)), .keepGoing, "still covered")
        assertTrue(clock.isHeld)
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(50)), .run(seconds: 26))
    }

    runSuite("A new call prompt doesn't inherit an old hover") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setHovered(true, now: t0.addingTimeInterval(1))
        assertEqual(clock.start(timeout: 20, now: t0.addingTimeInterval(3)), .run(seconds: 20))
    }

    runSuite("A held call prompt always has at least a second left") {
        var clock = CallPromptTimeoutClock()
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setHovered(true, now: t0.addingTimeInterval(45))
        assertEqual(clock.heldRemaining, 1)
    }

    runSuite("With no call prompt up, hover and visibility changes do nothing") {
        var clock = CallPromptTimeoutClock()
        assertEqual(clock.setOnScreen(false, now: t0), .keepGoing)
        assertEqual(clock.setHovered(true, now: t0), .keepGoing)
        _ = clock.start(timeout: 30, now: t0)
        _ = clock.setOnScreen(false, now: t0.addingTimeInterval(1))
        clock.stop()
        assertNil(clock.deadline)
        assertEqual(clock.setOnScreen(true, now: t0.addingTimeInterval(2)), .keepGoing)
        assertEqual(
            clock.start(timeout: 30, now: t0.addingTimeInterval(3)),
            .run(seconds: 30),
            "after the prompt closes, the next one starts on screen until the island says otherwise"
        )
    }
}
