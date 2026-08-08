// RecordedAudioTimelineTests.swift
// Tests for multi-segment dictation audio buffering across microphone handoffs.

import AVFoundation
import Foundation

private func makeSharedMicTestBuffer(
    channels: [[Float]],
    sampleRate: Double = 48_000
) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: sampleRate,
        channels: AVAudioChannelCount(channels.count),
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(
        pcmFormat: format,
        frameCapacity: AVAudioFrameCount(channels.first?.count ?? 0)
    )!
    buffer.frameLength = buffer.frameCapacity
    for (channelIndex, samples) in channels.enumerated() {
        guard let destination = buffer.floatChannelData?[channelIndex] else { continue }
        for (sampleIndex, sample) in samples.enumerated() {
            destination[sampleIndex] = sample
        }
    }
    return buffer
}

func testRecordedAudioTimeline() {
    runSuite("RecordedAudioTimeline.append — merges consecutive chunks with the same sample rate") {
        var timeline = RecordedAudioTimeline()
        timeline.append([0.1, 0.2], sampleRate: 48_000)
        timeline.append([0.3], sampleRate: 48_000)

        assertEqual(timeline.segments.count, 1, "matching sample rates should stay in one segment")
        assertEqual(timeline.segments.first?.samples.count, 3, "samples should append onto the active segment")
        assertEqual(timeline.totalSourceSampleCount, 3, "total sample count should reflect merged audio")
    }

    runSuite("RecordedAudioTimeline.append — preserves segment boundaries when the sample rate changes") {
        var timeline = RecordedAudioTimeline()
        timeline.append([0.1, 0.2], sampleRate: 48_000)
        timeline.append([0.3, 0.4], sampleRate: 24_000)

        assertEqual(timeline.segments.count, 2, "sample rate changes should start a new segment")
        assertEqual(timeline.segments.map(\.sampleRate), [48_000, 24_000], "segment metadata should preserve each source rate")
        assertEqual(timeline.totalDurationSeconds, (2.0 / 48_000.0) + (2.0 / 24_000.0), "duration should sum across all segments")
    }

    runSuite("RecordedAudioTimeline.drain — returns buffered segments and clears the timeline") {
        var timeline = RecordedAudioTimeline()
        timeline.append([0.1, 0.2], sampleRate: 48_000)
        timeline.append([0.3], sampleRate: 24_000)

        let drained = timeline.drain()

        assertEqual(drained.count, 2, "drain should hand back every buffered segment")
        assertTrue(timeline.isEmpty, "drain should clear the in-memory timeline")
        assertEqual(timeline.totalSourceSampleCount, 0, "cleared timelines should report zero samples")
    }

    runSuite("RecordedAudioTimeline.append — drops invalid and non-finite sample rates") {
        var timeline = RecordedAudioTimeline()

        for sampleRate in [0, -1, Double.nan, Double.infinity, -Double.infinity, 1, 7_999, 384_001] {
            timeline.append([0.1, 0.2], sampleRate: sampleRate)
        }

        assertTrue(timeline.isEmpty, "invalid sample rates should not create timeline segments")
        timeline.append([0.3], sampleRate: 48_000)
        assertEqual(timeline.segments.count, 1, "valid sample rates should still append")
    }

    runSuite("SharedMeetingMicRecorder records only while armed") {
        let recorder = SharedMeetingMicRecorder()
        let buffer = makeSharedMicTestBuffer(channels: [[0.1, 0.2]])

        recorder.append(buffer)
        assertTrue(recorder.finish().isEmpty, "buffers before begin should be ignored")

        recorder.begin()
        recorder.append(buffer)
        let captured = recorder.finish()
        assertEqual(captured.segments.count, 1, "active meeting mic buffers should be captured")
        assertEqual(captured.segments[0].samples, [0.1, 0.2], "captured mono samples should remain unchanged")

        recorder.append(buffer)
        assertTrue(recorder.finish().isEmpty, "buffers after finish should be ignored")
    }

    runSuite("Shared meeting mic path always records borrowed PCM") {
        let source = (try? String(
            contentsOfFile: "Sources/Speech/ParakeetSharedMeetingMicBridge.swift",
            encoding: .utf8
        )) ?? ""
        guard let start = source.range(of: "nonisolated func appendSharedMeetingMicBuffer"),
              let end = source.range(of: "func updateSharedMeetingMicAudioLevel", range: start.upperBound..<source.endIndex) else {
            assertTrue(false, "shared meeting mic append method should remain present")
            return
        }
        let appendBody = String(source[start.lowerBound..<end.lowerBound])
        assertTrue(
            appendBody.contains("sharedMeetingMicRecorder.append(buffer)"),
            "borrowed meeting PCM should always reach the recorder"
        )
        assertFalse(
            appendBody.contains("liveDisplayEnabled"),
            "recording borrowed meeting PCM must not depend on a provisional-text feature gate"
        )
    }

    runSuite("SharedMeetingMicRecorder downmixes stereo and preserves route sample-rate changes") {
        let recorder = SharedMeetingMicRecorder()
        recorder.begin()
        recorder.append(makeSharedMicTestBuffer(channels: [[0.2, 0.4], [0.4, 0.8]], sampleRate: 48_000))
        recorder.append(makeSharedMicTestBuffer(channels: [[0.5]], sampleRate: 24_000))

        let captured = recorder.finish()
        assertEqual(captured.segments.count, 2, "sample-rate changes should remain separate for safe resampling")
        assertEqual(captured.segments[0].samples, [0.3, 0.6], "stereo meeting PCM should downmix to mono")
        assertEqual(captured.segments.map(\.sampleRate), [48_000, 24_000], "each route format should be preserved")
    }

    runSuite("SharedMeetingMicRecorder cancel discards borrowed dictation audio") {
        let recorder = SharedMeetingMicRecorder()
        recorder.begin()
        recorder.append(makeSharedMicTestBuffer(channels: [[0.1, 0.2, 0.3]]))
        recorder.cancel()
        assertTrue(recorder.finish().isEmpty, "cancel should not leak samples into the next dictation")
    }

    runSuite("MeetingMicPCMRelay never coalesces buffers admitted by Core") {
        let relay = MeetingMicPCMRelay()
        var receivedSamples: [Float] = []

        relay.setDictationHandler { buffer in
            guard let sample = buffer.floatChannelData?[0][0] else { return }
            receivedSamples.append(sample)
        }

        let expectedSamples = (0..<128).map(Float.init)
        for sample in expectedSamples {
            relay.enqueue(makeSharedMicTestBuffer(channels: [[sample]]))
        }
        assertEqual(receivedSamples, expectedSamples, "every admitted buffer should be delivered once and in order")

        relay.setDictationHandler(nil)
        relay.enqueue(makeSharedMicTestBuffer(channels: [[999]]))
        assertEqual(receivedSamples, expectedSamples, "an inactive consumer should receive no later buffers")
    }

    runSuite("SharedMeetingMicTransitionState rejects a resume invalidated by dictation stop") {
        var state = SharedMeetingMicTransitionState()
        state.beginSharedRecording()
        let resumeToken = state.beginResume()

        state.invalidate()

        assertFalse(
            state.finishResume(token: resumeToken),
            "a stop during async mic resume must prevent the resumed engine from becoming active"
        )
        assertFalse(state.isResumeInProgress, "invalidated resume state should settle immediately")
    }

    runSuite("SharedMeetingMicTransitionState accepts only the current resume") {
        var state = SharedMeetingMicTransitionState()
        state.beginSharedRecording()
        let resumeToken = state.beginResume()

        assertTrue(state.finishResume(token: resumeToken), "the current uninterrupted resume should complete")
        assertFalse(state.finishResume(token: resumeToken), "a completed resume token must be one-shot")
    }
}
