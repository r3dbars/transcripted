import Foundation

@available(macOS 14.0, *)
@MainActor
private func makeTelemetryPromptCandidate(
    provider: MeetingPromptProvider = .zoom,
    reason: MeetingPromptReason = .calendarPlusRuntimeMatch,
    source: MeetingPromptSource = .calendarEvent
) -> MeetingPromptDetector.Candidate {
    let startDate = Date(timeIntervalSince1970: 2_000)
    return MeetingPromptDetector.Candidate(
        id: "calendar:design-review",
        title: "Meeting detected",
        detail: "Design review - starts soon",
        provider: provider,
        reason: reason,
        source: source,
        startDate: startDate,
        endDate: startDate.addingTimeInterval(30 * 60),
        meetingURL: URL(string: "https://zoom.us/j/123"),
        suggestedTranscriptTitle: "Design review"
    )
}

@MainActor
func testMeetingPromptTelemetry() async {
    guard #available(macOS 14.0, *) else { return }

    runSuite("MeetingPromptTelemetry.properties — keeps prompt context coarse and stable") {
        let properties = MeetingPromptTelemetry.properties(
            for: makeTelemetryPromptCandidate(),
            readiness: MeetingPromptTelemetryReadiness(
                microphoneGranted: true,
                systemAudioRecordingGranted: false,
                meetingRecordingActive: false,
                dictationRecordingActive: false
            ),
            backoffKind: .runtimeUntilNextCalendar
        )

        assertEqual(properties["provider"], "zoom", "provider should stay enum-shaped")
        assertEqual(properties["prompt_reason"], "calendar_plus_runtime_match", "prompt reason should stay explicit")
        assertEqual(properties["source"], "calendar_event", "source should distinguish calendar and runtime prompts")
        assertEqual(properties["calendar_confidence"], "linked_event_runtime_match", "calendar confidence should be coarse")
        assertEqual(properties["call_state"], "app_active", "call state should be coarse")
        assertEqual(properties["app_signal"], "native_runtime", "app signal should not include app names")
        assertEqual(properties["route_ready"], "false", "route readiness should reflect both required permissions")
        assertEqual(properties["missing_permission"], "system_audio_recording", "missing permission should be bucketed")
        assertEqual(properties["backoff_kind"], "runtime_until_next_calendar", "backoff kind should be preserved")
        assertEqual(properties["cooldown_reason"], "runtime_until_next_calendar", "dismiss telemetry should preserve cooldown reason")
    }

    runSuite("MeetingPromptTelemetry.properties — adds suppression context without raw meeting data") {
        let suppression = MeetingPromptSuppression(
            candidate: makeTelemetryPromptCandidate(
                provider: .googleMeet,
                reason: .micInput,
                source: .runtimeApp
            ),
            reason: .ownCaptureActive,
            cooldownReason: "pending",
            captureActivity: .dictation
        )
        let properties = MeetingPromptTelemetry.properties(
            for: suppression,
            readiness: MeetingPromptTelemetryReadiness(
                microphoneGranted: false,
                systemAudioRecordingGranted: false,
                meetingRecordingActive: false,
                dictationRecordingActive: true
            )
        )

        assertEqual(properties["provider"], "googleMeet", "provider should stay enum-shaped")
        assertEqual(properties["source"], "runtime_app", "runtime prompts should report runtime source")
        assertEqual(properties["app_signal"], "browser_mic", "browser mic signals should stay coarse")
        assertEqual(properties["suppression_reason"], "own_capture_active", "suppression reason should be explicit")
        assertEqual(properties["cooldown_reason"], "pending", "suppression cooldown reason should pass through")
        assertEqual(properties["capture_activity"], "dictation", "capture activity should explain why we stayed quiet")
        assertEqual(properties["missing_permission"], "microphone_and_system_audio_recording", "combined missing permissions should be bucketed")
    }

    runSuite("MeetingPromptTelemetry.readyState — prioritizes active capture before permission readiness") {
        assertEqual(
            MeetingPromptTelemetry.readyState(
                readiness: MeetingPromptTelemetryReadiness(
                    microphoneGranted: true,
                    systemAudioRecordingGranted: true,
                    meetingRecordingActive: true,
                    dictationRecordingActive: false
                )
            ),
            "recording_active",
            "meeting recording should be the strongest ready-state signal"
        )
        assertEqual(
            MeetingPromptTelemetry.readyState(
                readiness: MeetingPromptTelemetryReadiness(
                    microphoneGranted: true,
                    systemAudioRecordingGranted: true,
                    meetingRecordingActive: false,
                    dictationRecordingActive: true
                )
            ),
            "dictation_active",
            "dictation should explain prompt suppression before generic readiness"
        )
        assertEqual(
            MeetingPromptTelemetry.readyState(
                readiness: MeetingPromptTelemetryReadiness(
                    microphoneGranted: true,
                    systemAudioRecordingGranted: true,
                    meetingRecordingActive: false,
                    dictationRecordingActive: false
                )
            ),
            "ready",
            "both required permissions should report ready"
        )
        assertEqual(
            MeetingPromptTelemetry.readyState(
                readiness: MeetingPromptTelemetryReadiness(
                    microphoneGranted: true,
                    systemAudioRecordingGranted: false,
                    meetingRecordingActive: false,
                    dictationRecordingActive: false
                )
            ),
            "not_ready",
            "missing route permission should report not ready"
        )
    }
}
