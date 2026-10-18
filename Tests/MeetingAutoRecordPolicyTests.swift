import Foundation

func testMeetingAutoRecordPolicy() {
    let held = MeetingAutoRecordPolicy.evidenceHoldDuration

    struct Row {
        let name: String
        let request: MeetingAutoRecordPolicy.Request
        let expected: MeetingAutoRecordPolicy.Decision
    }

    let rows: [Row] = [
        Row(
            name: "setting off keeps the current prompt",
            request: autoRecordRequest(
                enabled: false, evidence: .nativeApp, provider: .zoom, reason: .micInput
            ),
            expected: .prompt
        ),
        Row(
            name: "native Zoom holding the mic auto-starts when every gate passes",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .micInput
            ),
            expected: .autoStart
        ),
        Row(
            name: "native Teams holding the mic auto-starts when every gate passes",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .teams, reason: .micInput
            ),
            expected: .autoStart
        ),
        Row(
            name: "a focused in-call Meet tab that holds the mic auto-starts",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .googleMeet, reason: .micInput
            ),
            expected: .autoStart
        ),
        Row(
            name: "a focused in-call Zoom tab that holds the mic auto-starts",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .zoom, reason: .micInput
            ),
            expected: .autoStart
        ),
        Row(
            name: "a focused in-call Teams tab that holds the mic auto-starts",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .teams, reason: .micInput
            ),
            expected: .autoStart
        ),
        Row(
            name: "a browser tab title alone never auto-starts",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .googleMeet, reason: .micInput,
                holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "a Meet tab title without the browser holding the mic stays a prompt",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .googleMeet, reason: .cameraInput,
                holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "a Meet pre-join screen never auto-starts",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .googleMeet, reason: .micInput,
                isMeetPreJoin: true
            ),
            expected: .prompt
        ),
        Row(
            name: "a named call in a background tab never auto-starts",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .googleMeet, reason: .micInput,
                isFocusedFrontWindow: false
            ),
            expected: .prompt
        ),
        Row(
            name: "proven evidence must hold for a few seconds before auto-start",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .micInput,
                evidenceAge: held - 1
            ),
            expected: .prompt
        ),
        Row(
            name: "camera plus a front browser never auto-starts without the mic",
            request: autoRecordRequest(
                evidence: .camera, provider: .googleMeet, reason: .cameraInput,
                holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "a Meet tab plus the camera still needs the browser on the mic",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .googleMeet, reason: .cameraInput,
                holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "native Webex is not proven and stays a prompt",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .webex, reason: .micInput
            ),
            expected: .prompt
        ),
        Row(
            name: "native FaceTime is not proven and stays a prompt",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .facetime, reason: .micInput
            ),
            expected: .prompt
        ),
        Row(
            name: "a camera-only native Zoom call stays a prompt",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .cameraInput,
                holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "a listen-only native Zoom call stays a prompt",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .audioOutput,
                holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "a Webex tab title is not proven and stays a prompt",
            request: autoRecordRequest(
                evidence: .tabTitle, provider: .webex, reason: .micInput
            ),
            expected: .prompt
        ),
        Row(
            name: "a call-site guess stays a prompt",
            request: autoRecordRequest(
                evidence: .callSite, provider: .teams, reason: .micInput
            ),
            expected: .prompt
        ),
        Row(
            name: "mic-only browser evidence stays a prompt",
            request: autoRecordRequest(
                evidence: .micOnly, provider: .googleMeet, reason: .micInput
            ),
            expected: .prompt
        ),
        Row(
            name: "camera corroboration stays a prompt",
            request: autoRecordRequest(
                evidence: .camera, provider: .googleMeet, reason: .cameraInput,
                holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "mic-and-output browser evidence stays a prompt",
            request: autoRecordRequest(
                evidence: .micAndOutput, provider: .googleMeet, reason: .micInput
            ),
            expected: .prompt
        ),
        Row(
            name: "a calendar prompt stays a prompt",
            request: autoRecordRequest(
                evidence: .none, provider: .zoom, reason: .calendarNearby,
                holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "a calendar event does not block auto-start when the call is proven",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .calendarNearby,
                holdsMicrophone: true
            ),
            expected: .autoStart
        ),
        Row(
            name: "missing microphone permission stays a prompt",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .micInput,
                microphoneGranted: false
            ),
            expected: .prompt
        ),
        Row(
            name: "missing system-audio permission stays a prompt",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .micInput,
                systemAudioGranted: false
            ),
            expected: .prompt
        ),
        Row(
            name: "another capture does not auto-start a proven call",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .micInput,
                otherCaptureActive: true
            ),
            expected: .prompt
        ),
        Row(
            name: "with the setting off, another capture still keeps the calendar prompt",
            request: autoRecordRequest(
                enabled: false, evidence: .none, provider: .zoom, reason: .calendarNearby,
                otherCaptureActive: true, holdsMicrophone: false
            ),
            expected: .prompt
        ),
        Row(
            name: "live system-audio denial never auto-starts",
            request: autoRecordRequest(
                evidence: .nativeApp, provider: .zoom, reason: .micInput,
                systemAudioGranted: false
            ),
            expected: .prompt
        ),
    ]

    for row in rows {
        runSuite("MeetingAutoRecordPolicy — \(row.name)") {
            assertEqual(
                MeetingAutoRecordPolicy.decision(for: row.request),
                row.expected,
                row.name
            )
        }
    }

    runSuite("MeetingAutoRecordPolicy waits a few seconds before auto-start") {
        let waiting = autoRecordRequest(
            evidence: .tabTitle, provider: .googleMeet, reason: .micInput,
            evidenceAge: 0
        )
        assertTrue(
            MeetingAutoRecordPolicy.shouldWaitForEvidenceHold(waiting),
            "a brand-new focused Meet tab should wait, not prompt, while the setting is on"
        )
        let ready = autoRecordRequest(
            evidence: .tabTitle, provider: .googleMeet, reason: .micInput
        )
        assertFalse(
            MeetingAutoRecordPolicy.shouldWaitForEvidenceHold(ready),
            "once the evidence has been held, wait is over"
        )
        let off = autoRecordRequest(
            enabled: false, evidence: .nativeApp, provider: .zoom, reason: .micInput,
            evidenceAge: 0
        )
        assertFalse(
            MeetingAutoRecordPolicy.shouldWaitForEvidenceHold(off),
            "with the setting off, do not delay the current prompt"
        )
    }

    runSuite("MeetingAutoRecordPolicy declines the rest of the call only on Stop or Discard") {
        assertTrue(
            MeetingAutoRecordPolicy.recordsDeclineOnEnd(
                wasAutoStarted: true, userStoppedOrDiscarded: true
            ),
            "Stop or Discard of an auto-started recording must decline the rest of the call"
        )
        assertFalse(
            MeetingAutoRecordPolicy.recordsDeclineOnEnd(
                wasAutoStarted: true, userStoppedOrDiscarded: false
            ),
            "a failed start or unexpected stop must not decline the rest of the call"
        )
        assertFalse(
            MeetingAutoRecordPolicy.recordsDeclineOnEnd(
                wasAutoStarted: false, userStoppedOrDiscarded: true
            ),
            "a recording the user started themselves is not an auto-start decline"
        )
        assertEqual(
            MeetingAutoRecordPolicy.runtimeSuppressionReason(
                cooldownReason: MeetingPromptSuppressionReason.declinedThisCall.rawValue
            ),
            .declinedThisCall,
            "Stop/Discard rest-of-call suppression must report as a decline, not a generic skip"
        )
        assertEqual(
            MeetingAutoRecordPolicy.runtimeSuppressionReason(cooldownReason: "record_selected"),
            .runtimeSuppressed,
            "other runtime cooldowns stay a generic skip"
        )
    }
}

private func autoRecordRequest(
    enabled: Bool = true,
    evidence: MeetingPromptCallEvidence,
    provider: MeetingPromptProvider,
    reason: MeetingPromptReason,
    microphoneGranted: Bool = true,
    systemAudioGranted: Bool = true,
    otherCaptureActive: Bool = false,
    holdsMicrophone: Bool? = nil,
    isFocusedFrontWindow: Bool = true,
    isMeetPreJoin: Bool = false,
    evidenceAge: TimeInterval = MeetingAutoRecordPolicy.evidenceHoldDuration
) -> MeetingAutoRecordPolicy.Request {
    MeetingAutoRecordPolicy.Request(
        autoRecordEnabled: enabled,
        evidence: evidence,
        provider: provider,
        reason: reason,
        microphoneGranted: microphoneGranted,
        systemAudioGranted: systemAudioGranted,
        otherCaptureActive: otherCaptureActive,
        holdsMicrophone: holdsMicrophone ?? (reason == .micInput),
        isFocusedFrontWindow: isFocusedFrontWindow,
        isMeetPreJoin: isMeetPreJoin,
        evidenceAge: evidenceAge
    )
}
