import Foundation

func testDictationMeterPolicy() {
    runSuite("DictationMeterPolicy hides meter outside active recording") {
        let loading = DictationMeterPolicy.presentation(
            isListening: false,
            sttIsRecording: false,
            rawLevel: 0.8
        )
        assertEqual(loading, .init(isVisible: false, level: 0), "loading should not show stale audio")

        let starting = DictationMeterPolicy.presentation(
            isListening: true,
            sttIsRecording: false,
            rawLevel: 0.8
        )
        assertEqual(starting, .init(isVisible: false, level: 0), "listening UI should wait for real recording")

        let drafting = DictationMeterPolicy.presentation(
            isListening: false,
            sttIsRecording: true,
            rawLevel: 0.8
        )
        assertEqual(drafting, .init(isVisible: false, level: 0), "drafting should clear the meter")
    }

    runSuite("DictationMeterPolicy shows quiet startup waveform when requested") {
        let quietStartup = DictationMeterPolicy.presentation(
            isListening: false,
            sttIsRecording: false,
            rawLevel: 0.8,
            showsQuietStartupWaveform: true
        )
        assertEqual(
            quietStartup,
            .init(isVisible: true, level: 0),
            "mini cursor startup should show a flat quiet waveform instead of text"
        )
    }

    runSuite("DictationMeterPolicy shows clamped level while listening and recording") {
        let visible = DictationMeterPolicy.presentation(
            isListening: true,
            sttIsRecording: true,
            rawLevel: 0.4
        )
        assertEqual(visible, .init(isVisible: true, level: 0.4), "active recording should show the live level")

        let high = DictationMeterPolicy.presentation(
            isListening: true,
            sttIsRecording: true,
            rawLevel: 4
        )
        assertEqual(high, .init(isVisible: true, level: 1), "raw levels should clamp high")

        let low = DictationMeterPolicy.presentation(
            isListening: true,
            sttIsRecording: true,
            rawLevel: -1
        )
        assertEqual(low, .init(isVisible: true, level: 0), "raw levels should clamp low")
    }

    runSuite("The waveform shows a reading only while listening and recording, clamped, peak never below level") {
        let reading = DictationAudioLevel(level: 0.4, peak: 0.7)
        assertEqual(
            DictationMeterPolicy.presentation(isListening: false, sttIsRecording: true, reading: reading),
            .silent,
            "not listening should show silence"
        )
        assertEqual(
            DictationMeterPolicy.presentation(isListening: true, sttIsRecording: false, reading: reading),
            .silent,
            "not recording yet should show silence"
        )
        assertEqual(
            DictationMeterPolicy.presentation(isListening: false, sttIsRecording: false, reading: reading),
            .silent,
            "idle should show silence"
        )

        let live = DictationMeterPolicy.presentation(isListening: true, sttIsRecording: true, reading: reading)
        assertEqual(live.level, 0.4, "an in-range level passes through")
        assertEqual(live.peak, 0.7, "an in-range peak passes through")

        let high = DictationMeterPolicy.presentation(isListening: true, sttIsRecording: true, reading: DictationAudioLevel(level: 4))
        assertEqual(high.level, 1, "level clamps high")
        assertEqual(high.peak, 1, "peak clamps high")

        let low = DictationMeterPolicy.presentation(isListening: true, sttIsRecording: true, reading: DictationAudioLevel(level: -1, peak: -2))
        assertEqual(low.level, 0, "level clamps low")
        assertEqual(low.peak, 0, "peak clamps low")

        // A reading can't carry a peak below its level (its initializer raises
        // it), and the policy's clamping keeps that true.
        let fixed = DictationMeterPolicy.presentation(
            isListening: true, sttIsRecording: true, reading: DictationAudioLevel(level: 0.6, peak: 0.2)
        )
        assertEqual(fixed.level, 0.6, "level passes through")
        assertTrue(fixed.peak >= 0.6, "peak should never be below the level, got \(fixed.peak)")

        let clampedThenRaised = DictationMeterPolicy.presentation(
            isListening: true, sttIsRecording: true, reading: DictationAudioLevel(level: 4, peak: 0.5)
        )
        assertEqual(clampedThenRaised.level, 1, "level clamps high")
        assertEqual(clampedThenRaised.peak, 1, "peak should be raised to the clamped level")
    }
}
