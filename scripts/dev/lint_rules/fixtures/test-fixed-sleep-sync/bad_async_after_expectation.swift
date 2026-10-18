// lint-fixture-path: Tests/TranscriptedCoreTests/AudioTests/WakeFixtureTests.swift
import XCTest

final class WakeFixtureTests: XCTestCase {
    func testWakeRecordsGap() {
        center.post(name: notifications.didWakeName, object: nil)
        let settled = expectation(description: "wake handling settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { settled.fulfill() }
        wait(for: [settled], timeout: 1.5)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(audio.recordingGaps.count, 1)
    }
}
