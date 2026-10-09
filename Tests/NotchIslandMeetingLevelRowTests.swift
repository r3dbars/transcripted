import Foundation

private let stepInterval = NotchIslandMeetingLevelRow.stepInterval

/// Hands the row one reading per step and steps it `steps` times from `start`.
@discardableResult
private func feed(
    _ row: inout NotchIslandMeetingLevelRow,
    mic: Float,
    system: Float,
    steps: Int,
    from start: TimeInterval = 0
) -> TimeInterval {
    var time = start
    for _ in 0..<steps {
        row.receive(mic: mic, system: system, at: time)
        time += stepInterval
        row.step(at: time)
    }
    return time
}

func testNotchIslandMeetingLevelRow() {
    let count = NotchIslandMeetingLevelRow.count
    let audible = NotchIslandMeetingLevelRow.audible

    runSuite("The meeting row keeps its own calmer pace") {
        assertTrue(stepInterval > 0.05, "slower than the dictation waveform's 20 bars a second")
        assertTrue(stepInterval < 0.15, "faster than Core's 0.15 s level publishes")

        var row = NotchIslandMeetingLevelRow()
        for index in 0..<10 { row.receive(mic: 0.9, system: 0.9, at: Double(index) * 0.01) }
        assertTrue(row.slots.allSatisfy { ($0.you ?? 0) <= audible && ($0.call ?? 0) <= audible }, "readings alone never move the row")
        row.step(at: 0.11)
        assertTrue((row.slots.last?.you ?? 0) > audible, "a step shows the loudest reading since the last one")
    }

    runSuite("A quiet meeting rests as dots, the call's on the left and yours on the right") {
        let slots = NotchIslandMeetingLevelRow().slots
        assertEqual(slots.count, count, "one slot per bar")
        for (index, slot) in slots.enumerated() {
            if index < count / 2 {
                assertTrue(slot.call != nil && slot.you == nil, "slot \(index) on the left should show only the call's dot")
            } else {
                assertTrue(slot.you != nil && slot.call == nil, "slot \(index) on the right should show only your dot")
            }
        }
    }

    runSuite("Your voice enters on the right and moves left") {
        var row = NotchIslandMeetingLevelRow()
        let time = feed(&row, mic: 0.8, system: 0, steps: 1)
        assertTrue((row.slots.last?.you ?? 0) > audible, "your newest bar should stand on the right edge")
        assertTrue(row.slots.last?.call == nil, "the call doesn't draw where you're heard")
        assertTrue((row.slots[count - 2].you ?? 1) <= audible, "nothing older than one step yet")

        feed(&row, mic: 0, system: 0, steps: 3, from: time)
        assertTrue((row.slots[count - 4].you ?? 0) > audible, "three steps later the bar should sit three slots left")
    }

    runSuite("The call enters on the left and moves right") {
        var row = NotchIslandMeetingLevelRow()
        let time = feed(&row, mic: 0, system: 0.8, steps: 1)
        assertTrue((row.slots.first?.call ?? 0) > audible, "the call's newest bar should stand on the left edge")
        feed(&row, mic: 0, system: 0, steps: 2, from: time)
        assertTrue((row.slots[2].call ?? 0) > audible, "two steps later it should sit two slots right")
        assertTrue(row.slots[2].you == nil, "you don't draw where only the call is heard")
    }

    runSuite("When both talk the bars cross through each other") {
        var row = NotchIslandMeetingLevelRow()
        feed(&row, mic: 0.8, system: 0.8, steps: count)
        for (index, slot) in row.slots.enumerated() {
            assertTrue(slot.call != nil && slot.you != nil, "slot \(index) should draw both bars while both talk")
        }
    }

    runSuite("One voice crosses the whole row without the other side's dots showing through") {
        var row = NotchIslandMeetingLevelRow()
        feed(&row, mic: 0.8, system: 0, steps: count)
        assertTrue(row.slots[0].call == nil, "the call's resting dot hides where your bar reached the far left")
        assertTrue((row.slots[0].you ?? 0) > audible, "your bar should have crossed to the far left")

        var callOnly = NotchIslandMeetingLevelRow()
        feed(&callOnly, mic: 0, system: 0.8, steps: count)
        assertTrue(callOnly.slots[count - 1].you == nil, "your resting dot hides where the call's bar reached the far right")
        assertTrue((callOnly.slots[count - 1].call ?? 0) > audible, "the call's bar should have crossed to the far right")
    }

    runSuite("The row says when it has come to rest") {
        var row = NotchIslandMeetingLevelRow()
        assertTrue(row.isAtRest(at: 0), "a fresh row has nothing to move")
        row.receive(mic: 0.8, system: 0.5, at: 0)
        assertFalse(row.isAtRest(at: 0.01), "a waiting reading keeps it moving")
        row.step(at: stepInterval)
        assertFalse(row.isAtRest(at: 0.2), "within the hold it keeps moving")
        var time = stepInterval
        for _ in 0..<(count * 4) {
            time += stepInterval
            row.step(at: time)
        }
        assertTrue(row.isAtRest(at: time), "with no readings every bar falls to rest and the row stops")
    }

    runSuite("A late reading holds the bar briefly, then it falls to rest") {
        var row = NotchIslandMeetingLevelRow()
        row.receive(mic: 0.8, system: 0, at: 0)
        row.step(at: stepInterval)
        let first = row.you[0]
        row.step(at: 0.2)
        assertEqual(row.you[0], first, "within the hold the newest bar repeats the last level")
        row.step(at: 1.0)
        assertTrue(row.you[0] < first, "past the hold it falls toward rest")
    }

    runSuite("Bad readings don't break the row") {
        var row = NotchIslandMeetingLevelRow()
        feed(&row, mic: .nan, system: 7, steps: 1)
        let slots = row.slots
        assertTrue(slots.allSatisfy { ($0.call ?? 0).isFinite && ($0.you ?? 0).isFinite }, "levels stay finite")
        assertTrue(slots.allSatisfy { ($0.call ?? 0) <= 1 && ($0.you ?? 0) <= 1 }, "levels stay at most full height")
    }
}
