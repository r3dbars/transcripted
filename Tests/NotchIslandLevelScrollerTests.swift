import Foundation

// Time is injected: a 60 Hz display draws frame k at k/60 s with a 1/60 s frame.
private let displayHz: Double = 60
private let frameDuration: TimeInterval = 1.0 / displayHz

private func frameTime(_ frame: Int, hz: Double = displayHz) -> TimeInterval {
    Double(frame) / hz
}

/// Runs the given frames in order. `deliver` can hand readings to the scroller
/// before each frame draws. Returns the frames on which the bars stepped.
private func runFrames(
    _ frames: [Int],
    hz: Double = displayHz,
    scroller: inout NotchIslandLevelScroller,
    deliver: (Int, TimeInterval, inout NotchIslandLevelScroller) -> Void = { _, _, _ in }
) -> [Int] {
    var stepped: [Int] = []
    for frame in frames {
        let time = frameTime(frame, hz: hz)
        deliver(frame, time, &scroller)
        if scroller.advance(to: time, frameDuration: 1.0 / hz) {
            stepped.append(frame)
        }
    }
    return stepped
}

/// Hands over `reading` (if any), then draws 60 Hz frames from `frame` until the bars step.
@discardableResult
private func advanceToNextStep(
    _ scroller: inout NotchIslandLevelScroller,
    frame: inout Int,
    delivering reading: DictationAudioLevel?
) -> Bool {
    if let reading { scroller.receive(reading, at: frameTime(frame)) }
    for _ in 0..<12 {
        let time = frameTime(frame)
        frame += 1
        if scroller.advance(to: time, frameDuration: frameDuration) { return true }
    }
    return false
}

private func assertShiftedLeftByOne(_ before: [Float], _ after: [Float], _ message: String, file: String = #file, line: Int = #line) {
    assertEqual(Array(after.dropLast()), Array(before.dropFirst()), message, file: file, line: line)
}

private func assertBarsInRange(_ scroller: NotchIslandLevelScroller, count: Int, _ message: String, file: String = #file, line: Int = #line) {
    assertEqual(scroller.levels.count, count, "\(message): bar count", file: file, line: line)
    assertTrue(scroller.levels.allSatisfy { $0 >= 0 && $0 <= 1 }, "\(message): bars \(scroller.levels) out of 0...1", file: file, line: line)
}

func testNotchIslandLevelScroller() {
    let everyThirdFrame = Array(stride(from: 0, to: 60, by: 3))

    runSuite("The bars move at one fixed pace however the readings arrive") {
        assertEqual(NotchIslandLevelScroller.stepInterval, 0.05, "20 bars a second")

        var bunched = NotchIslandLevelScroller(count: 9)
        let bunchedSteps = runFrames(Array(0..<60), scroller: &bunched) { frame, time, scroller in
            guard frame == 0 || frame == 30 else { return }
            for index in 0..<10 {
                let level = Float(index) / 10
                scroller.receive(DictationAudioLevel(level: level, peak: min(1, level + 0.1)), at: time)
            }
        }
        assertEqual(bunchedSteps.count, 20, "1 s of frames should step exactly 20 times with bunched readings")
        assertEqual(bunchedSteps, everyThirdFrame, "bunched readings should not change when the bars step")
        let consecutive = zip(bunchedSteps, bunchedSteps.dropFirst()).contains { pair in pair.1 - pair.0 == 1 }
        assertFalse(consecutive, "no two steps should land on consecutive frames")

        var steady = NotchIslandLevelScroller(count: 9)
        let steadySteps = runFrames(Array(0..<60), scroller: &steady) { frame, time, scroller in
            scroller.receive(DictationAudioLevel(level: Float(frame % 5) / 5), at: time)
        }
        assertEqual(steadySteps, everyThirdFrame, "a reading every frame should step on the same frames")

        var none = NotchIslandLevelScroller(count: 9)
        assertEqual(runFrames(Array(0..<60), scroller: &none), everyThirdFrame, "no readings at all should step on the same frames")

        var fastDisplay = NotchIslandLevelScroller(count: 9)
        let fastSteps = runFrames(Array(0..<120), hz: 120, scroller: &fastDisplay) { frame, time, scroller in
            if frame % 4 == 0 { scroller.receive(DictationAudioLevel(level: 0.5), at: time) }
        }
        assertEqual(fastSteps, Array(stride(from: 0, to: 120, by: 6)), "a 120 Hz display should still step 20 times a second")
    }

    runSuite("A late frame doesn't make the bars catch up in a burst") {
        var scroller = NotchIslandLevelScroller(count: 9)
        var stepCount = 0
        // Rising readings before the stall so each bar holds a distinct value.
        let beforeStall = runFrames(Array(0...12), scroller: &scroller) { frame, time, scroller in
            if frame % 3 == 0 {
                stepCount += 1
                scroller.receive(DictationAudioLevel(level: Float(stepCount) * 0.15), at: time)
            }
        }
        assertEqual(beforeStall, [0, 3, 6, 9, 12], "steps every 3 frames before the stall")

        let barsBeforeLateFrame = scroller.levels
        // The main thread stalls for 500 ms: the next frame lands at t = 0.7 (frame 42).
        let lateFrameStepped = scroller.advance(to: frameTime(42), frameDuration: frameDuration)
        assertTrue(lateFrameStepped, "the late frame should step")
        assertShiftedLeftByOne(barsBeforeLateFrame, scroller.levels, "the late frame should move the bars exactly one place")

        let afterStall = runFrames(Array(43...60), scroller: &scroller)
        assertFalse(afterStall.contains(43), "the frame right after the late one should not step")
        assertEqual(afterStall, [45, 48, 51, 54, 57, 60], "steps should resume 0.05 s apart from the late frame")
    }

    runSuite("Frames between steps don't move the bars") {
        var scroller = NotchIslandLevelScroller(count: 9)
        for frame in 0..<30 {
            let time = frameTime(frame)
            let before = scroller.levels
            scroller.receive(DictationAudioLevel(level: Float(frame % 4) / 4, peak: 0.9), at: time)
            let moved = scroller.advance(to: time, frameDuration: frameDuration)
            if frame % 3 == 0 {
                assertTrue(moved, "frame \(frame) should step")
            } else {
                assertFalse(moved, "frame \(frame) is between steps")
                assertEqual(scroller.levels, before, "frame \(frame) should leave the bars as they were")
            }
        }
    }

    runSuite("A loud sound shows at once and eases down after") {
        var scroller = NotchIslandLevelScroller(count: 9)
        var frame = 0
        assertTrue(advanceToNextStep(&scroller, frame: &frame, delivering: DictationAudioLevel(level: 0.9, peak: 0.9)), "loud step")
        let loudBar = scroller.levels.last ?? 0
        assertTrue(loudBar >= 0.7 * 0.9 - 1e-6, "the step after a loud reading should rise at least 70% of the way at once, got \(loudBar)")

        var previous = loudBar
        for quietStep in 1...4 {
            assertTrue(advanceToNextStep(&scroller, frame: &frame, delivering: .silent), "quiet step \(quietStep)")
            let newest = scroller.levels.last ?? 0
            assertTrue(newest < previous, "quiet step \(quietStep) should keep falling: \(newest) after \(previous)")
            if quietStep == 1 {
                assertTrue(newest > 0, "the first quiet step should ease down, not drop straight to 0")
            }
            previous = newest
        }
    }

    runSuite("The newest bar is on the right and older bars move left one place per step") {
        let count = 9
        var scroller = NotchIslandLevelScroller(count: count)
        var frame = 0
        advanceToNextStep(&scroller, frame: &frame, delivering: DictationAudioLevel(level: 0.9, peak: 0.9))
        let loudBar = scroller.levels[count - 1]
        assertTrue(loudBar > 0.5, "the loud bar should be the rightmost, got \(scroller.levels)")
        assertTrue(scroller.levels.dropLast().allSatisfy { $0 == 0 }, "older bars should still be at rest")

        for quietStep in 1...5 {
            let before = scroller.levels
            assertTrue(advanceToNextStep(&scroller, frame: &frame, delivering: .silent), "quiet step \(quietStep)")
            assertShiftedLeftByOne(before, scroller.levels, "quiet step \(quietStep) should move every bar one place left")
            assertEqual(scroller.levels[count - 1 - quietStep], loudBar, "the loud bar should sit at index \(count - 1 - quietStep)")
        }
    }

    runSuite("When readings stop, the bars come to rest") {
        var scroller = NotchIslandLevelScroller(count: 9)
        scroller.receive(DictationAudioLevel(level: 0.9, peak: 1), at: 0)
        _ = runFrames(Array(0...120), scroller: &scroller)
        assertTrue(scroller.levels.allSatisfy { $0 < 0.01 }, "2 s without readings should leave every bar near 0, got \(scroller.levels)")
    }

    runSuite("levels always has count values in 0...1") {
        for count in [1, 9, 24] {
            var scroller = NotchIslandLevelScroller(count: count)
            assertEqual(scroller.levels, Array(repeating: Float(0), count: count), "a new scroller starts with \(count) bars at rest")

            // Deterministic jittered frames, bursts of readings, and a stall.
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(count)
            func nextUnit() -> Float {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return Float(seed >> 40) / Float(1 << 24)
            }
            var time: TimeInterval = 10
            for frame in 0..<400 {
                time += frame == 200 ? 0.6 : frameDuration * Double(0.5 + nextUnit())
                let burst = Int(nextUnit() * 4)
                for _ in 0..<burst {
                    scroller.receive(DictationAudioLevel(level: nextUnit(), peak: nextUnit()), at: time)
                }
                _ = scroller.advance(to: time, frameDuration: frameDuration)
                assertBarsInRange(scroller, count: count, "count \(count), frame \(frame)")
            }
        }
    }

    runSuite("The bars stay in 0...1 even if a reading is out of range") {
        var scroller = NotchIslandLevelScroller(count: 9)
        let outOfRange = [
            DictationAudioLevel(level: 3, peak: 5),
            DictationAudioLevel(level: -2, peak: -1),
            DictationAudioLevel(level: 1.5),
        ]
        for frame in 0..<30 {
            let time = frameTime(frame)
            scroller.receive(outOfRange[frame % outOfRange.count], at: time)
            _ = scroller.advance(to: time, frameDuration: frameDuration)
            assertBarsInRange(scroller, count: 9, "frame \(frame)")
        }
    }
}
