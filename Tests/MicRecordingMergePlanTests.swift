// MicRecordingMergePlanTests.swift
// Tests for gap-aware mic segment merge planning.

import Foundation

func testMicRecordingMergePlan() {
    runSuite("MicRecordingMergePlan.silenceSampleCount — converts gap duration to samples") {
        let segment = MicRecordingSegment(
            url: URL(fileURLWithPath: "/tmp/recovery.wav"),
            gapBeforeDuration: 0.25
        )

        assertEqual(
            MicRecordingMergePlan.silenceSampleCount(before: segment, sampleRate: 16_000),
            4_000,
            "250ms gap should become 4,000 silence samples at 16kHz"
        )
    }

    runSuite("MicRecordingSegment — clamps negative gap durations") {
        let segment = MicRecordingSegment(
            url: URL(fileURLWithPath: "/tmp/recovery.wav"),
            gapBeforeDuration: -1
        )

        assertEqual(segment.gapBeforeDuration, 0, "negative recovery gaps should clamp to zero")
        assertEqual(
            MicRecordingMergePlan.silenceSampleCount(before: segment, sampleRate: 16_000),
            0,
            "clamped gaps should not insert silence"
        )
    }

    runSuite("MicRecordingMergePlan.silenceSampleCount — guards invalid sample rates") {
        let segment = MicRecordingSegment(
            url: URL(fileURLWithPath: "/tmp/recovery.wav"),
            gapBeforeDuration: 0.5
        )

        assertEqual(
            MicRecordingMergePlan.silenceSampleCount(before: segment, sampleRate: 0),
            0,
            "invalid sample rates should not request silence samples"
        )
    }
}
