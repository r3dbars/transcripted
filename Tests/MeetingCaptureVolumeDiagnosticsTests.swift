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
    }
}
