// MeetingOverlayController+WarningPrompts.swift
// The warning prompts' display copy, the system-audio auto-hide timer and
// the per-second prompt countdown with what happens when it runs out. Split
// out of MeetingOverlayController.swift to keep it under the file-size limit.

import Foundation

extension MeetingOverlayController {
    /// A recovered system-audio notice hides itself through the normal
    /// acknowledgement, so the meeting stays marked degraded. Re-applying
    /// the same notice (another signal changed) keeps the running timer.
    func updateSystemAudioAutoHide(
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

    func cancelSystemAudioAutoHide() {
        systemAudioAutoHideTask?.cancel()
        systemAudioAutoHideTask = nil
        systemAudioAutoHideWarning = nil
    }

    /// Builds the display copy for the resolved warning-prompt kind, plus
    /// whether it starts a countdown (only audio inactivity does — its
    /// countdown can auto-stop the recording; the others never expire on
    /// their own).
    func promptDisplay(
        for kind: PromptKind,
        inactivity: MeetingAudioInactivityWarning?,
        systemAudio: MeetingSystemAudioDegradationWarning?,
        route: MeetingRouteWarning?
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

    func isWarningDrivenPromptKind(_ kind: PromptKind?) -> Bool {
        switch kind {
        case .systemAudio, .audioInactivity, .audioRoute, .micBoost:
            return true
        case .missedCall, .none:
            return false
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
            guard let warning = meetingSession?.audioInactivityWarning else { return }
            switch MeetingInactivityCountdownExpiry.resolve(
                isCallEnded: warning.kind == .callEnded,
                automaticStopAllowed: warning.automaticStopAllowed
            ) {
            case .noAutomaticStop:
                return
            case .confirmCallEndedThenStop:
                // The session reads the call app's audio now and either stops
                // at 0 or leaves Continue / Stop up without a countdown.
                Task { @MainActor [weak self] in
                    guard let session = self?.meetingSession else { return }
                    await session.resolveCallEndCountdownExpiry(warning)
                }
            case .stop:
                Task { @MainActor [weak self] in
                    guard let session = self?.meetingSession else { return }
                    await session.endRecordingFromAudioInactivityPrompt(automatic: true, expectedWarning: warning)
                }
            }
        case .missedCall:
            onMissedCallNudgeResolved?(.expired)
            dismissPrompt()
        case .none:
            dismissPrompt()
        }
    }
}
