// lint-fixture-path: Tests/TranscriptedCoreTests/AudioTests/AudioLevelPublishGateTests.swift
// Shape of 9c7ed2698^: sleeps through the publish interval on a real clock, then asserts.
import XCTest

final class AudioLevelPublishGateTests: XCTestCase {
    @MainActor
    func testMicLevelPublishesAgainAfterInterval() async throws {
        let audio = makeAudio()
        let buffer = makeBuffer(sampleValue: 0.5)
        audio.calculateLevel(buffer: buffer)
        try await Task.sleep(nanoseconds: UInt64((Audio.levelPublishInterval + 0.05) * 1_000_000_000))
        audio.calculateLevel(buffer: buffer)
        XCTAssertEqual(published.count, 2)
    }
}
