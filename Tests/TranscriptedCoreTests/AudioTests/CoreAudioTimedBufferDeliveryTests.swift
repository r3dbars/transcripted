import XCTest
import AVFoundation
import CoreAudio
import Combine
@testable import TranscriptedCore

final class CoreAudioTimedBufferDeliveryTests: XCTestCase {
    private final class HAL: @unchecked Sendable {
        var format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        func capture() -> CoreAudioSystemAudioCapture {
            CoreAudioSystemAudioCapture(hardwareHooks: .init(
                prepare: { self.format }, start: {}, stop: {}, currentFormat: { self.format }
            ), clock: { 100 })
        }
        func buffer() -> AVAudioPCMBuffer {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128)!
            buffer.frameLength = 128
            for item in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                memset(item.mData!, 0, Int(item.mDataByteSize))
            }
            return buffer
        }
    }

    private func stamp(_ host: UInt64, _ sample: Double) -> AudioTimeStamp {
        var stamp = AudioTimeStamp()
        stamp.mHostTime = host
        stamp.mSampleTime = sample
        stamp.mFlags = [.hostTimeValid, .sampleTimeValid]
        return stamp
    }

    func testDirectPCMDeliversTheStampOfEachExactRingSlot() throws {
        let hal = HAL(), capture = hal.capture()
        var timing: [SystemAudioBufferTiming] = []
        try capture.startTimed { _, stamp in timing.append(stamp) }
        defer { capture.stopSync() }
        capture.receiveForTesting(hal.buffer(), timestamp: stamp(1_000, 20))
        capture.receiveForTesting(hal.buffer(), timestamp: stamp(2_000, 148))
        capture.drainForTesting()
        XCTAssertEqual(timing.map(\.firstSampleHostTime), [1_000, 2_000])
        XCTAssertEqual(timing.map(\.sampleTime), [20, 148])
        XCTAssertEqual(timing.map(\.sampleRate), [48_000, 48_000])
        XCTAssertEqual(timing[0].continuityID, timing[1].continuityID)
    }

    func testFinishingTailKeepsTheOriginalTapEpochAndStamp() throws {
        let hal = HAL(), capture = hal.capture()
        var timing: [SystemAudioBufferTiming] = []
        try capture.startTimed { _, stamp in timing.append(stamp) }
        capture.receiveForTesting(hal.buffer(), timestamp: stamp(1_000, 0))
        capture.drainForTesting()
        capture.receiveForTesting(hal.buffer(), timestamp: stamp(2_000, 128))
        capture.finishAndDrain()
        XCTAssertEqual(timing.count, 2)
        XCTAssertEqual(timing.last?.firstSampleHostTime, 2_000)
        XCTAssertEqual(timing.first?.continuityID, timing.last?.continuityID)
    }

    func testReentrantGapSubscriberCannotRelabelThePCMSlot() throws {
        let hal = HAL(), capture = hal.capture()
        var delivered: [(Float, UInt64?)] = []
        try capture.startTimed { buffer, timing in
            delivered.append((buffer.floatChannelData![0][0], timing.firstSampleHostTime))
        }
        defer { capture.stopSync() }
        let first = hal.buffer(), second = hal.buffer()
        first.floatChannelData![0][0] = 0.25
        second.floatChannelData![0][0] = 0.5
        capture.receiveForTesting(first, timestamp: stamp(1_000, 0))
        capture.receiveForTesting(second, timestamp: stamp(2_000, 128))
        let subscriber = capture.recoveryEventPublisher.sink { event in
            if case .gap = event { capture.drainForTesting() }
        }
        capture.queue.sync { capture.recoveryStarted = 99 }
        capture.drainForTesting()
        withExtendedLifetime(subscriber) {}
        XCTAssertEqual(delivered.count, 2)
        XCTAssertEqual(delivered.first { $0.0 == 0.25 }?.1, 1_000)
        XCTAssertEqual(delivered.first { $0.0 == 0.5 }?.1, 2_000)
    }

    func testSleepTailKeepsItsEpochButRebuiltTapHasANewOne() throws {
        let hal = HAL(), capture = hal.capture()
        var timing: [SystemAudioBufferTiming] = []
        try capture.startTimed { _, stamp in timing.append(stamp) }
        defer { capture.stopSync() }
        capture.receiveForTesting(hal.buffer(), timestamp: stamp(1_000, 0))
        capture.prepareForSystemSleep()
        capture.recoverAfterSystemWake()
        capture.receiveForTesting(hal.buffer(), timestamp: stamp(2_000, 128))
        capture.drainForTesting()
        XCTAssertEqual(timing.count, 2)
        XCTAssertEqual(timing.map(\.firstSampleHostTime), [1_000, 2_000])
        XCTAssertNotEqual(timing[0].continuityID, timing[1].continuityID)
    }

    func testInvalidFlagsCannotTurnStoredNumbersIntoTimingEvidence() throws {
        let hal = HAL(), capture = hal.capture()
        var timing: SystemAudioBufferTiming?
        try capture.startTimed { _, stamp in timing = stamp }
        defer { capture.stopSync() }
        var invalid = stamp(1_000, 200)
        invalid.mFlags = []
        capture.receiveForTesting(hal.buffer(), timestamp: invalid)
        capture.drainForTesting()
        XCTAssertNil(timing?.firstSampleHostTime)
        XCTAssertNil(timing?.sampleTime)
    }

    func testResamplingNeverLabelsOutputWithCurrentInputTimestamp() throws {
        let hal = HAL(), capture = hal.capture()
        var timing: [SystemAudioBufferTiming] = []
        try capture.startTimed { _, stamp in timing.append(stamp) }
        defer { capture.stopSync() }
        hal.format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        capture.invalidateFormatForTesting()
        capture.drainForTesting()
        capture.receiveForTesting(hal.buffer(), timestamp: stamp(1_000, 0))
        capture.drainForTesting()
        XCTAssertFalse(timing.isEmpty)
        XCTAssertTrue(timing.allSatisfy { $0 == .unavailable })
    }
}
