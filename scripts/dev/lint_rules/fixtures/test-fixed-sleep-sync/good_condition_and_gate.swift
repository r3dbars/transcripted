// lint-fixture-path: Tests/MeetingPromptDetectorTests.swift
// Shape of the fixes: age the stamp instead of sleeping (9c7ed2698), poll a
// condition in a bounded loop (4ca2f83bd), await a gate the fake opens.
import XCTest

final class AudioLevelPublishGateTests: XCTestCase {
    @MainActor
    func testMicLevelPublishesAgainAfterInterval() async {
        let audio = makeAudio()
        audio.calculateLevel(buffer: buffer)
        // Task.sleep(nanoseconds:) in a comment doesn't count, nor "usleep(1)" in a string.
        audio.micLevelPublishLock.withLock {
            audio.lastMicLevelPublishTime -= 2 * Audio.levelPublishInterval
        }
        audio.calculateLevel(buffer: buffer)
        await gate.waitUntilOpened()
        XCTAssertEqual(published.count, 2)
    }
}

@MainActor
private func waitForPromptEvaluation(until condition: () -> Bool) async {
    for _ in 0..<1_000 {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

private func waitUntil(timeout: TimeInterval = 2, condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return condition()
}
