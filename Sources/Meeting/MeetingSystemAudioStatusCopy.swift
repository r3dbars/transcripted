import Foundation

/// User-facing diagnostic copy for system-audio capture status changes.
///
/// The copy mapping is keyed on a Foundation-pure `Case` so it can be
/// unit-tested in the fast-test runner without pulling the
/// AVFoundation/AppKit/CoreAudio-heavy `Audio` module that defines
/// `SystemAudioStatus`. The thin `SystemAudioStatus` overload lives in
/// `MeetingSystemAudioStatusCopy+SystemAudioStatus.swift` (app build only) and
/// forwards each case here, so the two paths stay byte-for-byte aligned.
enum MeetingSystemAudioStatusCopy {
    /// Foundation-pure mirror of `SystemAudioStatus`'s cases.
    enum Case: Equatable {
        case unknown
        case healthy
        case reconnecting
        case silent
        case failed
    }

    static func message(for status: Case) -> String {
        switch status {
        case .unknown:
            return "System audio status reset"
        case .healthy:
            return "System audio capture is healthy"
        case .reconnecting:
            return "System audio capture is reconnecting"
        case .silent:
            return "System audio capture is silent"
        case .failed:
            return "System audio capture failed"
        }
    }
}

/// A recording-scoped, aggregate-only warning latch for system-audio loss.
///
/// The latch deliberately survives a successful reconnect or explicit prompt
/// dismissal so diagnostics and the saved artifact remain labeled as degraded.
/// The normal recording strip stays quiet; only actionable interruption or
/// failure states use the separate prompt UI. No audio, transcript, device, or
/// app identity is retained in this state.
struct MeetingSystemAudioDegradationWarning: Equatable {
    enum Cause: Equatable {
        case interruption
        case silence
        case failure
    }

    enum Phase: Equatable {
        case recovering
        case degraded
        case recovered

        var diagnosticName: String {
            switch self {
            case .recovering: return "recovering"
            case .degraded: return "degraded"
            case .recovered: return "recovered"
            }
        }
    }

    let cause: Cause
    let phase: Phase
    let isPromptDismissed: Bool

    var shouldPresentPrompt: Bool {
        cause != .silence && !isPromptDismissed
    }

    func dismissingPrompt() -> MeetingSystemAudioDegradationWarning {
        MeetingSystemAudioDegradationWarning(
            cause: cause,
            phase: phase,
            isPromptDismissed: true
        )
    }
}

enum MeetingSystemAudioDegradationPolicy {
    static func next(
        current: MeetingSystemAudioDegradationWarning?,
        status: MeetingSystemAudioStatusCopy.Case,
        isRecording: Bool
    ) -> MeetingSystemAudioDegradationWarning? {
        guard isRecording else { return nil }

        switch status {
        case .unknown:
            // Unknown is a transient/reset state, not proof that an already
            // observed degradation recovered. Keep the recording-scoped latch.
            return current
        case .healthy:
            guard let current else { return nil }
            return MeetingSystemAudioDegradationWarning(
                cause: current.cause,
                phase: .recovered,
                isPromptDismissed: current.isPromptDismissed
            )
        case .reconnecting:
            return MeetingSystemAudioDegradationWarning(
                cause: .interruption,
                phase: .recovering,
                isPromptDismissed: carriesPromptDismissal(
                    from: current,
                    for: .interruption
                )
            )
        case .silent:
            return MeetingSystemAudioDegradationWarning(
                cause: .silence,
                phase: .degraded,
                isPromptDismissed: carriesPromptDismissal(
                    from: current,
                    for: .silence
                )
            )
        case .failed:
            return MeetingSystemAudioDegradationWarning(
                cause: .failure,
                phase: .degraded,
                isPromptDismissed: carriesPromptDismissal(
                    from: current,
                    for: .failure
                )
            )
        }
    }

    private static func carriesPromptDismissal(
        from current: MeetingSystemAudioDegradationWarning?,
        for cause: MeetingSystemAudioDegradationWarning.Cause
    ) -> Bool {
        guard let current,
              current.phase != .recovered,
              current.cause == cause else {
            return false
        }
        return current.isPromptDismissed
    }
}

enum MeetingSystemAudioPromptPolicy {
    static func shouldPresentSystemAudioPrompt(
        warning: MeetingSystemAudioDegradationWarning?,
        hasAudioInactivityWarning: Bool
    ) -> Bool {
        warning?.shouldPresentPrompt == true && !hasAudioInactivityWarning
    }
}

enum MeetingSystemAudioDegradationCopy {
    static func title(for warning: MeetingSystemAudioDegradationWarning) -> String {
        switch (warning.cause, warning.phase) {
        case (.interruption, .recovering):
            return "System audio interrupted"
        case (.interruption, .recovered):
            return "System audio reconnected"
        case (.silence, .recovered):
            return "System audio resumed"
        case (.failure, .recovered):
            return "System audio restored"
        case (.failure, _):
            return "System audio unavailable"
        case (.silence, _):
            return "System audio is silent"
        case (.interruption, .degraded):
            return "System audio interrupted"
        }
    }

    static func detail(for warning: MeetingSystemAudioDegradationWarning) -> String {
        switch (warning.cause, warning.phase) {
        case (.interruption, .recovering):
            return "Trying once to reconnect. Your mic recording is still safe."
        case (.interruption, .recovered):
            return "Mic is safe. This transcript will be marked degraded."
        case (.silence, .recovered), (.failure, .recovered):
            return "Mic is safe. This transcript will still be marked degraded."
        case (.failure, _):
            return "Mic is still recording. This transcript will be saved as partial."
        case (.silence, _):
            return "Transcripted is still recording your mic."
        case (.interruption, .degraded):
            return "Mic is still recording. This transcript will be marked degraded."
        }
    }

    static func accessibilityLabel(for warning: MeetingSystemAudioDegradationWarning) -> String {
        "\(title(for: warning)). \(detail(for: warning))"
    }
}
