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
        case unverified
        /// The tap heard only silence for a sustained stretch, after its own
        /// reconnects, while another app kept playing: the call is probably
        /// not being recorded. A real loss, so it degrades the saved capture.
        case unheardPlayback
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
    /// True once an interruption or failure has been observed at any point
    /// in this recording. `cause` is overwritten on every status transition,
    /// so an interruption followed by prolonged silence ends with
    /// `cause == .silence`; the saved-capture degraded stamp must not lose
    /// the earlier real degradation because of that.
    var observedNonSilenceCause: Bool = false

    var shouldPresentPrompt: Bool {
        cause != .silence && !isPromptDismissed
    }

    /// Whether the saved capture health should be marked degraded for this
    /// recording. Silence alone is legitimate (the remote side went quiet)
    /// and stays visible via `system_status`; only an interruption or
    /// failure, at any point in the recording, degrades the saved artifact.
    var degradesSavedCapture: Bool {
        (cause != .silence && cause != .unverified) || observedNonSilenceCause
    }

    func dismissingPrompt() -> MeetingSystemAudioDegradationWarning {
        MeetingSystemAudioDegradationWarning(
            cause: cause,
            phase: phase,
            isPromptDismissed: true,
            observedNonSilenceCause: observedNonSilenceCause
        )
    }
}

enum MeetingSystemAudioDegradationPolicy {
    /// A quiet recording is not a failure, but users must know when this
    /// recording has never received system signal. Dismissal acknowledges the
    /// uncertainty; only actual PCM evidence resolves it. Real failures win.
    static func reconcilingSignalVerification(
        current: MeetingSystemAudioDegradationWarning?,
        signalVerified: Bool,
        shouldWarn: Bool,
        isRecording: Bool
    ) -> MeetingSystemAudioDegradationWarning? {
        guard isRecording else { return nil }
        if signalVerified { return current?.cause == .unverified ? nil : current }
        guard shouldWarn else { return current }
        if let current, current.cause != .silence { return current }
        return MeetingSystemAudioDegradationWarning(
            cause: .unverified, phase: .degraded, isPromptDismissed: false,
            observedNonSilenceCause: current?.degradesSavedCapture ?? false
        )
    }

    /// The call is playing but the tap hears silence. This is a loss whether
    /// or not earlier signal verified the recording, so it replaces an
    /// unverified or silence notice. An interruption or failure already on
    /// screen keeps its own copy.
    ///
    /// When real signal returns there are two cases. If it came back only
    /// after a new tap or output (`playbackLossConfirmed`), the call really
    /// was lost: the notice moves to recovered and the saved capture stays
    /// degraded. If the same tap heard it, the call was just quiet (a lobby,
    /// nobody talking): the notice goes away and nothing is degraded, unless
    /// an earlier interruption already degraded this meeting.
    static func reconcilingUnheardPlayback(
        current: MeetingSystemAudioDegradationWarning?,
        notHearingPlayback: Bool,
        playbackLossConfirmed: Bool = false,
        isRecording: Bool
    ) -> MeetingSystemAudioDegradationWarning? {
        guard isRecording else { return nil }
        guard notHearingPlayback else {
            guard let current, current.cause == .unheardPlayback, current.phase != .recovered else {
                return current
            }
            guard playbackLossConfirmed || current.observedNonSilenceCause else { return nil }
            return MeetingSystemAudioDegradationWarning(
                cause: .unheardPlayback,
                phase: .recovered,
                isPromptDismissed: current.isPromptDismissed,
                observedNonSilenceCause: true
            )
        }
        if let current {
            switch current.cause {
            case .unheardPlayback where current.phase != .recovered:
                return current
            case .interruption where current.phase == .recovering, .failure where current.phase != .recovered:
                return current
            default:
                break
            }
        }
        // `observedNonSilenceCause` remembers whether something before this
        // notice already degraded the meeting, so a false alarm can't undo it.
        return MeetingSystemAudioDegradationWarning(
            cause: .unheardPlayback,
            phase: .degraded,
            isPromptDismissed: false,
            observedNonSilenceCause: current?.degradesSavedCapture ?? false
        )
    }

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
            // Buffers flowing proves neither signal nor that the tap hears
            // the playing call; only the signal checks clear these.
            if current.cause == .unverified || current.cause == .unheardPlayback { return current }
            return MeetingSystemAudioDegradationWarning(
                cause: current.cause,
                phase: .recovered,
                isPromptDismissed: current.isPromptDismissed,
                observedNonSilenceCause: current.degradesSavedCapture
            )
        case .reconnecting:
            return MeetingSystemAudioDegradationWarning(
                cause: .interruption,
                phase: .recovering,
                isPromptDismissed: carriesPromptDismissal(
                    from: current,
                    for: .interruption
                ),
                observedNonSilenceCause: true
            )
        case .silent:
            if current?.cause == .unverified || current?.cause == .unheardPlayback { return current }
            return MeetingSystemAudioDegradationWarning(
                cause: .silence,
                phase: .degraded,
                isPromptDismissed: carriesPromptDismissal(
                    from: current,
                    for: .silence
                ),
                observedNonSilenceCause: current?.degradesSavedCapture ?? false
            )
        case .failed:
            return MeetingSystemAudioDegradationWarning(
                cause: .failure,
                phase: .degraded,
                isPromptDismissed: carriesPromptDismissal(
                    from: current,
                    for: .failure
                ),
                observedNonSilenceCause: true
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
        case (.unverified, _):
            return "System audio not verified"
        case (.unheardPlayback, .recovered):
            return "Call audio is back"
        case (.unheardPlayback, _):
            return "Can't hear the call"
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
        case (.unverified, _):
            return "Mic is recording. Check System Audio in Settings."
        case (.unheardPlayback, .recovered):
            return "Mic is safe. This transcript will still be marked degraded."
        case (.unheardPlayback, _):
            return "Audio is playing but Transcripted hears silence. Mic is safe."
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
