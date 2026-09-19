import XCTest
import AVFoundation
@testable import TranscriptedCore

final class CoreAudioTapBufferRingTests: XCTestCase {
    private func format(interleaved: Bool = false) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: interleaved)!
    }
    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = 8, value: Float) -> AVAudioPCMBuffer {
        let result = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        result.frameLength = frames
        for item in UnsafeMutableAudioBufferListPointer(result.mutableAudioBufferList) {
            item.mData!.assumingMemoryBound(to: Float.self).initialize(repeating: value, count: Int(item.mDataByteSize) / 4)
        }
        return result
    }
    private func push(_ ring: CoreAudioTapBufferRing, _ format: AVAudioFormat, frames: AVAudioFrameCount = 8, value: Float) {
        let input = buffer(format, frames: frames, value: value)
        withExtendedLifetime(input) { ring.push(input.audioBufferList) }
    }

    func testOwnsCopiedInterleavedAndPlanarSamples() {
        for interleaved in [false, true] {
            let format = format(interleaved: interleaved)
            let ring = CoreAudioTapBufferRing(format: format)
            let input = buffer(format, value: 0.25)
            ring.push(input.audioBufferList)
            for item in UnsafeMutableAudioBufferListPointer(input.mutableAudioBufferList) {
                memset(item.mData!, 0, Int(item.mDataByteSize))
            }
            let output = ring.pop(format: format)!
            XCTAssertEqual(output.frameLength, 8)
            for item in UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList) {
                XCTAssertEqual(item.mData!.assumingMemoryBound(to: Float.self)[0], 0.25)
            }
            XCTAssertNil(ring.pop(format: format))
        }
    }

    func testCapacityDropsNewestWithoutOverwritingUnreadBuffers() {
        let format = format()
        let ring = CoreAudioTapBufferRing(format: format, capacity: 2)
        for value in [Float(0.1), 0.2, 0.3] { push(ring, format, value: value) }
        XCTAssertEqual(ring.dropped.load(ordering: .relaxed), 1)
        let first = ring.pop(format: format)!
        let second = ring.pop(format: format)!
        withExtendedLifetime(first) { XCTAssertEqual(first.floatChannelData![0][0], 0.1) }
        withExtendedLifetime(second) { XCTAssertEqual(second.floatChannelData![0][0], 0.2) }
        XCTAssertNil(ring.pop(format: format))
        push(ring, format, value: 0.4)
        let fourth = ring.pop(format: format)!
        withExtendedLifetime(fourth) { XCTAssertEqual(fourth.floatChannelData![0][0], 0.4) }
    }

    func testOversizedAndInvalidatedInputRejectedButSilenceAccepted() {
        let format = format()
        let ring = CoreAudioTapBufferRing(format: format, maximumFrames: 8)
        push(ring, format, frames: 9, value: 1)
        XCTAssertNil(ring.pop(format: format))
        push(ring, format, value: 0)
        XCTAssertEqual(ring.pop(format: format)!.frameLength, 8)
        ring.formatInvalidated.store(true, ordering: .releasing)
        push(ring, format, value: 1)
        XCTAssertNil(ring.pop(format: format))
        XCTAssertEqual(ring.dropped.load(ordering: .relaxed), 2)
    }

    func testStopWithoutPreparationIsIdempotentAndDoesNotAcquirePermission() {
        let capture = CoreAudioSystemAudioCapture()
        capture.stopSync()
        capture.stop()
        XCTAssertNil(capture.audioFormat)
        XCTAssertEqual(capture.diagnosticBackendName, "core_audio_tap")
        XCTAssertTrue(capture.deliversOwnedAudioBuffers)
    }
}
