import Foundation

func testMeetingCaptureVolumeDiagnostics() {
    runSuite("MeetingCaptureVolumeDiagnostics flags route volume drops after stop") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.500",
                "default_input_volume_during": "0.500",
                "default_output_volume_before": "0.750",
                "default_output_volume_during": "0.750",
                "default_system_output_volume_before": "0.750",
                "default_system_output_volume_during": "0.750",
            ],
            afterStopContext: [
                "default_input_volume_after": "0.500",
                "default_output_volume_after": "0.500",
                "default_system_output_volume_after": "0.740",
            ]
        )

        assertEqual(context["default_input_volume_changed"], "false", "unchanged input volume should stay boring")
        assertEqual(context["default_input_volume_dropped"], "false", "unchanged input volume should not look like a drop")
        assertEqual(context["default_output_volume_changed"], "true", "output volume changes should be visible for issue 500")
        assertEqual(context["default_output_volume_dropped"], "true", "output volume drops should be queryable")
        assertEqual(context["default_system_output_volume_changed"], "false", "tiny system output drift should stay below the threshold")
        assertEqual(context["default_system_output_volume_dropped"], "false", "tiny system output drift should not be called a drop")
        assertEqual(context["output_ducking_detected"], "true", "any output drop should mark possible ducking")
        assertEqual(context["quiet_mic_recovered"], "unavailable", "missing peaks should not become false confidence")
        assertEqual(context["quiet_mic_unrecovered"], "unavailable", "missing peaks should not become false confidence")
    }

    runSuite("MeetingCaptureVolumeDiagnostics marks unavailable volume scalars explicitly") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "unavailable",
                "default_output_volume_before": "0.750",
                "default_output_volume_during": "0.740",
                "default_system_output_volume_before": "0.750",
                "default_system_output_volume_during": "0.730",
            ],
            afterStopContext: [:]
        )

        assertEqual(context["default_input_volume_changed"], "unavailable", "missing scalars should not become false confidence")
        assertEqual(context["default_input_volume_dropped"], "unavailable", "missing scalars should not become false confidence")
        assertEqual(context["default_output_volume_changed"], "false", "small during-only drift should stay below the threshold")
        assertEqual(context["default_output_volume_dropped"], "false", "small during-only drift should not be a drop")
        assertEqual(context["default_system_output_volume_changed"], "true", "during values should be used when after values are absent")
        assertEqual(context["default_system_output_volume_dropped"], "true", "during-only drops should still be visible")
        assertEqual(context["output_ducking_detected"], "true", "system output drops should mark possible ducking")
    }

    runSuite("MeetingCaptureVolumeDiagnostics distinguishes increases from drops") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.200",
                "default_output_volume_before": "0.500",
                "default_system_output_volume_before": "NaN",
            ],
            afterStopContext: [
                "default_input_volume_after": "0.260",
                "default_output_volume_after": "0.530",
                "default_system_output_volume_after": "0.500",
            ]
        )

        assertEqual(context["default_input_volume_changed"], "true", "large input volume increases should be visible")
        assertEqual(context["default_input_volume_dropped"], "false", "volume increases should not look like drops")
        assertEqual(context["default_output_volume_changed"], "true", "large output volume increases should be visible")
        assertEqual(context["default_output_volume_dropped"], "false", "output increases should not look like drops")
        assertEqual(context["default_system_output_volume_changed"], "unavailable", "non-finite before values should stay unavailable")
        assertEqual(context["output_ducking_detected"], "unavailable", "mixed unavailable and false states should stay cautious")
    }

    runSuite("MeetingCaptureVolumeDiagnostics flags transient output ducking during recording") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_output_volume_before": "0.750",
                "default_output_volume_during": "0.500",
                "default_system_output_volume_before": "0.750",
                "default_system_output_volume_during": "0.750",
            ],
            afterStopContext: [
                "default_output_volume_after": "0.750",
                "default_system_output_volume_after": "0.750",
            ]
        )

        assertEqual(context["default_output_volume_dropped"], "false", "after-stop recovery should keep the final scalar truthful")
        assertEqual(context["output_ducking_detected"], "true", "during-recording output drops should still mark possible ducking")
    }

    runSuite("MeetingCaptureVolumeDiagnostics classifies quiet mic recovery") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_output_volume_before": "0.740",
                "default_output_volume_during": "0.740",
                "default_system_output_volume_before": "0.740",
                "default_system_output_volume_during": "0.740",
                "mic_raw_peak": "0.03000",
                "mic_processed_peak": "0.36000",
            ],
            afterStopContext: [
                "default_output_volume_after": "0.740",
                "default_system_output_volume_after": "0.740",
            ]
        )

        assertEqual(context["quiet_mic_recovered"], "true", "quiet raw mic with usable processed mic should be queryable")
        assertEqual(context["quiet_mic_unrecovered"], "false", "recovered quiet mic should not also look unrecovered")
        assertEqual(context["output_ducking_detected"], "false", "stable output scalars should stay boring")
    }

    runSuite("MeetingCaptureVolumeDiagnostics classifies unrecovered quiet mic") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "mic_raw_peak": "0.02000",
                "mic_processed_peak": "0.07000",
            ],
            afterStopContext: [:]
        )

        assertEqual(context["quiet_mic_recovered"], "false", "weak processed mic should not look recovered")
        assertEqual(context["quiet_mic_unrecovered"], "true", "quiet raw mic with weak processed mic should be queryable")
    }

    runSuite("MeetingCaptureVolumeDiagnostics leaves normal mic unflagged") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "mic_raw_peak": "0.18000",
                "mic_processed_peak": "0.25000",
            ],
            afterStopContext: [:]
        )

        assertEqual(context["quiet_mic_recovered"], "false", "normal raw mic should not be classified as a quiet-mic recovery")
        assertEqual(context["quiet_mic_unrecovered"], "false", "normal raw mic should not be classified as a quiet-mic failure")
    }

    runSuite("MeetingCaptureVolumeDiagnostics classifies a scalar-drop attenuation (issue 500 Bug A)") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.800",
                "mic_raw_peak": "0.02000",
                "mic_processed_peak": "0.30000",
            ],
            afterStopContext: [
                "default_input_volume_after": "0.200",
            ]
        )

        assertEqual(context["default_input_volume_dropped"], "true", "a large input scalar drop should register")
        assertEqual(context["input_volume_scalar_available"], "true", "a readable scalar should be reported available")
        assertEqual(context["attenuation_kind"], "scalar_drop", "quiet mic with a dropped input scalar is the WebRTC scalar-drop case")
    }

    runSuite("MeetingCaptureVolumeDiagnostics uses captured input scalar for overridden meeting input") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.800",
                "default_input_volume_during": "0.800",
                "captured_input_volume_before": "0.700",
                "captured_input_volume_during": "0.200",
                "mic_raw_peak": "0.02000",
                "mic_processed_peak": "0.30000",
            ],
            afterStopContext: [
                "default_input_volume_after": "0.800",
            ]
        )

        assertEqual(context["default_input_volume_dropped"], "false", "the default input can stay flat when capture was redirected")
        assertEqual(context["captured_input_volume_dropped"], "true", "the selected capture device drop should be visible")
        assertEqual(context["input_volume_scalar_available"], "true", "captured input scalar should count as readable")
        assertEqual(context["attenuation_kind"], "scalar_drop", "classification should follow the device Transcripted actually recorded")
    }

    runSuite("MeetingCaptureVolumeDiagnostics does not let stale default input drops override captured input") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.800",
                "captured_input_volume_before": "0.700",
                "captured_input_volume_during": "0.700",
                "mic_raw_peak": "0.02000",
                "mic_processed_peak": "0.07000",
            ],
            afterStopContext: [
                "default_input_volume_after": "0.200",
            ]
        )

        assertEqual(context["default_input_volume_dropped"], "true", "default route diagnostics should still report its own drop")
        assertEqual(context["captured_input_volume_dropped"], "false", "the selected capture device stayed flat")
        assertEqual(context["attenuation_kind"], "voice_processed", "captured input facts should own attenuation classification when present")
    }

    runSuite("MeetingCaptureVolumeDiagnostics does not fall back when captured scalar is unreadable") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.800",
                "captured_input_volume_before": "unavailable",
                "captured_input_volume_during": "unavailable",
                "mic_raw_peak": "0.02000",
                "mic_processed_peak": "0.07000",
            ],
            afterStopContext: [
                "default_input_volume_after": "0.200",
            ]
        )

        assertEqual(context["default_input_volume_dropped"], "true", "default route diagnostics should still report its own drop")
        assertEqual(context["captured_input_volume_dropped"], "unavailable", "the selected capture device did not expose a scalar")
        assertEqual(context["input_volume_scalar_available"], "false", "captured input presence should own scalar availability")
        assertEqual(context["attenuation_kind"], "voice_processed", "unreadable captured input should not inherit default route drops")
    }

    runSuite("MeetingCaptureVolumeDiagnostics classifies voice-processing attenuation when the scalar held (issue 500 Bug B)") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.800",
                "default_input_volume_during": "0.800",
                "mic_raw_peak": "0.02000",
                "mic_processed_peak": "0.07000",
            ],
            afterStopContext: [
                "default_input_volume_after": "0.800",
            ]
        )

        assertEqual(context["default_input_volume_dropped"], "false", "a flat input scalar should not look like a drop")
        assertEqual(context["input_volume_scalar_available"], "true", "a readable scalar should be reported available")
        assertEqual(context["attenuation_kind"], "voice_processed", "quiet mic with an unchanged input scalar is the voice-processing case")
    }

    runSuite("MeetingCaptureVolumeDiagnostics still classifies voice processing when the scalar is unreadable") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "unavailable",
                "mic_raw_peak": "0.02000",
                "mic_processed_peak": "0.07000",
            ],
            afterStopContext: [:]
        )

        assertEqual(context["input_volume_scalar_available"], "false", "an unreadable scalar should be reported unavailable")
        assertEqual(context["attenuation_kind"], "voice_processed", "a quiet mic with no visible scalar drop is still the voice-processing case")
    }

    runSuite("MeetingCaptureVolumeDiagnostics reports no attenuation for a healthy mic") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "mic_raw_peak": "0.18000",
                "mic_processed_peak": "0.25000",
            ],
            afterStopContext: [:]
        )

        assertEqual(context["attenuation_kind"], "none", "a normal-level mic should not be flagged as attenuated")
    }

    runSuite("MeetingCaptureVolumeDiagnostics reports unavailable attenuation without mic peaks") {
        let context = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_output_volume_before": "0.740",
                "default_output_volume_during": "0.740",
            ],
            afterStopContext: [:]
        )

        assertEqual(context["attenuation_kind"], "unavailable", "missing mic peaks should not become false attenuation confidence")
    }
}
