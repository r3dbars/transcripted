import Foundation

func testNextSentenceKeyGesture() {
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let bindings: [(key: NextSentenceHotkey, code: Int64, flags: UInt64)] = [
        (NextSentenceHotkey(recorded: 96)!, 96, 0),
        (NextSentenceHotkey(recorded: 2, modifiers: NextSentenceHotkey.option, label: "d")!,
         2, NextSentenceHotkey.option),
    ]

    runSuite("Blocked nonmodifier presses and their releases pass through without gesture work") {
        for binding in bindings {
            var gesture = NextSentenceKeyGesture()
            let down = gesture.handle(.keyDown(keyCode: binding.code, flags: binding.flags),
                                      key: binding.key, blocked: true, now: instant)
            assertEqual(down.swallow, false)
            assertEqual(down.event, nil)
            assertEqual(down.holdCheck, nil)
            let up = gesture.handle(.keyUp(keyCode: binding.code, flags: 0),
                                    key: binding.key, blocked: false, now: instant.addingTimeInterval(0.01))
            assertEqual(up.swallow, false, "an unaccepted press cannot consume its later release")
            assertEqual(up.event, nil)
            assertEqual(up.holdCheck, nil)
            assertEqual(gesture.downAt, nil)
            assertEqual(gesture.holding, false)
        }
    }

    runSuite("Orphan and wrong-chord releases do not become Write for Me gestures") {
        for binding in bindings {
            var orphan = NextSentenceKeyGesture()
            let release = orphan.handle(.keyUp(keyCode: binding.code, flags: binding.flags),
                                        key: binding.key, blocked: false, now: instant)
            assertEqual(release.swallow, false)
            assertEqual(release.event, nil)
            assertEqual(release.holdCheck, nil)

            var rejected = NextSentenceKeyGesture()
            let wrongFlags: UInt64 = binding.flags == 0 ? NextSentenceHotkey.option : 0
            let down = rejected.handle(.keyDown(keyCode: binding.code, flags: wrongFlags),
                                       key: binding.key, blocked: false, now: instant)
            assertEqual(down.swallow, false)
            assertEqual(down.event, nil)
            assertEqual(down.holdCheck, nil)
            let up = rejected.handle(.keyUp(keyCode: binding.code, flags: binding.flags),
                                     key: binding.key, blocked: false, now: instant.addingTimeInterval(0.01))
            assertEqual(up.swallow, false, "a matching release cannot retroactively accept a rejected chord")
            assertEqual(up.event, nil)
            assertEqual(up.holdCheck, nil)
            assertEqual(rejected.downAt, nil)
        }
    }

    runSuite("Accepted F5 taps consume both edges and emit one tap") {
        var gesture = NextSentenceKeyGesture()
        let key = bindings[0].key
        let down = gesture.handle(.keyDown(keyCode: 96, flags: 0), key: key, blocked: false, now: instant)
        assertEqual(down.swallow, true)
        assertEqual(down.event, nil)
        assertTrue(down.holdCheck != nil, "an accepted press schedules its hold check")
        let up = gesture.handle(.keyUp(keyCode: 96, flags: 0), key: key, blocked: false,
                                now: instant.addingTimeInterval(0.01))
        assertEqual(up.swallow, true)
        assertEqual(up.event, .tap)
        assertEqual(up.holdCheck, nil)
        assertEqual(gesture.downAt, nil)
        assertEqual(gesture.holding, false)
        if let token = down.holdCheck {
            assertEqual(gesture.holdTimerFired(token), nil, "a released tap invalidates its pending hold check")
        }
    }

    runSuite("Accepted holds consume repeats and release even if admission later becomes blocked") {
        for binding in bindings {
            var gesture = NextSentenceKeyGesture()
            let down = gesture.handle(.keyDown(keyCode: binding.code, flags: binding.flags),
                                      key: binding.key, blocked: false, now: instant)
            assertEqual(down.swallow, true)
            assertTrue(down.holdCheck != nil)
            if let token = down.holdCheck {
                assertEqual(gesture.holdTimerFired(token), .holdStart)
            }
            assertEqual(gesture.holding, true)
            let repeated = gesture.handle(.keyDown(keyCode: binding.code, flags: binding.flags),
                                          key: binding.key, blocked: true, now: instant)
            assertEqual(repeated.swallow, true, "autorepeat remains part of the accepted press")
            assertEqual(repeated.event, nil)
            assertEqual(repeated.holdCheck, nil)
            let up = gesture.handle(.keyUp(keyCode: binding.code, flags: 0),
                                    key: binding.key, blocked: true, now: instant)
            assertEqual(up.swallow, true, "accepted release remains consumed after modifiers lift or blocking changes")
            assertEqual(up.event, .holdEnd)
            assertEqual(up.holdCheck, nil)
            assertEqual(gesture.downAt, nil)
            assertEqual(gesture.holding, false)
        }
    }

    runSuite("Accepted Option-D releases still complete after Option lifts") {
        var gesture = NextSentenceKeyGesture()
        let binding = bindings[1]
        let down = gesture.handle(.keyDown(keyCode: binding.code, flags: binding.flags),
                                  key: binding.key, blocked: false, now: instant)
        assertEqual(down.swallow, true)
        let up = gesture.handle(.keyUp(keyCode: binding.code, flags: 0),
                                key: binding.key, blocked: false, now: instant.addingTimeInterval(0.01))
        assertEqual(up.swallow, true)
        assertEqual(up.event, .tap)
        assertEqual(gesture.downAt, nil)
    }

    runSuite("Accepted Fn modifier taps emit a tap while both edges pass through") {
        var gesture = NextSentenceKeyGesture()
        let down = gesture.handle(.flagsChanged(keyCode: 63, flags: 0x80_0000),
                                  key: .fn, blocked: false, now: instant)
        assertEqual(down.swallow, false)
        assertEqual(down.event, nil)
        assertTrue(down.holdCheck != nil)
        let up = gesture.handle(.flagsChanged(keyCode: 63, flags: 0),
                                key: .fn, blocked: false, now: instant.addingTimeInterval(0.1))
        assertEqual(up.swallow, false)
        assertEqual(up.event, .tap)
        assertEqual(up.holdCheck, nil)
        assertEqual(gesture.downAt, nil)
        assertEqual(gesture.holding, false)
    }

    runSuite("Blocked Fn modifier edges remain pass-through without a gesture or hold timer") {
        var gesture = NextSentenceKeyGesture()
        let down = gesture.handle(.flagsChanged(keyCode: 63, flags: 0x80_0000),
                                  key: .fn, blocked: true, now: instant)
        let up = gesture.handle(.flagsChanged(keyCode: 63, flags: 0),
                                key: .fn, blocked: true, now: instant)
        for result in [down, up] {
            assertEqual(result.swallow, false)
            assertEqual(result.event, nil)
            assertEqual(result.holdCheck, nil)
        }
        assertEqual(gesture.downAt, nil)
        assertEqual(gesture.holding, false)
    }
}
