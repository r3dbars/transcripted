import Foundation

func testMeetingAudioInactivityDetector() {
    runSuite("MeetingAudioInactivityDetector warns after configured silence") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 300,
                countdownSeconds: 30,
                activeLevelThreshold: 0.02
            )
        )

        assertEqual(detector.startRecording(at: 0), .none)
        assertEqual(detector.tick(at: 299), .none)
        assertEqual(
            detector.tick(at: 300),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 300, countdownSeconds: 30))
        )
    }

    runSuite("MeetingAudioInactivityDetector clears warning when audio resumes") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 10,
                countdownSeconds: 5,
                activeLevelThreshold: 0.02
            )
        )

        _ = detector.startRecording(at: 0)
        assertEqual(
            detector.tick(at: 10),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 5))
        )
        assertEqual(detector.observe(micLevel: 0.03, systemLevel: 0, at: 12), .warningCleared)
        assertNil(detector.warning)
        assertEqual(detector.tick(at: 21), .none)
        assertEqual(
            detector.tick(at: 22),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 5))
        )
    }

    runSuite("MeetingAudioInactivityDetector dismiss snoozes until audio resumes") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 10,
                countdownSeconds: 5,
                activeLevelThreshold: 0.02
            )
        )

        _ = detector.startRecording(at: 0)
        _ = detector.tick(at: 10)
        assertEqual(detector.dismissWarning(), .warningCleared)
        assertEqual(detector.tick(at: 100), .none)
        assertNil(detector.warning)

        assertEqual(detector.observe(micLevel: 0, systemLevel: 0.03, at: 101), .none)
        assertEqual(
            detector.tick(at: 111),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 5))
        )
    }

    runSuite("MeetingAudioInactivityDetector treats either audio stream as active") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 10,
                countdownSeconds: 5,
                activeLevelThreshold: 0.02
            )
        )

        _ = detector.startRecording(at: 0)
        assertEqual(detector.observe(micLevel: 0, systemLevel: 0.03, at: 8), .none)
        assertEqual(detector.tick(at: 17), .none)
        assertEqual(
            detector.tick(at: 18),
            .warningStarted(MeetingAudioInactivityWarning(inactiveDuration: 10, countdownSeconds: 5))
        )
    }

    runSuite("MeetingAudioInactivityDetector stop clears active warning") {
        var detector = MeetingAudioInactivityDetector(
            configuration: .init(
                inactivityInterval: 10,
                countdownSeconds: 5,
                activeLevelThreshold: 0.02
            )
        )

        _ = detector.startRecording(at: 0)
        _ = detector.tick(at: 10)
        assertEqual(detector.stopRecording(), .warningCleared)
        assertNil(detector.warning)
        assertEqual(detector.tick(at: 100), .none)
    }

    runSuite("MeetingAudioInactivityRecoveryPolicy disables auto-stop for degraded long Bluetooth capture") {
        let baseWarning = MeetingAudioInactivityWarning(
            inactiveDuration: 300,
            countdownSeconds: 30
        )
        let diagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.667",
                "default_input_volume_during": "0.000",
                "input_device_class": "aggregate",
                "mic_processed_peak": "0.14816",
                "mic_raw_peak": "0.02030",
                "output_device_class": "bluetooth",
                "route_change_count": "158",
                "system_output_device_class": "bluetooth",
                "system_status": "silent",
            ],
            afterStopContext: [:]
        )

        let warning = MeetingAudioInactivityRecoveryPolicy.warning(
            from: baseWarning,
            durationSeconds: 17 * 60,
            diagnostics: diagnostics
        )

        assertEqual(warning.kind, .degradedRoute, "long route-churned Bluetooth silence should get the recovery prompt")
        assertEqual(warning.automaticStopAllowed, false, "degraded capture should not auto-end the recording")
    }

    runSuite("MeetingAudioInactivityRecoveryPolicy honors captured input volume drops") {
        let baseWarning = MeetingAudioInactivityWarning(
            inactiveDuration: 300,
            countdownSeconds: 30
        )
        let diagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "captured_input_volume_before": "0.650",
                "captured_input_volume_during": "0.000",
                "default_input_volume_before": "0.500",
                "default_input_volume_during": "0.500",
                "input_device_class": "built_in",
                "mic_processed_peak": "0.14816",
                "mic_raw_peak": "0.02030",
                "output_device_class": "built_in",
                "route_change_count": "0",
                "system_output_device_class": "built_in",
                "system_status": "active",
            ],
            afterStopContext: [:]
        )

        let warning = MeetingAudioInactivityRecoveryPolicy.warning(
            from: baseWarning,
            durationSeconds: 17 * 60,
            diagnostics: diagnostics
        )

        assertEqual(warning.kind, .degradedRoute, "selected mic scalar drops should get the recovery prompt")
        assertEqual(warning.automaticStopAllowed, false, "selected mic scalar drops should not auto-end the recording")
    }

    runSuite("MeetingAudioInactivityRecoveryPolicy keeps normal silence auto-stop") {
        let baseWarning = MeetingAudioInactivityWarning(
            inactiveDuration: 300,
            countdownSeconds: 30
        )
        let diagnostics = MeetingCaptureVolumeDiagnostics.annotatedStopContext(
            baseContext: [
                "default_input_volume_before": "0.500",
                "default_input_volume_during": "0.500",
                "input_device_class": "built_in",
                "mic_processed_peak": "0.00000",
                "mic_raw_peak": "0.00000",
                "output_device_class": "built_in",
                "route_change_count": "0",
                "system_output_device_class": "built_in",
                "system_status": "silent",
            ],
            afterStopContext: [:]
        )

        let warning = MeetingAudioInactivityRecoveryPolicy.warning(
            from: baseWarning,
            durationSeconds: 17 * 60,
            diagnostics: diagnostics
        )

        assertEqual(warning.kind, .noAudio, "plain long silence should keep the original prompt")
        assertEqual(warning.automaticStopAllowed, true, "plain silence should still auto-end after the countdown")
    }
}
