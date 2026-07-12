import Foundation
import XCTest
@testable import TranscriptedCore

final class DictationSpillPlanTests: XCTestCase {
    func testChunkAndJournalURLsStayInsideSessionDirectory() {
        let sessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let directory = URL(fileURLWithPath: "/tmp/transcripted-dictation-spill", isDirectory: true)
        let plan = DictationSpillPlan(sessionID: sessionID, directory: directory, sampleRate: 16_000)

        XCTAssertEqual(
            plan.journalURL,
            directory.appendingPathComponent("11111111-2222-3333-4444-555555555555.dictation-recording.json")
        )
        XCTAssertEqual(
            plan.chunkURL(index: 7),
            directory.appendingPathComponent("11111111-2222-3333-4444-555555555555-chunk-00007.pcm")
        )
        XCTAssertEqual(
            plan.chunkURL(index: -1),
            directory.appendingPathComponent("11111111-2222-3333-4444-555555555555-chunk-00000.pcm")
        )
    }

    func testRotationUsesConfiguredChunkDuration() {
        let plan = DictationSpillPlan(
            directory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            sampleRate: 16_000,
            chunkDuration: 10
        )

        XCTAssertFalse(plan.shouldRotateChunk(currentFrameCount: 159_999))
        XCTAssertTrue(plan.shouldRotateChunk(currentFrameCount: 160_000))
    }

    func testRecoverableWindowDefaultsToFiveMinutes() {
        let plan = DictationSpillPlan(
            directory: URL(fileURLWithPath: "/tmp", isDirectory: true),
            sampleRate: 16_000
        )

        XCTAssertEqual(plan.maximumRecoverableChunks, 30)
    }
}
