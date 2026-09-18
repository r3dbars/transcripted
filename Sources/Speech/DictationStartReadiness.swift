// DictationStartReadiness.swift
// How a dictation start prepares the process and the CoreAudio budgets it
// runs under, decided purely from "was Transcripted frontmost when the start
// was requested".
//
// Issue #1743: the menu Start Dictation path is inherently foreground — the
// user has just clicked Transcripted's menu bar item, so the process is the
// active app and macOS App Nap cannot be engaged on it. The global hotkey
// path is the opposite: a menubar accessory app with no visible window that
// is not frontmost is a textbook App Nap candidate, and App Nap demotes the
// QoS of the very dispatch queue (`com.transcripted.parakeet.audio-engine`)
// that every CoreAudio start operation runs on, while coalescing the timers
// the bounded-timeout machinery depends on. Every one of those operations is
// fenced by `audioStartOperationTimeout`; when the fence trips, the start
// path abandons the audio graph, marks the input format unready, and burns a
// slot in the four-worker `ParakeetTimedAudioEngineWorkLimiter` circuit. Two
// of those in a row and the circuit opens, which is a hard failure for the
// rest of the wait budget.
//
// So the two things a background start needs, before the first microphone
// open rather than after it has already failed, are:
//
//   1. an App Nap suppression assertion (see DictationProcessActivity), so
//      the audio-engine queue runs at the priority the foreground path gets
//      for free, and
//   2. wider CoreAudio budgets, because an endpoint-security product that
//      hooks microphone device opens (the reporter runs CrowdStrike Falcon)
//      can push a cold background HAL open past a foreground-sized fence
//      even once App Nap is out of the way.
//
// Foreground starts keep the existing budgets exactly. Nothing here changes
// the menu path, and nothing here changes stopping a live session.

import Foundation

/// The readiness plan for one dictation start.
struct DictationStartReadinessProfile: Equatable {
    /// True when Transcripted was not the active app at start-request time.
    let isBackgroundStart: Bool

    /// Fence for a single CoreAudio start operation before the graph is
    /// treated as blocked and abandoned.
    let audioStartOperationTimeoutNanoseconds: UInt64

    /// Fence for a single CoreAudio system-input operation — the route
    /// selection lookup a start does before it can read any format. It has
    /// its own serialized worker and its own circuit breaker, so widening
    /// only the audio-engine fence would leave a background start failing
    /// here instead.
    let systemInputOperationTimeoutNanoseconds: UInt64

    /// Total budget the dictation wait loop may spend getting the microphone
    /// open before it reports `microphone_start_timeout`.
    let recoveryBudget: TimeInterval

    /// Whether this start may escalate to the bounded foreground-activation
    /// handshake after a native start failure. Only hotkey-originated starts
    /// may: a menu or overlay start is already foreground, and a start the
    /// user did not trigger from another app must never steal their focus.
    let allowsForegroundActivationEscalation: Bool

    /// Stable name for diagnostics/telemetry.
    var name: String { isBackgroundStart ? "background" : "foreground" }

    static let foreground = DictationStartReadinessProfile(
        isBackgroundStart: false,
        audioStartOperationTimeoutNanoseconds: TranscriptedConstants.audioStartOperationTimeout,
        systemInputOperationTimeoutNanoseconds: TranscriptedConstants.systemInputOperationTimeout,
        recoveryBudget: TranscriptedConstants.dictationRecoveryBudget,
        allowsForegroundActivationEscalation: false
    )
}

enum DictationStartReadinessPolicy {
    /// Trigger raw values (`DictationSessionController.DictationTrigger`) that
    /// can fire while another app owns the foreground. Raw strings rather than
    /// the enum itself so this policy stays free of the AppKit-bound
    /// controller and remains directly fast-testable.
    static let hotkeyTriggerRawValues: Set<String> = [
        "physical_key",
        "keyboard_shortcut",
        "right_option_tap",
    ]

    static func isHotkeyTrigger(_ triggerRawValue: String) -> Bool {
        hotkeyTriggerRawValues.contains(triggerRawValue)
    }

    /// App Nap is a property of the process, not of the trigger: if
    /// Transcripted is not the active app when the start is requested, the
    /// background plan applies whichever way the start was requested. The
    /// trigger only decides whether the focus-stealing escalation is allowed.
    static func profile(
        triggerRawValue: String,
        isAppActive: Bool
    ) -> DictationStartReadinessProfile {
        guard !isAppActive else { return .foreground }
        return DictationStartReadinessProfile(
            isBackgroundStart: true,
            audioStartOperationTimeoutNanoseconds:
                TranscriptedConstants.audioStartOperationTimeoutBackgroundStart,
            systemInputOperationTimeoutNanoseconds:
                TranscriptedConstants.systemInputOperationTimeoutBackgroundStart,
            recoveryBudget: TranscriptedConstants.dictationBackgroundStartRecoveryBudget,
            allowsForegroundActivationEscalation: isHotkeyTrigger(triggerRawValue)
        )
    }
}
