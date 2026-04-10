// RecordedAudioTimelineTests.swift
// Tests for multi-segment dictation audio buffering across microphone handoffs.

import Foundation

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
}
