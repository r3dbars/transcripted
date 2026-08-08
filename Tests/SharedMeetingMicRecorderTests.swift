import AVFoundation
import Foundation

private func makeMonoBuffer(frameCount: Int, sampleRate: Double = 48_000, value: Float = 0.5) -> AVAudioPCMBuffer? {
    guard let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: 1,
        interleaved: false
    ),
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
    let data = buffer.floatChannelData else { return nil }

    buffer.frameLength = AVAudioFrameCount(frameCount)
    for frame in 0..<frameCount {
        data[0][frame] = value
    }
    return buffer
}

func testSharedMeetingMicRecorder() {
    // These cover the primitive `ParakeetEngine.finalizeStaleSharedMeetingMicClaim()`
    // depends on: a stale-claim finalize routes through
    // `finishSharedMeetingMicRecording`, which calls
    // `sharedMeetingMicRecorder.finish()` to drain buffered borrowed audio
    // into `recoveredRecordingTimeline` before the claim is cleared.
    // ParakeetEngine itself isn't in the fast-test seam (AVAudioEngine/
    // FluidAudio dependencies), so this is the closest pure-primitive level
    // that can exercise the drain-before-clear contract.
    runSuite("SharedMeetingMicRecorder.finish drains buffered samples appended after begin()") {
        guard let buffer = makeMonoBuffer(frameCount: 4) else {
            assertTrue(false, "expected test buffer to be created")
            return
        }

        let recorder = SharedMeetingMicRecorder()
        recorder.begin()
        recorder.append(buffer)
        var timeline = recorder.finish()

        assertFalse(
            timeline.isEmpty,
            "finish() must return whatever was appended since begin() — a stale-claim finalize relies on this to avoid silently discarding the user's borrowed audio"
        )
        assertEqual(
            timeline.totalSourceSampleCount,
            4,
            "all appended frames must be present in the drained timeline"
        )
        let segments = timeline.drain()
        assertFalse(segments.isEmpty, "drain() should hand back the segments finish() collected")
    }

    runSuite("SharedMeetingMicRecorder.finish clears its buffer — a second finish() drains nothing") {
        guard let buffer = makeMonoBuffer(frameCount: 4) else {
            assertTrue(false, "expected test buffer to be created")
            return
        }

        let recorder = SharedMeetingMicRecorder()
        recorder.begin()
        recorder.append(buffer)
        _ = recorder.finish()
        let secondFinish = recorder.finish()

        assertTrue(
            secondFinish.isEmpty,
            "finish() must clear after draining — a repeated stale-resolution check must not double-count or resurrect already-drained audio"
        )
    }

    runSuite("SharedMeetingMicRecorder.finish returns an empty timeline when nothing was appended") {
        let recorder = SharedMeetingMicRecorder()
        recorder.begin()
        let timeline = recorder.finish()
        assertTrue(timeline.isEmpty, "no buffers appended means nothing to drain")
    }

    runSuite("SharedMeetingMicRecorder.append before begin() is dropped, not buffered") {
        guard let buffer = makeMonoBuffer(frameCount: 4) else {
            assertTrue(false, "expected test buffer to be created")
            return
        }

        let recorder = SharedMeetingMicRecorder()
        recorder.append(buffer) // no begin() yet
        let timeline = recorder.finish()
        assertTrue(timeline.isEmpty, "samples appended before begin() must not leak into the next share")
    }

    runSuite("SharedMeetingMicRecorder caps retained borrowed audio") {
        guard let buffer = makeMonoBuffer(frameCount: 10) else {
            assertTrue(false, "expected test buffer to be created")
            return
        }

        let recorder = SharedMeetingMicRecorder(maxDurationSeconds: 0.00011)
        recorder.begin()
        recorder.append(buffer)
        recorder.append(buffer)
        let timeline = recorder.finish()

        assertEqual(timeline.totalSourceSampleCount, 5, "borrowed audio must stop growing at its duration cap")
    }
}
