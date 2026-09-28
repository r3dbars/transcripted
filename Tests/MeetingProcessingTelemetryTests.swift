import Foundation

func testMeetingProcessingTelemetry() {
    let machineClass = ["mac_chip": "m2_pro", "memory_gb_bucket": "16gb"]

    runSuite("Meeting processing timings become rounded PostHog properties") {
        let properties = MeetingProcessingTelemetry.properties(
            for: MeetingProcessingTelemetry.Timings(
                processingSeconds: 66.4321,
                sleepSeconds: 0,
                modelsReadySeconds: 0.004,
                resampleSeconds: 1.236,
                diarizeSeconds: 8.5,
                speechToTextSeconds: 48.017,
                speechToTextCalls: 612,
                speechToTextInputSeconds: 2_705.6,
                recordingSeconds: 3_570,
                speechModel: "parakeet-tdt-v3"
            ),
            machineClass: machineClass
        )
        assertEqual(properties["processing_ms"], "66430", "job time rounds to 10 ms")
        assertEqual(properties["sleep_ms"], "0", "no sleep")
        assertEqual(properties["models_ready_ms"], "0", "warm models round to zero")
        assertEqual(properties["resample_ms"], "1240", "resample time rounds to 10 ms")
        assertEqual(properties["diarize_ms"], "8500", "diarization time")
        assertEqual(properties["stt_ms"], "48020", "speech-to-text time")
        assertEqual(properties["stt_calls"], "612", "call count stays exact")
        assertEqual(properties["stt_input_seconds"], "2706", "speech input rounds to whole seconds")
        assertEqual(properties["recording_minutes"], "60", "recording length rounds to whole minutes")
        assertEqual(properties["stt_model"], "parakeet-tdt-v3", "model id")
        assertEqual(properties["mac_chip"], "m2_pro", "chip family comes along")
        assertEqual(properties["memory_gb_bucket"], "16gb", "memory bucket comes along")
    }

    runSuite("Missing or bad values stay safe") {
        let properties = MeetingProcessingTelemetry.properties(
            for: MeetingProcessingTelemetry.Timings(
                processingSeconds: .nan,
                sleepSeconds: -3,
                modelsReadySeconds: .infinity,
                resampleSeconds: 0,
                diarizeSeconds: 0,
                speechToTextSeconds: 0,
                speechToTextCalls: -1,
                speechToTextInputSeconds: .nan,
                recordingSeconds: nil,
                speechModel: nil
            ),
            machineClass: machineClass
        )
        assertEqual(properties["processing_ms"], "0", "NaN becomes zero")
        assertEqual(properties["sleep_ms"], "0", "negative becomes zero")
        assertEqual(properties["models_ready_ms"], "0", "infinity becomes zero")
        assertEqual(properties["stt_calls"], "0", "negative count becomes zero")
        assertEqual(properties["stt_input_seconds"], "0", "NaN input becomes zero")
        assertNil(properties["recording_minutes"], "unknown length is left out")
        assertNil(properties["stt_model"], "unknown model is left out")
    }

    runSuite("Every meeting processing key is allowlisted on meeting_transcript_saved") {
        let allowed = AnalyticsEventPolicy.policy(forEvent: "meeting_transcript_saved")?.allowedProperties ?? []
        let properties = MeetingProcessingTelemetry.properties(
            for: MeetingProcessingTelemetry.Timings(
                processingSeconds: 1, sleepSeconds: 0, modelsReadySeconds: 0, resampleSeconds: 0,
                diarizeSeconds: 0, speechToTextSeconds: 0, speechToTextCalls: 1,
                speechToTextInputSeconds: 1, recordingSeconds: 60, speechModel: "parakeet-tdt-v3"
            ),
            machineClass: machineClass
        )
        for key in properties.keys.sorted() {
            assertTrue(allowed.contains(key), "\(key) must be allowlisted or PostHog never sees it")
        }
    }
}
