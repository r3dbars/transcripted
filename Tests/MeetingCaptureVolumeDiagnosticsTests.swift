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
}
