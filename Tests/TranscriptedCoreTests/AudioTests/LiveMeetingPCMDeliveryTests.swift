import XCTest
import AVFoundation
@testable import TranscriptedCore

final class LiveMeetingPCMDeliveryTests: XCTestCase {
    private func buffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        result.frameLength = 16
        for index in 0..<16 { result.floatChannelData![0][index] = 0.1 }
        return result
    }

    func testDisabledPreviewDoesNotDeliverAudio() {
        let delivery = LiveMeetingPCMDelivery()
        let flushed = expectation(description: "disabled preview flushed")
        delivery.enqueue(buffer(), source: .system) { _, _, _, _ in XCTFail("disabled preview must not expose audio") }
        delivery.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
        XCTAssertEqual(delivery.dropCount, 0)
    }

    func testStalledPreviewDropsWithoutWaitingAndRetainsOwnedBuffer() {
        let pcm = buffer()
        let delivery = LiveMeetingPCMDelivery(byteLimit: PCMBufferBackpressureGate.retainedByteCount(for: pcm))
        let entered = expectation(description: "first consumer entered")
        let flushed = expectation(description: "bounded queue drained")
        let release = DispatchSemaphore(value: 0)
        delivery.setEnabled(true)
        delivery.enqueue(pcm, source: .microphone) { received, source, time, _ in
            XCTAssertEqual(source, .microphone)
            XCTAssertTrue(time.isFinite)
            XCTAssertEqual(received.floatChannelData![0][0], 0.1)
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        wait(for: [entered], timeout: 5)
        // This call is synchronous admission only. It must return even though
        // the first callback has not been released, and it never closes capture.
        delivery.enqueue(pcm, source: .system) { _, _, _, _ in XCTFail("overflow must be dropped") }
        XCTAssertEqual(delivery.dropCount, 1)
        release.signal()
        delivery.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)
    }

    func testDisableInvalidatesAlreadyQueuedAudioAcrossSharingSessions() {
        let delivery = LiveMeetingPCMDelivery()
        let entered = expectation(description: "first callback admitted")
        let drained = expectation(description: "old queue drained")
        let release = DispatchSemaphore(value: 0)
        delivery.setEnabled(true)
        delivery.enqueue(buffer(), source: .microphone) { _, _, _, _ in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
        }
        wait(for: [entered], timeout: 5)
        delivery.enqueue(buffer(), source: .system) { _, _, _, _ in XCTFail("old sharing generation must not reach the new session") }
        delivery.setEnabled(false)
        delivery.setEnabled(true)
        release.signal()
        delivery.flush { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func testPreviousRecordingCannotDeliverIntoNewCapture() {
        let delivery = LiveMeetingPCMDelivery()
        let drained = expectation(description: "stale capture ignored")
        delivery.setEnabled(true, captureGeneration: 2)
        delivery.enqueue(buffer(), source: .system, captureGeneration: 1) { _, _, _, _ in
            XCTFail("a previous recording's late buffer must not enter a new call")
        }
        delivery.flush { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }

    func testInFlightCallbackKeepsItsOriginalSharingLease() {
        let delivery = LiveMeetingPCMDelivery()
        let entered = expectation(description: "old callback began conversion")
        let drained = expectation(description: "old callback completed conversion")
        let release = DispatchSemaphore(value: 0)
        delivery.setEnabled(true, previewEpoch: 10)
        delivery.enqueue(buffer(), source: .system) { _, _, _, epoch in
            entered.fulfill()
            _ = release.wait(timeout: .now() + 5)
            XCTAssertEqual(epoch, 10, "conversion must validate this old lease, never adopt the new sharing session")
        }
        wait(for: [entered], timeout: 5)
        delivery.setEnabled(false, previewEpoch: 10)
        delivery.setEnabled(true, previewEpoch: 11)
        release.signal()
        delivery.flush { drained.fulfill() }
        wait(for: [drained], timeout: 5)
    }
}
