import XCTest
import AVFoundation
import Combine
@testable import TranscriptedCore

final class CoreAudioSystemAudioCaptureTests: XCTestCase {
    private final class HAL: @unchecked Sendable {
        var format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var now: TimeInterval = 100
        var starts = 0
        var prepares = 0
        var stops = 0
        var rejectStart = false
        var onPrepare: (() -> Void)?
        var onStart: (() -> Void)?
        func makeCapture() -> CoreAudioSystemAudioCapture {
            CoreAudioSystemAudioCapture(hardwareHooks: .init(
                prepare: { self.prepares += 1; self.onPrepare?(); return self.format },
                start: {
                    self.starts += 1
                    self.onStart?()
                    if self.rejectStart { throw NSError(domain: "HALTest", code: 1) }
                },
                stop: { self.stops += 1 },
                currentFormat: { self.format }
            ), clock: { self.now })
        }
        func buffer() -> AVAudioPCMBuffer {
            let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8)!
            result.frameLength = 8
            for item in UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList) {
                memset(item.mData!, 0, Int(item.mDataByteSize))
            }
            return result
        }
    }

    func testPreparedStartIsIdempotentAndStopDropsUnadmittedTail() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        try capture.prepare()
        try capture.prepare()
        try capture.start { frames += Int($0.frameLength) }
        try capture.start { _ in XCTFail("Second start replaced active consumer") }
        capture.receiveForTesting(hal.buffer())
        capture.stopSync()
        capture.stopSync()
        XCTAssertEqual(frames, 0)
        XCTAssertEqual(hal.prepares, 1)
        XCTAssertEqual(hal.starts, 1)
        XCTAssertEqual(hal.stops, 1)
        XCTAssertNil(capture.audioFormat)
    }

    func testFailedStartCleansHardwareAndCanPrepareFresh() throws {
        let hal = HAL(), capture = hal.makeCapture()
        hal.rejectStart = true
        XCTAssertThrowsError(try capture.start { _ in })
        XCTAssertEqual(hal.stops, 1)
        hal.rejectStart = false
        try capture.start { _ in }
        XCTAssertEqual(hal.prepares, 2)
        XCTAssertEqual(hal.starts, 2)
        capture.stopSync()
    }

    func testMissingBuffersRecoverOnceAndBalanceSuccess() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(events, [.deviceSwitch])
        XCTAssertEqual(hal.starts, 2)
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(events.count, 2)
        guard case .gap(let duration) = events[1] else { return XCTFail("Missing recovery gap") }
        XCTAssertEqual(duration, 3.2, accuracy: 0.001)
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2, "Recovery budget must not reset after success")
        XCTAssertEqual(events.count, 2, "An already-balanced recovery must not abandon twice")
    }

    func testNoRecoveryFromAmplitudeSilence() throws {
        let hal = HAL(), capture = hal.makeCapture()
        try capture.start { _ in }
        for _ in 0..<10 {
            hal.now += 1
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
        }
        XCTAssertEqual(hal.starts, 1)
        capture.stopSync()
    }

    func testRecoveryFailureAndStopEachBalanceWriteHold() throws {
        for failRestart in [false, true] {
            let hal = HAL(), capture = hal.makeCapture()
            var events: [SystemAudioRecoveryEvent] = []
            let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
            try capture.start { _ in }
            hal.rejectStart = failRestart
            hal.now += 3.1
            capture.drainForTesting()
            capture.stopSync()
            XCTAssertEqual(events, [.deviceSwitch, .recoveryAbandoned])
            withExtendedLifetime(subscription) {}
        }
    }

    func testStaleWakeAfterStopCannotRestartHardware() throws {
        let hal = HAL(), capture = hal.makeCapture()
        try capture.start { _ in }
        capture.stopSync()
        capture.recoverAfterSystemWake()
        capture.drainForTesting() // serial queue fence behind queued wake
        XCTAssertEqual(hal.starts, 1)
        XCTAssertNil(capture.audioFormat)
    }

    func testFormatInvalidationDiscardsQueuedOldFormatAndTerminates() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        try capture.start { frames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        capture.invalidateFormatForTesting()
        capture.drainForTesting()
        XCTAssertEqual(frames, 0)
        XCTAssertEqual(hal.stops, 1)
        XCTAssertTrue(messages.last??.contains("format changed") == true)
        withExtendedLifetime(subscription) {}
        capture.stopSync()
    }

    func testChangedRecoveryFormatIsRejectedBeforeRestart() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        try capture.start { _ in }
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 1)
        XCTAssertEqual(events, [.deviceSwitch, .recoveryAbandoned])
        XCTAssertEqual(capture.audioFormat?.sampleRate, 48000)
        withExtendedLifetime(subscription) {}
        capture.stopSync()
    }

    func testStopWaitsForInFlightPrepareThenClearsIt() {
        let hal = HAL(), capture = hal.makeCapture()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finishedPrepare = expectation(description: "prepare finished")
        let finishedStop = expectation(description: "stop finished")
        hal.onPrepare = { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        DispatchQueue.global().async {
            try? capture.prepare()
            finishedPrepare.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async {
            capture.stopSync()
            finishedStop.fulfill()
        }
        release.signal()
        wait(for: [finishedPrepare, finishedStop], timeout: 3)
        XCTAssertEqual(hal.prepares, 1)
        XCTAssertEqual(hal.starts, 0)
        XCTAssertEqual(hal.stops, 1)
        XCTAssertNil(capture.audioFormat)
    }

    func testStopWaitsForInFlightStartThenStopsExactHardware() {
        let hal = HAL(), capture = hal.makeCapture()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let started = expectation(description: "start returned")
        let stopped = expectation(description: "stop returned")
        hal.onStart = { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        DispatchQueue.global().async {
            try? capture.start { _ in }
            started.fulfill()
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        DispatchQueue.global().async {
            capture.stopSync()
            stopped.fulfill()
        }
        release.signal()
        wait(for: [started, stopped], timeout: 3)
        XCTAssertEqual(hal.starts, 1)
        XCTAssertEqual(hal.stops, 1)
        XCTAssertNil(capture.audioFormat)
    }

    func testCallbackCanStopReentrantlyWithoutDeadlock() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var ordinaryFrames = 0
        try capture.start { buffer in
            ordinaryFrames += Int(buffer.frameLength)
            capture.stopSync()
        }
        capture.receiveForTesting(hal.buffer())
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(ordinaryFrames, 8)
        XCTAssertEqual(hal.stops, 1)
    }

    func testStopFromRecoveryEventCannotRestartAfterCancellation() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { event in
            events.append(event)
            if event == .deviceSwitch { capture.stopSync() }
        }
        try capture.start { _ in }
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 1)
        XCTAssertEqual(events, [.deviceSwitch, .recoveryAbandoned])
        XCTAssertNil(capture.audioFormat)
        withExtendedLifetime(subscription) {}
    }

    func testStopFromReconnectingMessageCannotRestartAfterCancellation() throws {
        let hal = HAL(), capture = hal.makeCapture()
        let subscription = capture.errorMessagePublisher.sink { message in
            if message?.contains("reconnecting") == true { capture.stopSync() }
        }
        try capture.start { _ in }
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 1)
        XCTAssertNil(capture.audioFormat)
        withExtendedLifetime(subscription) {}
    }

    func testReuseAfterStopDeliversOnlyNewSessionBuffers() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var firstFrames = 0, secondFrames = 0
        try capture.start { firstFrames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        capture.stopSync()
        try capture.start { secondFrames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(firstFrames, 0)
        XCTAssertEqual(secondFrames, 8)
        capture.stopSync()
    }

    func testReentrantRestartFromGapCannotReceivePredecessorBuffer() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var successorFrames = 0
        let subscription = capture.recoveryEventPublisher.sink { event in
            if case .gap = event {
                capture.stopSync()
                try? capture.start { successorFrames += Int($0.frameLength) }
            }
        }
        try capture.start { _ in }
        hal.now += 3.1
        capture.drainForTesting()
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 3)
        XCTAssertEqual(successorFrames, 0)
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(successorFrames, 8)
        withExtendedLifetime(subscription) {}
        capture.stopSync()
    }
}
