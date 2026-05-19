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
}
