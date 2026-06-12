import XCTest
@testable import TranscriptedCore

final class QuietMicAttenuationDetectorTests: XCTestCase {

    // MARK: - Helpers

    /// One tick with a physically realizable interval summary. The live
    /// pipeline measures processedPeak after RealtimeAGC multiplies the same
    /// buffer copy (AudioFileManager.handleMicBuffer), so fixtures derive it
    /// as raw × gain (hard-clipped to 1.0) instead of inventing independent
    /// values the pipeline could never produce. The default rawPeak (0.004)
    /// qualifies at the gain pin (0.004 × 25 = 0.10 < 0.12) and is above the
    /// activity floor so it also counts toward the activity requirement.
    private func qualifyingTick(
        _ detector: inout QuietMicAttenuationDetector,
        rawPeak: Float = 0.004,
        appliedGain: Float? = 25,
        agcMaxGain: Float? = 25,
        sawBuffer: Bool = true
    ) -> Bool {
        detector.consume(
            rawPeak: rawPeak,
            processedPeak: min(1.0, rawPeak * (appliedGain ?? 1)),
            appliedGain: appliedGain,
            agcMaxGain: agcMaxGain,
            sawBuffer: sawBuffer
        )
    }

    // MARK: - Tests

    func testSustainedAttenuationFiresOnceAfterWindow() {
        var detector = QuietMicAttenuationDetector()
        for tick in 1..<150 {
            XCTAssertFalse(qualifyingTick(&detector), "must not fire before the 30s window (tick \(tick))")
        }
        XCTAssertTrue(qualifyingTick(&detector), "should fire exactly at tick 150 (30s at 0.2s ticks)")
        for tick in 151...300 {
            XCTAssertFalse(qualifyingTick(&detector), "one-shot latch must suppress repeat fires (tick \(tick))")
        }
    }

    func testLoudMeetingNeverFires() {
        var detector = QuietMicAttenuationDetector()
        for tick in 1...300 {
            XCTAssertFalse(
                qualifyingTick(&detector, rawPeak: 0.4, appliedGain: 1, agcMaxGain: 25),
                "a healthy loud mic must never prompt (tick \(tick))"
            )
        }
    }

    func testBriefQuietThenLoudResetsStreak() {
        var detector = QuietMicAttenuationDetector()
        for _ in 1...100 {
            XCTAssertFalse(qualifyingTick(&detector))
        }
        // One loud tick (mute button released, cough, etc.) resets the streak.
        XCTAssertFalse(qualifyingTick(&detector, rawPeak: 0.4, appliedGain: 1))
        for tick in 1...149 {
            XCTAssertFalse(qualifyingTick(&detector), "post-reset streak of 149 must not fire (tick \(tick))")
        }
    }

    func testGainNotPinnedNeverFires() {
        var detector = QuietMicAttenuationDetector()
        for tick in 1...300 {
            XCTAssertFalse(
                qualifyingTick(&detector, appliedGain: 10, agcMaxGain: 25),
                "AGC with headroom left means gain can still recover the mic (tick \(tick))"
            )
        }
    }

    func testAGCInactiveNeverFires() {
        var detector = QuietMicAttenuationDetector()
        for tick in 1...300 {
            XCTAssertFalse(
                qualifyingTick(&detector, appliedGain: nil, agcMaxGain: nil),
                "VPIO on / AGC absent must keep the detector dormant (tick \(tick))"
            )
        }
    }

    func testMissingBuffersResetStreak() {
        var detector = QuietMicAttenuationDetector()
        for _ in 1...100 {
            XCTAssertFalse(qualifyingTick(&detector))
        }
        // Device-recovery gap: no buffers this interval.
        XCTAssertFalse(qualifyingTick(&detector, sawBuffer: false))
        for tick in 1...149 {
            XCTAssertFalse(qualifyingTick(&detector), "recovery gap must restart the streak (tick \(tick))")
        }
        XCTAssertTrue(qualifyingTick(&detector), "a full fresh 150-tick streak after the gap should fire")
    }

    func testZeroRawPeakNeverFires() {
        var detector = QuietMicAttenuationDetector()
        for tick in 1...300 {
            XCTAssertFalse(
                qualifyingTick(&detector, rawPeak: 0),
                "a muted mic (zero raw peak) must never prompt (tick \(tick))"
            )
        }
    }

    func testSilentRoomWithoutActivityNeverFires() {
        var detector = QuietMicAttenuationDetector()
        // Quiet-but-qualifying ambient noise below the 0.002 activity floor:
        // streak grows past the window but no fire without voice-like energy.
        for tick in 1...200 {
            XCTAssertFalse(
                qualifyingTick(&detector, rawPeak: 0.001),
                "a silent room must never prompt (tick \(tick))"
            )
        }
        // The user starts speaking (still attenuated): 25 activity ticks
        // complete the requirement and fire.
        for tick in 1..<25 {
            XCTAssertFalse(qualifyingTick(&detector), "activity requirement is 5s = 25 ticks (tick \(tick))")
        }
        XCTAssertTrue(qualifyingTick(&detector), "voice-like energy should complete the latched streak")
    }

    func testLatchSuppressesSecondFire() {
        var detector = QuietMicAttenuationDetector()
        for _ in 1..<150 {
            XCTAssertFalse(qualifyingTick(&detector))
        }
        XCTAssertTrue(qualifyingTick(&detector))
        for tick in 1...300 {
            XCTAssertFalse(qualifyingTick(&detector), "latched detector must stay silent (tick \(tick))")
        }
    }

    func testTickIntervalDerivation() {
        var detector = QuietMicAttenuationDetector(tickInterval: 0.1)
        for tick in 1..<300 {
            XCTAssertFalse(qualifyingTick(&detector), "0.1s ticks need 300 ticks for 30s (tick \(tick))")
        }
        XCTAssertTrue(qualifyingTick(&detector), "should fire at tick 300 with a 0.1s cadence")
    }

    func testRealisticPinnedGainQuietStreamFires() {
        // End-to-end-shaped regression case for the constants' interplay:
        // 30s of raw peaks spanning the only physically realizable quiet band
        // [activityRawPeakFloor, usableThreshold / maxGain) with the AGC
        // pinned at its default max gain must fire. If the activity floor
        // ever creeps above usableThreshold / maxGain again, every activity
        // tick disqualifies itself (processed = raw × gain ≥ 0.12) and this
        // test catches the detector going dead.
        var detector = QuietMicAttenuationDetector()
        let maxGain = RealtimeAGC().maxGain
        let rawPeaks: [Float] = [0.002, 0.003, 0.0045]
        var fired = false
        for tick in 1...150 {
            let rawPeak = rawPeaks[tick % rawPeaks.count]
            let didFire = detector.consume(
                rawPeak: rawPeak,
                processedPeak: min(1.0, rawPeak * maxGain),
                appliedGain: maxGain,
                agcMaxGain: maxGain,
                sawBuffer: true
            )
            if tick < 150 {
                XCTAssertFalse(didFire, "must not fire before the 30s window (tick \(tick))")
            }
            fired = didFire
        }
        XCTAssertTrue(fired, "a realistic pinned-gain quiet stream must fire at tick 150")
    }

    func testActivityFloorIsReachableUnderPinnedGain() {
        // Constants-consistency guard: processed = raw × gain in the live
        // pipeline, so an activity tick (raw ≥ activityRawPeakFloor) at the
        // AGC pin must still land under the usable-processed bar — with
        // margin — or the activity requirement can never accumulate inside a
        // qualifying streak and the live prompt becomes unreachable.
        let agc = RealtimeAGC()
        XCTAssertLessThanOrEqual(
            QuietMicAttenuationDetector.activityRawPeakFloor * agc.maxGain,
            QuietMicAttenuationDetector.usableMicProcessedPeakThreshold * 0.5,
            "activity floor × default AGC max gain must stay under half the usable-processed bar"
        )
        XCTAssertGreaterThan(
            QuietMicAttenuationDetector.activityRawPeakFloor,
            agc.minPeak,
            "activity floor must stay above the AGC ambient/silence floor so a silent room never prompts"
        )
        XCTAssertGreaterThanOrEqual(
            QuietMicAttenuationDetector.activityRawPeakFloor,
            agc.noiseGatePeak,
            "activity floor must stay at or above the AGC noise gate so #500 prompts remain reachable"
        )
    }

    func testThresholdsMatchStopTimeClassification() {
        // Cross-target agreement guard: these literals are duplicated in the
        // app-side MeetingCaptureVolumeDiagnostics (MeetingCaptureSupport.swift)
        // because the fast-test runner cannot link Core. If either side moves,
        // both tests must move together.
        XCTAssertEqual(QuietMicAttenuationDetector.quietMicRawPeakThreshold, 0.05)
        XCTAssertEqual(QuietMicAttenuationDetector.usableMicProcessedPeakThreshold, 0.12)
    }
}
