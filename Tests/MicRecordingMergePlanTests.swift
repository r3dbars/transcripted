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

        for sampleRate in [0.0, -1.0, Double.nan, Double.infinity, -Double.infinity, 7_999.0, 384_001.0] {
            assertEqual(
                MicRecordingMergePlan.silenceSampleCount(before: segment, sampleRate: sampleRate),
                0,
                "invalid sample rates should not request silence samples"
            )
        }
    }

    runSuite("MicRecordingSegment — clamps non-finite gap durations") {
        for gap in [Double.nan, Double.infinity, -Double.infinity] {
            let segment = MicRecordingSegment(
                url: URL(fileURLWithPath: "/tmp/recovery.wav"),
                gapBeforeDuration: gap
            )

            assertEqual(segment.gapBeforeDuration, 0, "non-finite recovery gaps should clamp to zero")
            assertEqual(
                MicRecordingMergePlan.silenceSampleCount(before: segment, sampleRate: 16_000),
                0,
                "non-finite gaps should not insert silence"
            )
        }
    }

    runSuite("MicRecordingMergePlan.silenceSampleCount — rejects unsafe gap math") {
        let segment = MicRecordingSegment(
            url: URL(fileURLWithPath: "/tmp/recovery.wav"),
            gapBeforeDuration: Double.greatestFiniteMagnitude
        )

        assertEqual(
            MicRecordingMergePlan.silenceSampleCount(before: segment, sampleRate: 16_000),
            0,
            "overflowing silence math should fail closed"
        )
    }
}
