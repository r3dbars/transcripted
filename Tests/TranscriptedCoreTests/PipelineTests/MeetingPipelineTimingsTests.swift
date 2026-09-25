import XCTest
@testable import TranscriptedCore

final class MeetingPipelineTimingsTests: XCTestCase {

    func testStagesAddUpAndSleepIsWallMinusAwake() {
        let start = Date(timeIntervalSince1970: 1_000)
        let timings = MeetingPipelineTimings(now: start, uptime: 50)
        timings.add(.resample, seconds: 1.5)
        timings.add(.diarize, seconds: 4)
        timings.add(.diarize, seconds: 2)
        timings.add(.modelsReady, seconds: -1)
        timings.add(.resample, seconds: .nan)
        timings.addSpeechToTextCall(seconds: 0.08, inputSeconds: 4.5, model: "parakeet-tdt-v3")
        timings.addSpeechToTextCall(seconds: 0.12, inputSeconds: 12, model: nil)
        timings.recordRecordingLength(seconds: 600)
        timings.recordRecordingLength(seconds: 590)

        // 100 s on the wall clock, 70 s awake: 30 s asleep.
        let snapshot = timings.snapshot(now: start.addingTimeInterval(100), uptime: 120)

        XCTAssertEqual(snapshot.processingSeconds, 100, accuracy: 0.0001)
        XCTAssertEqual(snapshot.sleepSeconds, 30, accuracy: 0.0001)
        XCTAssertEqual(snapshot.modelsReadySeconds, 0)
        XCTAssertEqual(snapshot.resampleSeconds, 1.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.diarizeSeconds, 6, accuracy: 0.0001)
        XCTAssertEqual(snapshot.speechToTextSeconds, 0.2, accuracy: 0.0001)
        XCTAssertEqual(snapshot.speechToTextCalls, 2)
        XCTAssertEqual(snapshot.speechToTextInputSeconds, 16.5, accuracy: 0.0001)
        XCTAssertEqual(snapshot.recordingSeconds, 600)
        XCTAssertEqual(snapshot.speechModel, "parakeet-tdt-v3")
    }

    func testMeasureRecordsOnlyInsideABoundJob() async throws {
        XCTAssertNil(MeetingPipelineTimings.current)
        XCTAssertEqual(MeetingPipelineTimings.measure(.resample) { 7 }, 7)

        let timings = MeetingPipelineTimings()
        let value = try await MeetingPipelineTimings.$current.withValue(timings) { () async throws -> Int in
            let synchronous = MeetingPipelineTimings.measure(.resample) { 1 }
            let asynchronous = try await MeetingPipelineTimings.measureAsync(.diarize) { () async throws -> Int in
                try await Task.sleep(nanoseconds: 5_000_000)
                return 2
            }
            return synchronous + asynchronous
        }

        XCTAssertEqual(value, 3)
        XCTAssertGreaterThan(timings.snapshot().diarizeSeconds, 0)
        XCTAssertNil(MeetingPipelineTimings.current)
    }

    func testNoSleepWhenClocksAgree() {
        let start = Date(timeIntervalSince1970: 0)
        let timings = MeetingPipelineTimings(now: start, uptime: 10)
        let snapshot = timings.snapshot(now: start.addingTimeInterval(5), uptime: 15.001)
        XCTAssertEqual(snapshot.sleepSeconds, 0)
    }
}
