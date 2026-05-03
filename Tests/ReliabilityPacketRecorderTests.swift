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
                "device_switches": "2",
                "duration_ms": "143400",
                "error": "/Users/redbars/private.txt should not be copied",
                "reason": "overlay_stop_button",
                "source_app_name": "Private App",
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
