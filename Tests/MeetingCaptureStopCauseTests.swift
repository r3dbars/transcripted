import Foundation

func testMeetingCaptureStopCause() {
    runSuite("Unexpected capture stops use Core's cause or unrecorded") {
        assertEqual(
            MeetingCaptureStopCause.unexpected("mic_write_failed"),
            "mic_write_failed"
        )
        assertEqual(
            MeetingCaptureStopCause.unexpected("mic_recovery_gave_up"),
            "mic_recovery_gave_up"
        )
        assertEqual(MeetingCaptureStopCause.unexpected(nil), "unrecorded")
        assertEqual(MeetingCaptureStopCause.unexpected(""), "unrecorded")
        assertEqual(MeetingCaptureStopCause.unexpected("   "), "unrecorded")
    }

    runSuite("App-initiated stops keep Core's cause when it already ended capture") {
        assertEqual(
            MeetingCaptureStopCause.requested(
                internalCause: "mic_write_failed",
                reason: "overlay_stop_button"
            ),
            "mic_write_failed"
        )
        assertEqual(
            MeetingCaptureStopCause.requested(
                internalCause: nil,
                reason: "overlay_stop_button"
            ),
            "overlay_stop_button"
        )
        assertEqual(
            MeetingCaptureStopCause.requested(
                internalCause: nil,
                reason: "discard_button"
            ),
            "discard_button"
        )
        assertEqual(
            MeetingCaptureStopCause.requested(internalCause: nil, reason: ""),
            "unrecorded"
        )
    }

    runSuite("stop_cause values stay telemetry-safe categories") {
        let values = [
            "unrecorded",
            "mic_write_failed",
            "mic_recovery_gave_up",
            "pinned_mic_failed",
            "disk_low",
            "mic_write_backpressure",
            "system_write_backpressure",
            "hotkey_toggle",
            "overlay_stop_button",
            "menu_bar_stop_button",
            "quit_confirmation",
            "audio_inactivity_prompt",
            "audio_inactivity_timeout",
            "detected_call_end_prompt",
            "detected_call_end_timeout",
            "audio_route_warning",
            "system_audio_warning",
            "new_meeting_split",
            "debug_control",
            "lab_control",
            "unknown",
            "discard_button",
        ]
        for value in values {
            assertEqual(
                MeetingCaptureStopCause.unexpected(value),
                value,
                "\(value) must round-trip as a category"
            )
            assertTrue(value.count <= 80, "\(value) is too long for a tag")
        }
    }
}
