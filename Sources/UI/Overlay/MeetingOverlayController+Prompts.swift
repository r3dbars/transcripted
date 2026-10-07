// MeetingOverlayController+Prompts.swift
// Warning-prompt resolution, prompt countdown and prompt display builders for the meeting overlay.

import AppKit
import Combine
import TranscriptedCore

@available(macOS 14.0, *)
extension MeetingOverlayController {

    /// Single entry point for all four warning-driven prompts. Fires whenever
    /// any of them changes (see the CombineLatest4 subscription in
    /// `wireSubscriptions`), recomputes the winning kind via
    /// `MeetingPromptPriority.resolve`, and renders it — replacing the old
    /// four apply*/clear* method pairs that re-derived the same precedence
    /// by hand.
    func applyWarningPrompt(
        inactivity: MeetingAudioInactivityWarning?,
        systemAudio: MeetingSystemAudioDegradationWarning?,
        micBoostVisible: Bool,
        route: CaptureRouteStabilizationOutcome?
    ) {
        systemAudioDegradationWarning = systemAudio
        audioRouteWarningOutcome = route

        let resolvedKind = MeetingPromptPriority.resolve(
            inactivity: inactivity,
            systemAudio: systemAudio,
            routeActive: route != nil,
            micBoostVisible: micBoostVisible,
            current: promptKind,
            isRecording: meetingSession?.state == .recording
        )

        guard let resolvedKind else {
            lastAppliedAudioInactivityWarning = nil
            cancelSystemAudioAutoHide()
            if isWarningDrivenPromptKind(promptKind) {
                clearWarningPrompt()
            } else if state == .recording {
                pushToView()
            }
            return
        }

        if resolvedKind == .audioInactivity, promptKind == .audioInactivity,
           inactivity == lastAppliedAudioInactivityWarning {
            // Already showing this exact inactivity warning and some
            // unrelated signal is what changed. Its per-second countdown
            // Task is still ticking down — don't restart it under a fresh
            // value.
            return
        }

        guard let display = promptDisplay(
            for: resolvedKind,
            inactivity: inactivity,
            systemAudio: systemAudio,
            route: route
        ) else {
            // Resolver and display builder disagreed about which raw signal
            // backs `resolvedKind` — shouldn't happen; leave the previous
            // prompt state untouched rather than show a blank prompt.
            return
        }

        autoHideTask?.cancel()
        promptCountdownTask?.cancel()
        promptKind = resolvedKind
        promptSecondsRemaining = display.countdownSeconds
        currentPrompt = display.prompt
        if resolvedKind == .audioInactivity {
            lastAppliedAudioInactivityWarning = inactivity
        }
        state = presentationState(session: meetingSession?.state ?? .idle, prompt: promptKind)
        showPanel()
        pushToView()
        if display.schedulesCountdown {
            schedulePromptCountdown()
        }
        updateSystemAudioAutoHide(kind: resolvedKind, warning: systemAudio)
    }

    /// A recovered system-audio notice hides itself through the normal
    /// acknowledgement, so the meeting stays marked degraded. Re-applying
    /// the same notice (another signal changed) keeps the running timer.
    private func updateSystemAudioAutoHide(
        kind: PromptKind,
        warning: MeetingSystemAudioDegradationWarning?
    ) {
        guard kind == .systemAudio,
              let warning,
              let seconds = MeetingSystemAudioPromptPolicy.autoHideSeconds(for: warning) else {
            cancelSystemAudioAutoHide()
            return
        }
        if systemAudioAutoHideTask != nil, systemAudioAutoHideWarning == warning { return }
        systemAudioAutoHideTask?.cancel()
        systemAudioAutoHideWarning = warning
        systemAudioAutoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.systemAudioAutoHideTask = nil
            self.systemAudioAutoHideWarning = nil
            guard self.promptKind == .systemAudio,
                  self.systemAudioDegradationWarning == warning else { return }
            self.meetingSession?.acknowledgeSystemAudioDegradationWarning(automatic: true)
        }
    }

    private func cancelSystemAudioAutoHide() {
        systemAudioAutoHideTask?.cancel()
        systemAudioAutoHideTask = nil
        systemAudioAutoHideWarning = nil
    }

    /// Builds the display copy for the resolved warning-prompt kind, plus
    /// whether it starts a countdown (only audio inactivity does — its
    /// countdown can auto-stop the recording; the others never expire on
    /// their own).
    private func promptDisplay(
        for kind: PromptKind,
        inactivity: MeetingAudioInactivityWarning?,
        systemAudio: MeetingSystemAudioDegradationWarning?,
        route: CaptureRouteStabilizationOutcome?
    ) -> (prompt: PromptDisplay, countdownSeconds: Int, schedulesCountdown: Bool)? {
        switch kind {
        case .systemAudio:
            guard let systemAudio else { return nil }
            return (systemAudioWarningPromptDisplay(warning: systemAudio), 0, false)
        case .audioInactivity:
            guard let inactivity else { return nil }
            let seconds = inactivity.automaticStopAllowed ? max(1, inactivity.countdownSeconds) : 0
            return (
                audioInactivityPromptDisplay(warning: inactivity, countdownSeconds: seconds),
                seconds,
                inactivity.automaticStopAllowed
            )
        case .audioRoute:
            guard let route else { return nil }
            return (audioRouteWarningPromptDisplay(outcome: route), 0, false)
        case .micBoost:
            // No schedulePromptCountdown(): expiry must never auto-enable VPIO.
            return (micBoostPromptDisplay(), 0, false)
        case .missedCall:
            return nil
        }
    }

    private func isWarningDrivenPromptKind(_ kind: PromptKind?) -> Bool {
        switch kind {
        case .systemAudio, .audioInactivity, .audioRoute, .micBoost:
            return true
        case .missedCall, .none:
            return false
        }
    }

    /// Common "nothing left to show" path once the resolver returns nil for
    /// a previously-active warning prompt.
    private func clearWarningPrompt() {
        promptCountdownTask?.cancel()
        promptKind = nil
        currentPrompt = nil

        if meetingSession?.state == .recording {
            state = presentationState(session: .recording, prompt: nil)
            showPanel()
            pushToView()
        } else {
            state = .idle
            hidePanel()
        }
    }

    func schedulePromptCountdown() {
        promptCountdownTask?.cancel()
        promptCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while self.promptSecondsRemaining > 0 {
                self.refreshPromptCountdownDisplay()
                self.pushToView()

                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.promptSecondsRemaining -= 1
            }

            self.handlePromptCountdownExpired()
        }
    }

    private func refreshPromptCountdownDisplay() {
        switch promptKind {
        case .systemAudio:
            if let warning = systemAudioDegradationWarning {
                currentPrompt = systemAudioWarningPromptDisplay(warning: warning)
            }
        case .audioInactivity:
            let warning = meetingSession?.audioInactivityWarning
                ?? MeetingAudioInactivityWarning(
                    inactiveDuration: 5 * 60,
                    countdownSeconds: max(1, promptSecondsRemaining)
                )
            currentPrompt = audioInactivityPromptDisplay(
                warning: warning,
                countdownSeconds: promptSecondsRemaining
            )
        case .micBoost:
            currentPrompt = micBoostPromptDisplay()
        case .audioRoute:
            if let outcome = audioRouteWarningOutcome {
                currentPrompt = audioRouteWarningPromptDisplay(outcome: outcome)
            }
        case .missedCall:
            if let call = missedCallPrompt {
                currentPrompt = missedCallPromptDisplay(call: call)
            }
        case .none:
            break
        }
    }

    private func handlePromptCountdownExpired() {
        switch promptKind {
        case .systemAudio:
            return
        case .micBoost:
            // Defensive no-op: a countdown is never scheduled for this kind,
            // and expiry must never auto-enable VPIO.
            return
        case .audioRoute:
            return
        case .audioInactivity:
            guard meetingSession?.audioInactivityWarning?.automaticStopAllowed != false else {
                return
            }
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.endRecordingFromAudioInactivityPrompt(automatic: true)
            }
        case .missedCall:
            onMissedCallNudgeResolved?(.expired)
            dismissPrompt()
        case .none:
            dismissPrompt()
        }
    }

    private func systemAudioWarningPromptDisplay(
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
    private func audioInactivityPromptDisplay(
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

        return PromptDisplay(
            title: "No sound",
            detail: "Nothing heard for \(formatInactiveDuration(warning.inactiveDuration)).",
            countdownText: "Stops in \(max(0, countdownSeconds))s",
            secondaryTitle: "Continue",
            secondaryAccessibilityLabel: "Keep recording",
            primaryTitle: "Stop",
            primaryAccessibilityLabel: "Stop and transcribe the meeting"
        )
    }

    private func audioRouteWarningPromptDisplay(
        outcome: CaptureRouteStabilizationOutcome
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
    private func micBoostPromptDisplay() -> PromptDisplay {
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

    private func formatInactiveDuration(_ duration: TimeInterval) -> String {
        MeetingDurationFormatter.formatInactiveDuration(duration)
    }
}
