import Foundation

func testReliabilityPacketRecorder() {
    runSuite("ReliabilityPacketRecorder maps meeting stop recovery into a safe packet") {
        let event = ObservabilityEvent(
            timestamp: "2026-05-03T01:15:11.605Z",
            level: "info",
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: [
                "audio_gaps": "2",
                "default_input_volume_after": "0.620",
                "default_input_volume_before": "0.620",
                "default_input_volume_during": "0.620",
                "default_output_volume_after": "0.740",
                "default_output_volume_before": "0.740",
                "default_output_volume_dropped": "false",
                "default_output_volume_during": "0.740",
                "device_switches": "2",
                "duration_ms": "143400",
                "error": "/Users/redbars/private.txt should not be copied",
                "mic_processed_peak": "0.36000",
                "mic_raw_peak": "0.03000",
                "output_ducking_detected": "false",
                "quiet_mic_recovered": "true",
                "quiet_mic_unrecovered": "false",
                "reason": "overlay_stop_button",
                "source_app_name": "Private App",
                "system_peak": "0.25000",
                "system_file_present": "true",
                "trigger": "hotkey",
            ],
            appVersion: "1.1.29",
            osVersion: "Version 26.4.1"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertNotNil(packet, "meeting stop should produce a reliability packet")
        assertEqual(packet?.feature, "meeting", "packet feature should classify the flow")
        assertEqual(packet?.stage, "stop", "packet stage should classify stop behavior")
        assertEqual(packet?.outcome, "recovered", "device switches during stop should count as recovered")
        assertEqual(packet?.context["duration_bucket"], "2_9m", "raw durations should be bucketed")
        assertEqual(packet?.context["gap_count_bucket"], "2_3", "audio gaps should be bucketed")
        assertEqual(packet?.context["route_change_count_bucket"], "2_3", "device switches should be bucketed")
        assertEqual(packet?.context["system_stream_present"], "true", "system stream presence should stay coarse")
        assertEqual(packet?.context["mic_raw_peak"], "0.03000", "raw mic peak should stay available for manual QA")
        assertEqual(packet?.context["mic_processed_peak"], "0.36000", "processed mic peak should stay available for manual QA")
        assertEqual(packet?.context["system_peak"], "0.25000", "system audio peak should stay available for manual QA")
        assertEqual(packet?.context["default_output_volume_before"], "0.740", "before volume scalar should stay available for manual QA")
        assertEqual(packet?.context["default_output_volume_after"], "0.740", "after volume scalar should stay available for manual QA")
        assertEqual(packet?.context["default_output_volume_dropped"], "false", "issue 500 volume-drop flags should stay available for manual QA")
        assertEqual(packet?.context["output_ducking_detected"], "false", "ducking classification should stay available for manual QA")
        assertEqual(packet?.context["quiet_mic_recovered"], "true", "quiet mic recovery classification should stay available for manual QA")
        assertEqual(packet?.context["quiet_mic_unrecovered"], "false", "quiet mic failure classification should stay available for manual QA")
        assertNil(packet?.context["error"], "raw error text should not be copied into reliability packets")
        assertNil(packet?.context["source_app_name"], "source app names should not be copied into reliability packets")
    }

    runSuite("ReliabilityPacketRecorder outcome follows the capture grade and the audio that survived") {
        func stopEvent(_ extra: [String: String]) -> ObservabilityEvent {
            ObservabilityEvent(
                timestamp: "2026-09-03T20:00:00.000Z",
                level: "info",
                engine: "meeting",
                event: "meeting_recording_stopped",
                message: "Meeting recording stopped",
                context: [
                    "audio_gaps": "0",
                    "device_switches": "0",
                    "duration_ms": "600000",
                    "mic_file_present": "true",
                    "reason": "overlay_stop_button",
                    "stop_timed_out": "false",
                    "system_file_present": "true",
                    "trigger": "hotkey",
                ].merging(extra) { _, new in new },
                appVersion: "1.1.57",
                osVersion: "Version 26.6"
            )
        }

        let degraded = ReliabilityPacketRecorder.packet(from: stopEvent([
            "capture_quality": "degraded",
            "quality_reason": "system_audio_failed",
        ]))
        assertEqual(degraded?.outcome, "degraded_success", "a degraded grade must not be filed as a plain success")
        assertEqual(degraded?.context["quality_reason"], "system_audio_failed", "the reason for the grade travels with the packet")

        let noAudio = ReliabilityPacketRecorder.packet(from: stopEvent([
            "mic_file_present": "false",
            "system_file_present": "false",
            "capture_quality": "degraded",
        ]))
        assertEqual(noAudio?.outcome, "failed_retryable", "a stop that produced no audio is a failure, not a success")

        let clean = ReliabilityPacketRecorder.packet(from: stopEvent([
            "capture_quality": "excellent",
            "quality_reason": "none",
        ]))
        assertEqual(clean?.outcome, "success", "a clean stop is still a success")

        let recovered = ReliabilityPacketRecorder.packet(from: stopEvent([
            "capture_quality": "good",
            "quality_reason": "interruptions",
            "device_switches": "1",
        ]))
        assertEqual(recovered?.outcome, "recovered", "a non-degraded grade with switches keeps the recovered outcome")

        // A cancellation discards its files on purpose; the derived verdicts
        // must not turn it into a failure.
        let cancelled = ReliabilityPacketRecorder.packet(from: ObservabilityEvent(
            timestamp: "2026-09-03T20:00:00.000Z",
            level: "info",
            engine: "meeting",
            event: "meeting_recording_cancelled",
            message: "Meeting recording cancelled",
            context: [
                "mic_file_present": "false",
                "system_file_present": "false",
                "capture_quality": "degraded",
                "reason": "overlay_cancel_button",
            ],
            appVersion: "1.1.57",
            osVersion: "Version 26.6"
        ))
        assertEqual(cancelled?.outcome, "cancelled", "a cancellation stays cancelled even with no files and a degraded grade")
    }

    runSuite("ReliabilityPacketRecorder ignores unrelated app events") {
        let event = ObservabilityEvent(
            timestamp: "2026-05-03T01:15:11.605Z",
            level: "info",
            engine: "app",
            event: "app_launched",
            message: "App launched",
            context: nil,
            appVersion: "1.1.29",
            osVersion: "Version 26.4.1"
        )

        assertNil(ReliabilityPacketRecorder.packet(from: event), "boring app launch should not create a packet")
    }

    runSuite("ReliabilityPacketRecorder maps terminal meeting capture outcomes") {
        let noAudio = ObservabilityEvent(
            timestamp: "2026-09-03T19:15:11.605Z",
            level: "error",
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: [
                "capture_outcome": "no_audio",
                "mic_file_present": "false",
                "system_file_present": "false",
                "stop_timed_out": "false",
            ],
            appVersion: "1.1.57",
            osVersion: "Version 26.6.0"
        )
        let systemOnly = ObservabilityEvent(
            timestamp: "2026-09-03T19:16:11.605Z",
            level: "warning",
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: [
                "capture_outcome": "system_only",
                "mic_file_present": "false",
                "system_file_present": "true",
                "stop_timed_out": "false",
            ],
            appVersion: "1.1.57",
            osVersion: "Version 26.6.0"
        )

        let noAudioPacket = ReliabilityPacketRecorder.packet(from: noAudio)
        let systemOnlyPacket = ReliabilityPacketRecorder.packet(from: systemOnly)

        assertEqual(noAudioPacket?.outcome, "failed_retryable", "no-audio stops must not appear successful")
        assertEqual(noAudioPacket?.context["capture_outcome"], "no_audio", "typed capture outcome should survive safely")
        assertEqual(systemOnlyPacket?.outcome, "degraded_success", "partial captures should stay usable but degraded")
        assertEqual(systemOnlyPacket?.context["capture_outcome"], "system_only", "partial source shape should stay queryable")

        for detailEvent in [
            "meeting_recording_missing_audio",
            "meeting_recording_missing_mic_audio_system_only",
            "meeting_recording_missing_system_audio_mic_only",
            "meeting_recording_stop_timeout_failed",
            "recording_stop_timeout",
        ] {
            let detail = ObservabilityEvent(
                timestamp: "2026-09-03T19:17:11.605Z",
                level: "warning",
                engine: "meeting",
                event: detailEvent,
                message: "Meeting capture detail",
                context: ["capture_outcome": "system_only"],
                appVersion: "1.1.57",
                osVersion: "Version 26.6.0"
            )
            assertNil(
                ReliabilityPacketRecorder.packet(from: detail),
                "detail events must not duplicate the terminal meeting stop packet"
            )
        }
    }

    runSuite("ReliabilityPacketRecorder preserves mic/output mismatch diagnostics safely") {
        let event = ObservabilityEvent(
            timestamp: "2026-06-06T18:15:11.605Z",
            level: "info",
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: [
                "audio_device": "Private AirPods Pro",
                "captured_input_volume_before": "0.650",
                "captured_input_volume_changed": "false",
                "captured_input_volume_dropped": "false",
                "captured_input_volume_during": "0.650",
                "default_input_volume_after": "0.500",
                "default_input_volume_before": "0.500",
                "default_input_volume_dropped": "false",
                "default_input_volume_during": "0.500",
                "default_output_volume_after": "0.750",
                "default_output_volume_before": "0.750",
                "default_output_volume_dropped": "false",
                "default_output_volume_during": "0.750",
                "default_system_output_volume_after": "0.400",
                "default_system_output_volume_before": "0.750",
                "default_system_output_volume_dropped": "true",
                "default_system_output_volume_during": "0.750",
                "input_device_class": "built_in",
                "input_volume_scalar_available": "true",
                "mic_boost_prompt": "shown",
                "mic_processed_peak": "0.30000",
                "mic_raw_peak": "0.02000",
                "output_device_class": "bluetooth",
                "output_ducking_detected": "true",
                "system_output_device_class": "bluetooth",
                "transcript_text": "private words",
            ],
            appVersion: "1.1.46",
            osVersion: "Version 26.5.0"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertNotNil(packet, "meeting stop should produce a reliability packet")
        assertEqual(packet?.context["input_device_class"], "built_in", "coarse selected mic class should survive")
        assertEqual(packet?.context["output_device_class"], "bluetooth", "coarse output class should survive")
        assertEqual(packet?.context["system_output_device_class"], "bluetooth", "coarse system output class should survive")
        assertEqual(packet?.context["captured_input_volume_dropped"], "false", "captured mic scalar should stay separate from default route facts")
        assertEqual(packet?.context["default_system_output_volume_dropped"], "true", "system-output ducking should stay queryable")
        assertEqual(packet?.context["output_ducking_detected"], "true", "derived ducking flag should survive")
        assertEqual(packet?.context["mic_boost_prompt"], "shown", "the coarse issue 500 prompt outcome should survive into support packets")
        assertNil(packet?.context["audio_device"], "raw device names should not be copied into reliability packets")
        assertNil(packet?.context["transcript_text"], "transcript text should not be copied into reliability packets")
    }

    runSuite("ReliabilityPacketRecorder maps dictation microphone timeout route shape safely") {
        let event = ObservabilityEvent(
            timestamp: "2026-06-02T14:18:42.771Z",
            level: "error",
            engine: "dictation",
            event: "microphone_start_timeout",
            message: "Dictation recording failed to start within recovery budget",
            context: [
                "audio_device": "Private AirPods",
                "default_input_class": "bluetooth",
                "default_output_class": "bluetooth",
                "error": "private raw error",
                "failure_kind": "microphone_start_timeout",
                "format_ready": "false",
                "input_device_class": "built_in",
                "output_device_class": "bluetooth",
                "route_shape": "built_in_input_to_bluetooth_output",
                "sample_flow_started": "false",
                "selected_input_class": "built_in",
                "selection_overrode_default": "true",
                "selection_reason": "preferredBuiltInForBluetoothHeadset",
                "source_app_name": "Private App",
                "stt_model": "parakeet-tdt-v3",
                "transcript_text": "private words",
            ],
            appVersion: "1.1.45",
            osVersion: "Version 26.5.0"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertNotNil(packet, "dictation mic start timeout should produce a reliability packet")
        assertEqual(packet?.feature, "dictation", "packet feature should classify dictation")
        assertEqual(packet?.stage, "start", "packet stage should classify startup")
        assertEqual(packet?.outcome, "failed_retryable", "mic start timeout should be retryable")
        assertEqual(packet?.context["route_shape"], "built_in_input_to_bluetooth_output", "coarse route shape should survive")
        assertEqual(packet?.context["sample_flow_started"], "false", "sample-flow proof should stay queryable")
        assertEqual(packet?.context["selection_reason"], "preferredBuiltInForBluetoothHeadset", "selection reason should stay coarse")
        assertNil(packet?.context["audio_device"], "raw device names should not be copied into reliability packets")
        assertNil(packet?.context["error"], "raw error text should not be copied into reliability packets")
        assertNil(packet?.context["source_app_name"], "source app names should not be copied into reliability packets")
        assertNil(packet?.context["transcript_text"], "transcript text should not be copied into reliability packets")
    }

    runSuite("ReliabilityPacketRecorder ignores low-level dictation start attempt diagnostics") {
        for detailEvent in [
            "audio_engine_start_failed",
            "audio_engine_start_timeout",
            "mic_not_authorized",
        ] {
            let event = ObservabilityEvent(
                timestamp: "2026-07-04T11:58:00.000Z",
                level: "error",
                engine: "parakeet",
                event: detailEvent,
                message: "Low-level dictation audio attempt detail",
                context: ["failure_kind": detailEvent],
                appVersion: "1.1.49",
                osVersion: "Version 26.5.0"
            )

            assertNil(
                ReliabilityPacketRecorder.packet(from: event),
                "low-level audio attempt diagnostics must not duplicate the user-flow terminal packet"
            )
        }
    }

    runSuite("ReliabilityPacketRecorder preserves coarse runtime shutdown duration") {
        let event = ObservabilityEvent(
            timestamp: "2026-05-03T01:15:11.605Z",
            level: "warning",
            engine: "app",
            event: "unclean_shutdown_detected",
            message: "Previous app session did not shut down cleanly",
            context: [
                "session_active": "false",
                "session_duration_bucket": "3_7h",
                "session_kind": "none",
                "session_stage": "idle",
                "started_at": "2026-05-03T00:00:00Z",
            ],
            appVersion: "1.1.32",
            osVersion: "Version 26.4.1"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertEqual(packet?.context["session_duration_bucket"], "3_7h", "runtime duration should stay coarse")
        assertNil(packet?.context["started_at"], "raw runtime timestamps should not be copied into reliability packets")
    }

    runSuite("ReliabilityPacketRecorder maps short meetings as expected skips") {
        let event = ObservabilityEvent(
            timestamp: "2026-05-03T01:15:11.605Z",
            level: "info",
            engine: "meeting",
            event: "meeting_transcript_skipped",
            message: "Meeting transcription skipped because the recording was too short",
            context: [
                "error": "private raw error should not be copied",
                "failure_kind": "recording_too_short",
                "queue_depth": "0",
                "trigger": "hotkey",
            ],
            appVersion: "1.1.32",
            osVersion: "Version 26.4.1"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertNotNil(packet, "short meeting skips should produce a reliability packet")
        assertEqual(packet?.feature, "meeting", "packet feature should classify the flow")
        assertEqual(packet?.stage, "transcribe", "packet stage should classify the skip")
        assertEqual(packet?.outcome, "skipped_expected", "too-short meetings should not look like failures")
        assertEqual(packet?.context["failure_kind"], "recording_too_short", "skip reason should stay normalized")
        assertNil(packet?.context["error"], "raw error text should not be copied into reliability packets")
    }

    runSuite("ReliabilityPacketRecorder maps failed meeting transcription without private fields") {
        let event = ObservabilityEvent(
            timestamp: "2026-05-03T01:15:11.605Z",
            level: "error",
            engine: "meeting",
            event: "meeting_transcript_failed",
            message: "Meeting transcription failed",
            context: [
                "audio_device": "Jane's AirPods Pro",
                "audio_path": "/Users/jane/Private/customer.wav",
                "duration_ms": "734000",
                "email": "person@example.com",
                "failure_kind": "transcription_inference_failed",
                "file_path": "/Users/jane/Private/customer.md",
                "meeting_title": "Customer Roadmap",
                "queue_depth": "2",
                "raw_url": "https://meet.example.com/private-room",
                "speaker_name": "Alice Customer",
                "system_file_present": "true",
                "token": "sk-private",
                "transcript_text": "private transcript words",
                "trigger": "hotkey",
                "words": "1840",
            ],
            appVersion: "1.1.37",
            osVersion: "Version 26.4.1"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertNotNil(packet, "failed meeting transcription should produce reliability packets")
        assertEqual(packet?.feature, "meeting", "packet feature should classify the flow")
        assertEqual(packet?.stage, "transcribe", "packet stage should classify transcription")
        assertEqual(packet?.outcome, "failed_retryable", "transcript failures should remain visible as retryable failures")
        assertEqual(packet?.context["duration_bucket"], "10_29m", "raw duration should be bucketed")
        assertEqual(packet?.context["failure_kind"], "transcription_inference_failed", "failure kind should stay normalized")
        assertEqual(packet?.context["queue_depth_bucket"], "2_3", "queue depth should stay bucketed")
        assertEqual(packet?.context["system_stream_present"], "true", "system stream presence should stay coarse")
        assertEqual(packet?.context["trigger"], "hotkey", "trigger should stay queryable")
        assertEqual(packet?.context["word_count_bucket"], "300_plus", "word count should stay bucketed")
        assertNil(packet?.context["audio_device"], "raw device names should not be copied into reliability packets")
        assertNil(packet?.context["audio_path"], "audio paths should not be copied into reliability packets")
        assertNil(packet?.context["email"], "emails should not be copied into reliability packets")
        assertNil(packet?.context["file_path"], "file paths should not be copied into reliability packets")
        assertNil(packet?.context["meeting_title"], "meeting titles should not be copied into reliability packets")
        assertNil(packet?.context["raw_url"], "raw URLs should not be copied into reliability packets")
        assertNil(packet?.context["speaker_name"], "speaker names should not be copied into reliability packets")
        assertNil(packet?.context["token"], "tokens should not be copied into reliability packets")
        assertNil(packet?.context["transcript_text"], "transcript text should not be copied into reliability packets")
    }

    runSuite("ReliabilityPacketRecorder maps speaker finalization failures") {
        let event = ObservabilityEvent(
            timestamp: "2026-05-03T01:15:11.605Z",
            level: "error",
            engine: "meeting",
            event: "speaker_finalization_failed",
            message: "Meeting speaker naming finalization failed",
            context: [
                "failure_kind": "speaker_finalization_failed",
                "queue_depth": "2",
                "speaker_name": "Private Person",
                "trigger": "hotkey",
            ],
            appVersion: "1.1.37",
            osVersion: "Version 26.4.1"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertNotNil(packet, "speaker finalization failures should produce reliability packets")
        assertEqual(packet?.feature, "meeting", "packet feature should classify the flow")
        assertEqual(packet?.stage, "save", "speaker finalization is a post-transcript save-stage failure")
        assertEqual(packet?.outcome, "failed_retryable", "speaker finalization failures should remain visible as retryable failures")
        assertEqual(packet?.context["failure_kind"], "speaker_finalization_failed", "failure kind should stay normalized")
        assertEqual(packet?.context["queue_depth_bucket"], "2_3", "queue depth should stay bucketed")
        assertEqual(packet?.context["trigger"], "hotkey", "trigger should stay queryable")
        assertNil(packet?.context["speaker_name"], "speaker names should not be copied into reliability packets")
    }

    runSuite("ReliabilityPacketRecorder renders recent packet summaries from JSONL") {
        let packets = [
            ReliabilityPacket(
                timestamp: "2026-05-03T01:00:00Z",
                feature: "dictation",
                stage: "start",
                outcome: "success",
                event: "dictation_started",
                appVersion: "1.1.29",
                osMajor: "26",
                context: ["trigger": "physical_key"]
            ),
            ReliabilityPacket(
                timestamp: "2026-05-03T01:15:11Z",
                feature: "meeting",
                stage: "stop",
                outcome: "recovered",
                event: "meeting_recording_stopped",
                appVersion: "1.1.29",
                osMajor: "26",
                context: ["route_change_count_bucket": "2_3"]
            ),
        ]
        let encoder = JSONEncoder()
        let jsonl = packets
            .compactMap { try? encoder.encode($0) }
            .compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n")

        let summaries = ReliabilityPacketRecorder.packetSummaries(fromJSONL: jsonl, limit: 1)

        assertEqual(summaries.count, 1, "summary reader should honor the limit")
        assertTrue(summaries.first?.contains("meeting.stop recovered") == true, "newest packet summary should be returned")
    }

    runSuite("ReliabilityPacketRecorder treats the dictation session cap as expected, not a retryable failure") {
        let event = ObservabilityEvent(
            timestamp: "2026-09-03T19:15:11.605Z",
            level: "info",
            engine: "overlay",
            event: "dictation_timeout",
            message: "Dictation reached the session cap; saving without paste",
            context: ["trigger": "physical_key"],
            appVersion: "1.1.57",
            osVersion: "Version 26.6.0"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertEqual(packet?.feature, "dictation", "session cap should stay a dictation packet")
        assertEqual(packet?.stage, "recording", "session cap belongs to the recording stage")
        assertEqual(packet?.outcome, "skipped_expected", "the 5-minute cap is informational and must not inflate failed_retryable counts")
    }

    runSuite("ReliabilityPacketRecorder keeps coarse device classes and derived outcomes when fed the raw event") {
        // EventReporter hands the recorder the unsanitized entry on purpose:
        // the recorder allowlists and redacts every value itself. Feeding it
        // the locally-blanked copy shipped "[redacted-sensitive-value]" for
        // input_device_class in support bundles and blanked the audio_gaps /
        // device_switches inputs the `recovered` outcome is derived from.
        let event = ObservabilityEvent(
            timestamp: "2026-09-03T19:15:11.605Z",
            level: "info",
            engine: "meeting",
            event: "meeting_recording_stopped",
            message: "Meeting recording stopped",
            context: [
                "audio_gaps": "1",
                "device_switches": "1",
                "input_device_class": "built_in",
                "output_device_class": "bluetooth",
                "system_file_present": "true",
                "audio_device": "Private AirPods",
                "reason": "overlay_stop_button",
            ],
            appVersion: "1.1.57",
            osVersion: "Version 26.6.0"
        )

        let packet = ReliabilityPacketRecorder.packet(from: event)

        assertEqual(packet?.outcome, "recovered", "device switches must still be readable so the recovered outcome stays reachable")
        assertEqual(packet?.context["input_device_class"], "built_in", "coarse input class should ship as its enum value, never as a redaction marker")
        assertEqual(packet?.context["system_stream_present"], "true", "system stream presence is derived from system_file_present and must not be blanked upstream")
        assertNil(packet?.context["audio_device"], "raw device labels must still be dropped by the recorder's own allowlist")
    }
}
