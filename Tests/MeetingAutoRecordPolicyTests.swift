import Foundation

func testMeetingAutoRecordPolicy() {
    struct Row {
        let name: String
        let autoRecordEnabled: Bool
        let evidence: MeetingPromptCallEvidence
        let provider: MeetingPromptProvider
        let reason: MeetingPromptReason
        let microphoneGranted: Bool
        let systemAudioGranted: Bool
        let otherCaptureActive: Bool
        let expected: MeetingAutoRecordPolicy.Decision
    }

    let rows: [Row] = [
        Row(
            name: "setting off keeps the current prompt",
            autoRecordEnabled: false,
            evidence: .nativeApp, provider: .zoom, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "native Zoom holding the mic auto-starts when every gate passes",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .zoom, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .autoStart
        ),
        Row(
            name: "native Teams holding the mic auto-starts when every gate passes",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .teams, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .autoStart
        ),
        Row(
            name: "a Meet tab title auto-starts when every gate passes",
            autoRecordEnabled: true,
            evidence: .tabTitle, provider: .googleMeet, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .autoStart
        ),
        Row(
            name: "a Zoom tab title auto-starts when every gate passes",
            autoRecordEnabled: true,
            evidence: .tabTitle, provider: .zoom, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .autoStart
        ),
        Row(
            name: "a Teams tab title auto-starts when every gate passes",
            autoRecordEnabled: true,
            evidence: .tabTitle, provider: .teams, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .autoStart
        ),
        Row(
            name: "native Webex is not proven and stays a prompt",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .webex, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "native FaceTime is not proven and stays a prompt",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .facetime, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "a camera-only native Zoom call stays a prompt",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .zoom, reason: .cameraInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "a listen-only native Zoom call stays a prompt",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .zoom, reason: .audioOutput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "a Webex tab title is not proven and stays a prompt",
            autoRecordEnabled: true,
            evidence: .tabTitle, provider: .webex, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "a call-site guess stays a prompt",
            autoRecordEnabled: true,
            evidence: .callSite, provider: .teams, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "mic-only browser evidence stays a prompt",
            autoRecordEnabled: true,
            evidence: .micOnly, provider: .googleMeet, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "camera corroboration stays a prompt",
            autoRecordEnabled: true,
            evidence: .camera, provider: .googleMeet, reason: .cameraInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "mic-and-output browser evidence stays a prompt",
            autoRecordEnabled: true,
            evidence: .micAndOutput, provider: .googleMeet, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "a calendar prompt stays a prompt",
            autoRecordEnabled: true,
            evidence: .none, provider: .zoom, reason: .calendarNearby,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "missing microphone permission stays a prompt",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .zoom, reason: .micInput,
            microphoneGranted: false, systemAudioGranted: true, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "missing system-audio permission stays a prompt",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .zoom, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: false, otherCaptureActive: false,
            expected: .prompt
        ),
        Row(
            name: "another capture already running suppresses the prompt",
            autoRecordEnabled: true,
            evidence: .nativeApp, provider: .zoom, reason: .micInput,
            microphoneGranted: true, systemAudioGranted: true, otherCaptureActive: true,
            expected: .none
        ),
    ]

    for row in rows {
        runSuite("MeetingAutoRecordPolicy — \(row.name)") {
            let decision = MeetingAutoRecordPolicy.decision(
                for: MeetingAutoRecordPolicy.Request(
                    autoRecordEnabled: row.autoRecordEnabled,
                    evidence: row.evidence,
                    provider: row.provider,
                    reason: row.reason,
                    microphoneGranted: row.microphoneGranted,
                    systemAudioGranted: row.systemAudioGranted,
                    otherCaptureActive: row.otherCaptureActive
                )
            )
            assertEqual(decision, row.expected, row.name)
        }
    }
}
