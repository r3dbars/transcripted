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

    private func overflow(_ capture: CoreAudioSystemAudioCapture, _ hal: HAL) {
        for _ in 0...CoreAudioTapBufferRing.defaultCapacity { capture.receiveForTesting(hal.buffer()) }
    }

    private func hostTime(_ seconds: TimeInterval) -> UInt64 {
        AudioConvertNanosToHostTime(UInt64(seconds * 1_000_000_000))
    }

    private final class HAL: @unchecked Sendable {
        var format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
        var now: TimeInterval = 100
        var starts = 0
        var prepares = 0
        var stops = 0
        var rejectStart = false
        var otherAudioPlaying = false
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
                currentFormat: { self.format },
                otherAudioIsPlaying: { self.otherAudioPlaying }
            ), clock: { self.now })
        }
        func buffer(frames: AVAudioFrameCount = 8) -> AVAudioPCMBuffer {
            let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            result.frameLength = frames
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

    func testOverflowAtFinishTerminatesWithoutAppendingAcrossGap() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        try capture.start { frames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        overflow(capture, hal)
        capture.finishAndDrain()
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(frames, 8, "Previously delivered prefix survives, nothing follows the lost interval")
        XCTAssertEqual(capture.bufferSuccessRate, 0)
        XCTAssertTrue(messages.contains { $0?.contains("overflow") == true })
        capture.stopSync()
        withExtendedLifetime(subscription) {}
    }

    func testOverflowKeepsQueuedAudioAndReconnectsQuietly() throws {
        // Deep review M5: a few hundred ms of consumer hiccup used to end
        // system audio for the rest of the meeting.
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        var events: [SystemAudioRecoveryEvent] = []
        var messages: [String?] = []
        let recoverySubscription = capture.recoveryEventPublisher.sink { events.append($0) }
        let messageSubscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime((recoverySubscription, messageSubscription)) {}; capture.stopSync() }
        try capture.start { frames += Int($0.frameLength) }
        overflow(capture, hal)
        capture.drainForTesting()
        XCTAssertEqual(frames, 8 * CoreAudioTapBufferRing.defaultCapacity, "Audio queued before the hole is kept")
        XCTAssertEqual(hal.starts, 2, "An overflow rebuilds the tap instead of ending system audio")
        XCTAssertEqual(events, [.fellBehind], "falling behind is not a route change")
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(frames, 8 * CoreAudioTapBufferRing.defaultCapacity + 8)
        guard case .gap = events.last else { return XCTFail("The hole must be padded") }
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
        XCTAssertFalse(messages.contains { $0?.contains("reconnecting") == true })
    }

    func testRepeatedOverflowsStillEndCleanly() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { frames += Int($0.frameLength) }
        for _ in 0..<CoreAudioSystemAudioCapture.maxOverflowReconnects {
            overflow(capture, hal)
            capture.drainForTesting()
            // Each reconnect gets its first buffer before the next hiccup.
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
        }
        XCTAssertEqual(hal.starts, 1 + CoreAudioSystemAudioCapture.maxOverflowReconnects)
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
        let beforeLast = frames
        overflow(capture, hal)
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 1 + CoreAudioSystemAudioCapture.maxOverflowReconnects)
        XCTAssertTrue(messages.last??.contains("overflow") == true)
        XCTAssertEqual(
            frames - beforeLast,
            8 * CoreAudioTapBufferRing.defaultCapacity,
            "the last overflow still keeps the audio queued before the hole"
        )
    }

    func testOnlyRouteReconnectsReportADeviceSwitch() {
        typealias Capture = CoreAudioSystemAudioCapture
        XCTAssertEqual(Capture.recoveryEvent(for: .formatChange), .deviceSwitch)
        XCTAssertEqual(Capture.recoveryEvent(for: .stall), .deviceSwitch)
        XCTAssertEqual(Capture.recoveryEvent(for: .systemWake), .systemWake)
        XCTAssertEqual(Capture.recoveryEvent(for: .silentAfterWake), .systemWake)
        XCTAssertEqual(Capture.recoveryEvent(for: .overflow), .fellBehind)
    }

    func testOverflowPadCoversTheDroppedAudio() throws {
        // Without host stamps the drain clock only saw the rebuild, so a
        // long stall left system audio running early against the mic.
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        for _ in 0..<CoreAudioTapBufferRing.defaultCapacity { capture.receiveForTesting(hal.buffer()) }
        for _ in 0..<5 { capture.receiveForTesting(hal.buffer(frames: 48_000)) }
        hal.now += 6
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2)
        hal.now += 0.2
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        guard case .gap(let duration) = events.last else { return XCTFail("Missing overflow pad") }
        XCTAssertEqual(duration, 5.2, accuracy: 0.001, "5 s dropped plus the 0.2 s rebuild")
    }

    func testLongOverflowKeepsTheHostClockPad() throws {
        // A stall longer than the host-time plausibility bound used to fall
        // back to just the rebuild time.
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        let firstStart: TimeInterval = 5_000
        let bufferSeconds = 8.0 / 48_000
        for index in 0..<CoreAudioTapBufferRing.defaultCapacity {
            capture.receiveForTesting(hal.buffer(), hostTime: hostTime(firstStart + Double(index) * bufferSeconds))
        }
        let lastEnd = firstStart + Double(CoreAudioTapBufferRing.defaultCapacity) * bufferSeconds
        for _ in 0..<10 { capture.receiveForTesting(hal.buffer(frames: 48_000)) }
        hal.now += 10.1
        capture.drainForTesting()
        hal.now += 0.2
        capture.receiveForTesting(hal.buffer(), hostTime: hostTime(lastEnd + 10.3))
        capture.drainForTesting()
        guard case .gap(let duration) = events.last else { return XCTFail("Missing overflow pad") }
        XCTAssertEqual(duration, 10.3, accuracy: 0.001)
    }

    func testOverflowBeforeAReconnectsPadSkipsHeldAudioAndPadsOnce() throws {
        // The host drops writes until a reconnect's pad lands, so audio
        // handed over in that window must be padded, not counted as kept.
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { frames += Int($0.frameLength) }
        capture.invalidateFormatForTesting()
        capture.drainForTesting()
        XCTAssertEqual(events, [.deviceSwitch])
        overflow(capture, hal)
        hal.now += 1.5
        capture.drainForTesting()
        XCTAssertEqual(frames, 0, "audio queued while the write-hold is on is not delivered")
        XCTAssertEqual(hal.starts, 3)
        XCTAssertEqual(events, [.deviceSwitch, .recoveryAbandoned, .fellBehind])
        hal.now += 0.2
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(frames, 8)
        guard case .gap(let duration) = events.last else { return XCTFail("Missing pad") }
        XCTAssertEqual(duration, 1.7, accuracy: 0.001, "one pad from the first reconnect's start")
    }

    func testReconnectPadUsesHostClockStampsWhenPresent() throws {
        // Deep review M8: drain ticks only bracket the hole to the nearest
        // tick, so each reconnect used to shift system audio slightly.
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        let firstStart: TimeInterval = 5_000
        capture.receiveForTesting(hal.buffer(), hostTime: hostTime(firstStart))
        capture.drainForTesting()
        capture.invalidateFormatForTesting()
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2)
        let lastEnd = firstStart + 8.0 / 48_000
        hal.now += 0.52
        capture.receiveForTesting(hal.buffer(), hostTime: hostTime(lastEnd + 0.5))
        capture.drainForTesting()
        guard case .gap(let duration) = events.last else { return XCTFail("Missing recovery gap") }
        XCTAssertEqual(duration, 0.5, accuracy: 0.001)
    }

    func testInterruptionGapFallsBackToTheDrainClock() {
        XCTAssertEqual(
            CoreAudioSystemAudioCapture.interruptionGap(clockGap: 0.3, lastDeliveredEnd: nil, firstNewStart: 10),
            0.3
        )
        XCTAssertEqual(
            CoreAudioSystemAudioCapture.interruptionGap(clockGap: 0.3, lastDeliveredEnd: 10, firstNewStart: 9),
            0.3,
            "a stamp running backwards is not trusted"
        )
        XCTAssertEqual(
            CoreAudioSystemAudioCapture.interruptionGap(clockGap: 0.3, lastDeliveredEnd: 10, firstNewStart: 100),
            0.3,
            "a stamp far past the measured interruption is not trusted"
        )
        XCTAssertEqual(
            CoreAudioSystemAudioCapture.interruptionGap(clockGap: 0.3, lastDeliveredEnd: 10, firstNewStart: 10.29),
            0.29,
            accuracy: 0.000_001
        )
    }

    func testBufferSizeChangeChecksTheFormatBeforeThePoll() throws {
        // Deep review M11: with a late listener, new-rate samples went out
        // under the old format until the next format poll.
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        defer { capture.stopSync() }
        try capture.start { frames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 2, interleaved: false)!
        let resized = AVAudioPCMBuffer(pcmFormat: hal.format, frameCapacity: 4)!
        resized.frameLength = 4
        hal.now += 0.01
        capture.receiveForTesting(resized)
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2, "A changed buffer size confirms the format right away")
        XCTAssertEqual(frames, 8, "The new-rate buffer is not delivered under the old format")
    }

    func testWakeReconnectWithNoBuffersKeepsTheStallReconnect() throws {
        // Deep review M6: a slow wake used to spend the one stall reconnect,
        // so the next real stall ended system audio for good.
        let hal = HAL(), capture = hal.makeCapture()
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 3)
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 4, "A later real stall still gets its reconnect")
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
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
        overflow(capture, hal)
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
        XCTAssertEqual(events.filter { $0 == .systemWake }.count, 3)
        XCTAssertFalse(events.contains(.deviceSwitch), "Sleeping the Mac is not a route change")
        XCTAssertEqual(events.filter { if case .gap = $0 { return true } else { return false } }.count, 3)
        XCTAssertFalse(events.contains(.recoveryAbandoned))
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
        // Hardware 2026-09-23: each wake put up the interruption warning even
        // though the tap was back in a tenth of a second.
        XCTAssertFalse(
            messages.contains { $0?.contains("reconnecting") == true },
            "A wake reconnect that works must not warn the user"
        )
    }

    func testStallAfterAWakeReconnectStillWarns() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        hal.now += 3.1
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 3, "A wake reconnect that never delivers falls back to the stall reconnect")
        XCTAssertTrue(
            messages.contains { $0?.contains("reconnecting") == true },
            "Once the wake reconnect stalls, the user hears about it"
        )
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

    func testSleepReleasesTheTapAndWakeBuildsAFreshOne() throws {
        // Hardware 2026-09-23: with AirPods as the output, a tap kept attached
        // across sleep came back delivering only zeros, and AirPods playback
        // stayed garbled until they were reconnected.
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { frames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        capture.prepareForSystemSleep()
        capture.drainForTesting() // serial queue fence behind queued sleep notice
        XCTAssertEqual(hal.stops, 1, "Sleep releases the tap and aggregate")
        XCTAssertEqual(frames, 8, "Audio queued before the sleep is kept")
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(frames, 8, "Nothing is attached while the Mac sleeps")
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        XCTAssertEqual(hal.prepares, 2, "Wake builds a fresh tap instead of reusing the old one")
        XCTAssertEqual(hal.starts, 2)
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(frames, 16)
        XCTAssertEqual(events.first, .systemWake)
        XCTAssertFalse(events.contains(.deviceSwitch), "Sleeping the Mac is not a route change")
        XCTAssertFalse(events.contains(.recoveryAbandoned))
    }

    func testSleepReleaseFinishesBeforeTheSleepNoticeReturns() throws {
        // Deep review M14: the release ran async, so nothing guaranteed the
        // tap was off the output before the Mac slept.
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        capture.prepareForSystemSleep()
        XCTAssertEqual(hal.stops, 1, "No queue fence needed: the tap is already released")
    }

    func testSilentTapAfterWakeReconnectsOnlyWhileOtherAudioPlays() throws {
        // Hardware 2026-09-23: after a wake the tap delivered digital zeros
        // while a video played, and nothing reconnected because buffers kept
        // arriving.
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        var messages: [String?] = []
        let recoverySubscription = capture.recoveryEventPublisher.sink { events.append($0) }
        let messageSubscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime((recoverySubscription, messageSubscription)) {}; capture.stopSync() }
        try capture.start { _ in }
        capture.prepareForSystemSleep()
        capture.drainForTesting()
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2)
        for _ in 0..<5 {
            hal.now += 1
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
        }
        XCTAssertEqual(hal.starts, 2, "Zeros on a quiet Mac are real audio, not a broken tap")
        hal.otherAudioPlaying = true
        hal.now += 1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 3, "A tap hearing only zeros while another app plays is rebuilt")
        for _ in 0..<30 {
            hal.now += 1
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
        }
        XCTAssertEqual(
            hal.starts, 2 + CoreAudioSystemAudioCapture.maxWakeSilenceReconnects,
            "Silent-tap reconnects are bounded per wake"
        )
        XCTAssertFalse(events.contains(.deviceSwitch), "A wake reconnect is not a route change")
        XCTAssertFalse(messages.contains { $0?.contains("reconnecting") == true })
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
    }

    func testRealSignalAfterWakeEndsTheSilentTapWatch() throws {
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        let speech = hal.buffer()
        speech.floatChannelData![0][0] = 0.25
        hal.now += 0.1
        capture.receiveForTesting(speech)
        capture.drainForTesting()
        hal.otherAudioPlaying = true
        for _ in 0..<10 {
            hal.now += 1
            capture.receiveForTesting(hal.buffer())
            capture.drainForTesting()
        }
        XCTAssertEqual(hal.starts, 2, "Once the tap has heard real audio, later silence is just silence")
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
        XCTAssertEqual(events, [.deviceSwitch, .recoveryAbandoned, .systemWake])
        XCTAssertEqual(hal.starts, 3)
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(events.count, 4)
        guard case .gap(let duration) = events.last else { return XCTFail("Missing recovery gap") }
        XCTAssertEqual(duration, 4.2, accuracy: 0.001, "The pad covers the whole interruption, not just the last reconnect")
        let arms = events.filter { $0 == .deviceSwitch || $0 == .systemWake }.count
        XCTAssertEqual(arms, events.count - arms, "Every write-hold arm is balanced by exactly one release")
    }

    func testFormatInvalidationDiscardsQueuedOldFormatAndReconnectsQuietly() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var frames = 0
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { frames += Int($0.frameLength) }
        capture.receiveForTesting(hal.buffer())
        capture.invalidateFormatForTesting()
        capture.drainForTesting()
        XCTAssertEqual(frames, 0, "Samples queued under the old format are never relabelled")
        XCTAssertEqual(hal.stops, 1)
        XCTAssertEqual(hal.starts, 2, "A route change rebuilds the tap instead of ending system audio")
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(frames, 8)
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
        XCTAssertFalse(messages.contains { $0?.contains("reconnecting") == true })
    }

    func testOutputRateChangeIsResampledToTheRecordingFormat() throws {
        // Audit 2026-09-23: AirPods moving to their call profile, or a new
        // output device, changes the tap's rate. That used to end system
        // audio for the rest of the meeting.
        let hal = HAL(), capture = hal.makeCapture()
        var delivered: [AVAudioPCMBuffer] = []
        try capture.start { delivered.append($0) }
        defer { capture.stopSync() }
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 2, interleaved: false)!
        capture.invalidateFormatForTesting()
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2)
        XCTAssertEqual(capture.audioFormat?.sampleRate, 48000, "The host's WAV keeps one rate")
        let input = AVAudioPCMBuffer(pcmFormat: hal.format, frameCapacity: 2400)!
        input.frameLength = 2400
        for channel in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
            let samples = channel.mData!.assumingMemoryBound(to: Float.self)
            for index in 0..<2400 { samples[index] = sinf(Float(index) * 0.05) * 0.5 }
        }
        hal.now += 0.1
        capture.receiveForTesting(input)
        capture.drainForTesting()
        let frames = delivered.reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertTrue(delivered.allSatisfy { $0.format.sampleRate == 48000 })
        XCTAssertGreaterThan(frames, 3600, "2400 frames at 24 kHz are about 4800 at 48 kHz, less converter latency")
        XCTAssertLessThanOrEqual(frames, 4800 + 64)
    }

    func testAFlappingRouteStillEndsCleanly() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        for _ in 0..<CoreAudioSystemAudioCapture.maxFormatReconnects {
            capture.invalidateFormatForTesting()
            capture.drainForTesting()
        }
        XCTAssertEqual(hal.starts, 1 + CoreAudioSystemAudioCapture.maxFormatReconnects)
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
        capture.invalidateFormatForTesting()
        capture.drainForTesting()
        XCTAssertTrue(messages.last??.contains("format changed") == true)
    }

    // Telemetry (#1781): the per-recording counts that reach PostHog must
    // match what the tap actually did.
    func testDiagnosticsCountWakeAndStallReconnectsAndWhySystemAudioEnded() throws {
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        XCTAssertEqual(capture.diagnostics, .empty)
        capture.prepareForSystemSleep()
        capture.drainForTesting()
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        hal.now += 3.1
        capture.drainForTesting() // first stall reconnects
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        hal.now += 3.1
        capture.drainForTesting() // second stall ends system audio
        let diagnostics = capture.diagnostics
        XCTAssertEqual(diagnostics.sleeps, 1)
        XCTAssertEqual(diagnostics.wakeReconnects, 1)
        XCTAssertEqual(diagnostics.stallReconnects, 1)
        XCTAssertEqual(diagnostics.formatReconnects, 0)
        XCTAssertEqual(diagnostics.endReason, "no_buffers_after_reconnect")
    }

    func testDiagnosticsCountFormatReconnectsAndTheLimit() throws {
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        for _ in 0...CoreAudioSystemAudioCapture.maxFormatReconnects {
            capture.invalidateFormatForTesting()
            capture.drainForTesting()
        }
        XCTAssertEqual(capture.diagnostics.formatReconnects, CoreAudioSystemAudioCapture.maxFormatReconnects)
        XCTAssertEqual(capture.diagnostics.endReason, "format_change_limit")
    }

    func testCallbackLandingAfterFormatInvalidationStillReconnects() throws {
        // Deep review B1: the IOProc keeps running after the format listener
        // fires. A callback before the next drain tick used to be counted as
        // an overflow and end system audio, e.g. when a call app opened the
        // AirPods mic mid-meeting.
        let hal = HAL(), capture = hal.makeCapture()
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 2, interleaved: false)!
        capture.invalidateFormatForTesting()
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2, "A route change reconnects even when a callback beat the drain tick")
        XCTAssertEqual(capture.audioFormat?.sampleRate, 48000)
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
    }

    func testOverflowFromANewRouteReconnectsInsteadOfFailing() throws {
        // The listener can be late. Buffers that no longer fit, arriving
        // while the tap already reports a new format, are a route change.
        let hal = HAL(), capture = hal.makeCapture()
        var messages: [String?] = []
        let subscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime(subscription) {}; capture.stopSync() }
        try capture.start { _ in }
        overflow(capture, hal)
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 2, interleaved: false)!
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2)
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
    }

    func testFailedRebuildAfterWakeRetriesInsteadOfEndingSystemAudio() throws {
        // Deep review S4: every wake now builds the tap from scratch, and the
        // output may not be back yet. One failed build must not end system
        // audio for the meeting.
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        var messages: [String?] = []
        let recoverySubscription = capture.recoveryEventPublisher.sink { events.append($0) }
        let messageSubscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime((recoverySubscription, messageSubscription)) {}; capture.stopSync() }
        try capture.start { _ in }
        capture.prepareForSystemSleep()
        capture.drainForTesting()
        hal.rejectStart = true
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2)
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
        hal.now += 0.5
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2, "The retry waits for its delay")
        hal.rejectStart = false
        hal.now += CoreAudioSystemAudioCapture.rebuildRetryDelay(attempt: 1)
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 3)
        hal.now += 0.1
        capture.receiveForTesting(hal.buffer())
        capture.drainForTesting()
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first, .systemWake, "A retry keeps its first attempt's write-hold")
        guard case .gap = events.last else { return XCTFail("Missing recovery gap") }
        XCTAssertFalse(messages.contains { $0?.contains("failed") == true })
        XCTAssertFalse(messages.contains { $0?.contains("reconnecting") == true })
    }

    func testFailedRebuildRetriesAreBounded() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        var messages: [String?] = []
        let recoverySubscription = capture.recoveryEventPublisher.sink { events.append($0) }
        let messageSubscription = capture.errorMessagePublisher.sink { messages.append($0) }
        defer { withExtendedLifetime((recoverySubscription, messageSubscription)) {}; capture.stopSync() }
        try capture.start { _ in }
        hal.rejectStart = true
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        for attempt in 1...CoreAudioSystemAudioCapture.maxRebuildRetries {
            hal.now += CoreAudioSystemAudioCapture.rebuildRetryDelay(attempt: attempt)
            capture.drainForTesting()
        }
        XCTAssertEqual(hal.starts, 2 + CoreAudioSystemAudioCapture.maxRebuildRetries)
        XCTAssertTrue(messages.last??.contains("could not reconnect") == true)
        XCTAssertEqual(events, [.systemWake, .recoveryAbandoned], "The write-hold is released exactly once")
        hal.now += 60
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2 + CoreAudioSystemAudioCapture.maxRebuildRetries, "Nothing retries after giving up")
    }

    func testSecondSleepBeforeTheWakeReconnectStaysReleased() throws {
        // Deep review S5: a lid opened and closed again before the wake
        // reconnect ran. The tap stays released, and the missing-wake limit
        // counts from the latest sleep.
        let hal = HAL(), capture = hal.makeCapture()
        defer { capture.stopSync() }
        try capture.start { _ in }
        capture.prepareForSystemSleep()
        capture.drainForTesting()
        hal.now += 20
        capture.prepareForSystemSleep()
        capture.drainForTesting()
        hal.now += 20
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 1, "Nothing is attached before the second sleep's wake")
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2)
    }

    func testChangedFormatOnWakeIsKeptAtTheRecordingRate() throws {
        let hal = HAL(), capture = hal.makeCapture()
        var events: [SystemAudioRecoveryEvent] = []
        let subscription = capture.recoveryEventPublisher.sink { events.append($0) }
        try capture.start { _ in }
        hal.format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        capture.recoverAfterSystemWake()
        capture.drainForTesting()
        XCTAssertEqual(hal.starts, 2, "A new output rate after wake reconnects instead of failing")
        XCTAssertEqual(events, [.systemWake])
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
