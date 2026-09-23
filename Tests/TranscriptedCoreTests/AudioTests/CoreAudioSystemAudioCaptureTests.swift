import XCTest
import AVFoundation
import Combine
import CoreAudio
@testable import TranscriptedCore

final class CoreAudioSystemAudioCaptureTests: XCTestCase {
    func testProductionAggregateDoesNotWaitForTappedPlayback() throws {
        let properties = CoreAudioSystemAudioCapture.aggregateProperties(tapUID: "tap-id", aggregateUID: "aggregate-id")
        XCTAssertEqual(properties[kAudioAggregateDeviceTapAutoStartKey] as? Bool, false)
        XCTAssertEqual(properties[kAudioAggregateDeviceIsPrivateKey] as? Bool, true)
        XCTAssertEqual(properties[kAudioAggregateDeviceUIDKey] as? String, "aggregate-id")
        let taps = try XCTUnwrap(properties[kAudioAggregateDeviceTapListKey] as? [[String: Any]])
        XCTAssertEqual(taps.count, 1)
        XCTAssertEqual(taps.first?[kAudioSubTapUIDKey] as? String, "tap-id")
        XCTAssertEqual(taps.first?[kAudioSubTapDriftCompensationKey] as? Bool, true)
        XCTAssertNil(properties[kAudioAggregateDeviceSubDeviceListKey], "Do not add physical device input channels to the tap's PCM layout")
    }

    func testQuietBuffersBeyondWatchdogThenSignalStayInSameCapture() throws {
        let hal = HAL(), capture = hal.makeCapture()
        let attempt = SystemAudioCaptureStartAttempt(capture: capture)
        var frames = 0
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try attempt.startIfNotCancelled { buffer in
            attempt.observeSignal(buffer)
            frames += Int(buffer.frameLength)
        }
        for _ in 0..<16 {
            hal.now += 0.5
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
        }
        XCTAssertEqual(frames, 128, "Valid silent PCM retains the quiet prefix")
        XCTAssertFalse(attempt.hasObservedSignal, "Silent callbacks must not manufacture permission verification")
        let speech = hal.buffer()
        speech.floatChannelData![0][0] = 0.25
        capture.receiveForTesting(speech)
        capture.drainForTesting()
        XCTAssertEqual(frames, 136, "Delayed signal appends to the same capture")
        XCTAssertTrue(attempt.hasObservedSignal)
        XCTAssertEqual(hal.starts, 1)
        XCTAssertEqual(hal.prepares, 1)
        XCTAssertTrue(events.isEmpty, "Amplitude silence must not trigger reconnects")
    }

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

    func testFinishDrainsQueuedPCMExactlyOnceAndRejectsLateInput() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        try capture.start { frames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        capture.receiveForTesting(hal.buffer())
        capture.finishAndDrain()
        XCTAssertEqual(frames, 16)
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        capture.finishAndDrain()
        XCTAssertEqual(frames, 16)
        XCTAssertEqual(hal.stops, 1)
    }

    func testOverflowTerminatesWithoutAppendingAcrossGapIncludingAtFinish() throws {
        for finishImmediately in [false, true] {
            let hal = HAL(), capture = hal.makeCapture()
            var frames = 0
            var messages: [String?] = []
            let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
            try capture.start { frames += Int($0.frameLength) }
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
            for _ in 0..<33 { capture.receiveForTesting(hal.buffer()) }
            if finishImmediately { capture.finishAndDrain() } else { capture.drainForTesting() }
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
            XCTAssertEqual(frames, 8, "Previously delivered prefix survives, nothing follows the lost interval")
            XCTAssertEqual(capture.bufferSuccessRate, 0)
            XCTAssertTrue(messages.contains { $0?.contains("overflow") == true })
            capture.stopSync()
            withExtendedLifetime(subscription) {}
        }
    }

    func testProductionFinishHandoffWritesExactOriginalFileAfterAdmissionCloses() throws {
        let hal = HAL(), capture = hal.makeCapture()
        let attempt = SystemAudioCaptureStartAttempt(capture: capture)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("original.wav")
        let successorURL = directory.appendingPathComponent("successor.wav")
        let writer = try AVAudioFile(forWriting: url, settings: hal.format.settings)
        let successor = try AVAudioFile(forWriting: successorURL, settings: hal.format.settings)
        let queue = DispatchQueue(label: "finish-writer-test")
        try attempt.prepare()
        try attempt.startIfNotCancelled { buffer in
            attempt.observeSignal(buffer)
            attempt.enqueueFinishingBuffer(buffer, writer: writer, queue: queue) { _ in XCTFail("Tail write failed") }
        }
        // Models Audio.stop's synchronous arm, then consumer execution before
        // the asynchronously scheduled HAL stop reaches the backend queue.
        attempt.beginFinishing()
        let input = hal.buffer()
        input.floatChannelData![0][0] = 0.25
        capture.receiveForTesting(input)
        capture.drainForTesting()
        capture.receiveForTesting(input)
        attempt.finishAndDrain()
        // Arbitrary late callbacks cannot append once finish has returned.
        attempt.enqueueFinishingBuffer(input, writer: writer, queue: queue) { _ in XCTFail() }
        queue.sync { writer.close(); successor.close() }
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 16)
        XCTAssertEqual(try AVAudioFile(forReading: successorURL).length, 0)
        XCTAssertTrue(attempt.hasObservedSignal)
        XCTAssertFalse(attempt.isDraining)
    }

    func testReentrantCancellationDuringFinishCannotDeliverRemainingTail() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        try capture.start { buffer in
            frames += Int(buffer.frameLength)
            capture.stopSync()
        }
        capture.receiveForTesting(hal.buffer())
        capture.receiveForTesting(hal.buffer())
        capture.finishAndDrain()
        XCTAssertEqual(frames, 8)
    }

    func testAttemptFinishSubscriberCanCancelAcrossBackendQueueWithoutDeadlock() throws {
        let hal = HAL(), capture = hal.makeCapture()
        let attempt = SystemAudioCaptureStartAttempt(capture: capture)
        let subscription = capture.errorMessagePublisher.sink { message in
            if message?.contains("overflow") == true { attempt.cancel() }
        }
        try attempt.startIfNotCancelled { _ in }
        for _ in 0..<33 { capture.receiveForTesting(hal.buffer()) }
        let completed = expectation(description: "cross-queue finish completed")
        DispatchQueue.global().async {
            attempt.finishAndDrain()
            completed.fulfill()
        }
        wait(for: [completed], timeout: 3)
        XCTAssertTrue(attempt.hasFinalizationFailure)
        withExtendedLifetime(subscription) {}
    }

    func testDuplicateFinishCannotCancelTailBeforeFirstFinisherReachesBackend() throws {
        let hal = HAL(), capture = hal.makeCapture()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var finishCalls = 0
        let attempt = SystemAudioCaptureStartAttempt(capture: capture, beforeFinishForTesting: {
            lock.lock(); finishCalls += 1; let first = finishCalls == 1; lock.unlock()
            if first { entered.signal(); _ = release.wait(timeout: .now() + 3) }
        })
        var frames = 0
        try attempt.startIfNotCancelled { frames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        let finished = expectation(description: "first finisher completed")
        DispatchQueue.global().async { attempt.finishAndDrain(); finished.fulfill() }
        XCTAssertEqual(entered.wait(timeout: .now() + 3), .success)
        attempt.finishAndDrain()
        release.signal()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(frames, 8)
        XCTAssertEqual(hal.stops, 1)
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

    func testEverySystemWakeGetsItsOwnReconnect() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        var messages: [String?] = []
        let recoverySubscription = capture.recoveryEventPublisher.sink { events.append($0) }
        let messageSubscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime((recoverySubscription, messageSubscription)) {}; capture.stopSync() }
        try capture.start { _ in }
        for wake in 1...3 {
            capture.recoverAfterSystemWake()
            capture.drainForTesting() // serial queue fence behind queued wake
            XCTAssertEqual(hal.starts, 1 + wake, "Wake \(wake) must reconnect, not end system audio")
            hal.now += 0.1
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
        }
        XCTAssertEqual(events.filter { $0 == .deviceSwitch }.count, 3)
        XCTAssertEqual(events.filter { if case .gap = $0 { return true } else { return false } }.count, 3)
        XCTAssertFalse(events.contains(.recoveryAbandoned))
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
    }

    func testWakeReconnectLeavesStallBudgetForALaterStall() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2)
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 3, "A stall after a wake still gets its one reconnect")
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 3, "Stalls still get one reconnect per recording")
        XCTAssertEqual(events.count, 4)
        XCTAssertFalse(events.contains(.recoveryAbandoned))
    }

    func testSilenceWhileTheMacFallsAsleepKeepsTheStallReconnect() throws {
        // Hardware 2026-09-23: each sleep entry stalled the tap for 3s. The
        // first spent the one stall reconnect, the second ended system audio
        // before the wake could reconnect it.
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        var messages: [String?] = []
        let recoverySubscription = capture.recoveryEventPublisher.sink { events.append($0) }
        let messageSubscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime((recoverySubscription, messageSubscription)) {}; capture.stopSync() }
        try capture.start { _ in }
        for sleep in 1...2 {
            capture.prepareForSystemSleep()
            capture.drainForTesting() // serial queue fence behind queued sleep notice
            hal.now += 4
            capture.drainForTesting()
            XCTAssertEqual(hal.starts, sleep, "Sleep \(sleep): silence while falling asleep must not reconnect")
            capture.recoverAfterSystemWake()
            capture.drainForTesting()
            XCTAssertEqual(hal.starts, sleep + 1, "Sleep \(sleep): the wake reconnects")
            hal.now += 0.1
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
        }
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 4, "A real stall after both sleeps still gets its reconnect")
        XCTAssertFalse(events.contains(.recoveryAbandoned))
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
    }

    func testSleepThatNeverWakesStopsHoldingStallRecovery() throws {
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        capture.prepareForSystemSleep()
        capture.drainForTesting() // serial queue fence behind queued sleep notice
        hal.now += 4
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 1)
        hal.now += CoreAudioSystemAudioCapture.sleepPendingAwakeLimit
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2, "Awake time past the limit means the sleep never happened")
    }

    func testSleepNoticeAfterStopIsIgnored() throws {
        let hal = HAL(), capture = hal.makeCapture()
        try capture.start { _ in }
        capture.stopSync()
        capture.prepareForSystemSleep()
        try capture.start { _ in }
        defer { capture.stopSync() }
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 3, "A stale sleep notice must not hold the next recording's stall recovery")
    }

    func testWakeDuringPendingReconnectKeepsWriteHoldBalanced() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(events, [.deviceSwitch])
        hal.now += 1
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        XCTAssertEqual(events, [.deviceSwitch, .recoveryAbandoned, .deviceSwitch])
        XCTAssertEqual(hal.starts, 3)
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(events.count, 4)
        guard case .gap(let duration) = events.last else { return XCTFail("Missing recovery gap") }
        XCTAssertEqual(duration, 4.2, accuracy: 0.001, "The pad covers the whole interruption, not just the last reconnect")
        let arms = events.filter { $0 == .deviceSwitch }.count
        XCTAssertEqual(arms, events.count - arms, "Every write-hold arm is balanced by exactly one release")
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
