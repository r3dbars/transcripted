// MeetingOverlayController+PromptCopy.swift
// Prompt copy for the meeting overlay: the system-audio, audio-inactivity,
// Bluetooth-route, mic-boost and missed-call prompts, plus the shared duration
// formatter they use. These builders read only their parameters, so they live in
// their own file to keep MeetingOverlayController inside its file-size baseline.

import Foundation

extension MeetingOverlayController {
    func systemAudioWarningPromptDisplay(
        warning: MeetingSystemAudioDegradationWarning
    ) -> PromptDisplay {
        guard MeetingSystemAudioPromptPolicy.offersActions(for: warning) else {
            // Good news with nothing to decide: just OK, and it hides itself.
            return PromptDisplay(
                title: MeetingSystemAudioDegradationCopy.title(for: warning),
                detail: MeetingSystemAudioDegradationCopy.detail(for: warning),
                countdownText: "",
                secondaryTitle: "OK",
                secondaryAccessibilityLabel: "Dismiss this notice and keep recording",
                primaryTitle: "",
                primaryAccessibilityLabel: ""
            )
        }
        let offersCheckAccess = MeetingSystemAudioCheckAccessPolicy.offersCheckAccess(
            for: warning,
            status: TranscriptedPermissionAccess.refreshSystemAudioRecordingStatusFromSystem()
        )
        return PromptDisplay(
            title: MeetingSystemAudioDegradationCopy.title(for: warning),
            detail: MeetingSystemAudioDegradationCopy.detail(for: warning),
            countdownText: "",
            secondaryTitle: "Continue",
            secondaryAccessibilityLabel: "Acknowledge system audio warning and keep recording",
            primaryTitle: "Stop",
            primaryAccessibilityLabel: "Stop and transcribe the meeting",
            tertiaryTitle: offersCheckAccess ? MeetingMicOnlyNoticeCopy.checkAccessTitle : nil,
            tertiaryAccessibilityLabel: offersCheckAccess ? MeetingMicOnlyNoticeCopy.checkAccessAccessibilityLabel : nil
        )
    }
    func audioInactivityPromptDisplay(
        warning: MeetingAudioInactivityWarning,
        countdownSeconds: Int
    ) -> PromptDisplay {
        if warning.kind == .degradedRoute {
            return PromptDisplay(
                title: "Audio changed",
                detail: "Mic or call audio sounds muted. Still recording.",
                countdownText: "",
                secondaryTitle: "Continue",
                secondaryAccessibilityLabel: "Keep recording",
                primaryTitle: "Stop",
                primaryAccessibilityLabel: "Stop and transcribe the meeting"
            )
        }

        // Same shape as every recording warning: a short statement, one terse
        // detail line, Continue / Stop (the island draws "Stop" red).
        return PromptDisplay(
            title: warning.kind == .callEnded ? "Call ended" : "No sound",
            detail: warning.kind == .callEnded ? "Call audio stopped." : "Nothing heard for \(formatInactiveDuration(warning.inactiveDuration)).",
            // A warning that won't stop on its own shows no countdown.
            countdownText: warning.automaticStopAllowed ? "Stops in \(max(0, countdownSeconds))s" : "",
            secondaryTitle: "Continue",
            secondaryAccessibilityLabel: "Keep recording",
            primaryTitle: "Stop",
            primaryAccessibilityLabel: "Stop and transcribe the meeting"
        )
    }

    func audioRouteWarningPromptDisplay(
        outcome: MeetingRouteWarning
    ) -> PromptDisplay {
        let detail: String
        switch outcome {
        case .switchedToBuiltIn:
            detail = "Switched to the Mac's mic. Sound still plays in your headphones."
        case .builtInUnavailable, .switchFailed:
            detail = "Pick the Mac's mic in System Settings."
        case .notNeeded:
            detail = "Still recording."
        }

        return PromptDisplay(
            title: "Bluetooth mic is dropping out",
            detail: detail,
            countdownText: "",
            secondaryTitle: "Continue",
            secondaryAccessibilityLabel: "Keep recording with the current audio input",
            primaryTitle: "Stop",
            primaryAccessibilityLabel: "Stop and transcribe the meeting"
        )
    }

    // Keep `detail` short: the scope and
    // ducking trade-off must be the detail on its own and fit untruncated
    // (the user has to see the cost before consenting to VPIO), so the
    // cause lives in the title instead. Accepting never saves the mode.
    func micBoostPromptDisplay() -> PromptDisplay {
        PromptDisplay(
            title: "Another call app made your mic quiet",
            detail: "Just this meeting. Other sounds may get quieter.",
            countdownText: "",
            secondaryTitle: "Skip",
            secondaryAccessibilityLabel: "Keep software mic boost",
            primaryTitle: "Boost",
            primaryAccessibilityLabel: "Boost microphone with Apple voice processing"
        )
    }

    // Awareness, not blame: name the call surface and length, then point at the
    // two ways to capture next time. The panel renders `detail` as one
    // truncating line, so the copy stays short.
    func missedCallPromptDisplay(call: MeetingPromptUnrecordedCall) -> PromptDisplay {
        let surface = call.provider == .googleMeet
            ? "Browser call"
            : "\(call.provider.displayName) call"
        let length = formatInactiveDuration(call.duration)
        let shortcut = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.meetingBinding()
        )
        return PromptDisplay(
            title: "\(surface) not recorded",
            detail: "\(length). Next time, click Record or press \(shortcut).",
            countdownText: "",
            secondaryTitle: "Don't show again",
            secondaryAccessibilityLabel: "Disable missed-call reminders",
            primaryTitle: "OK",
            primaryAccessibilityLabel: "Dismiss missed-call reminder"
        )
    }

    func formatInactiveDuration(_ duration: TimeInterval) -> String {
        MeetingDurationFormatter.formatInactiveDuration(duration)
    }
}
