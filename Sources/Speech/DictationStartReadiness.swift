// DictationStartReadiness.swift
// How a dictation start prepares the process and which CoreAudio fences it
// runs under, decided purely from "was Transcripted frontmost when the start
// was requested".
//
// Issue #1743 context, and what is and is not established:
//
// ESTABLISHED. The error the reporter sees ("Mic wasn't ready yet. Nothing
// was recorded.") is produced in exactly one place —
// DictationSessionController.cancelPendingDictationStartAfterEarlyRelease —
// and only when the user's own hotkey ends a session whose microphone start
// had not landed yet (a push-to-talk release, or a hands-free second press;
// both arrive as `trigger: physical_key`). A start that exhausts the wait
// budget surfaces a different message entirely. So the wait budget is NOT
// part of this profile: raising it could not affect that symptom, because the
// user ends the session first.
//
// NOT ESTABLISHED. Why the start had not landed. The reporter's own
// workaround — foreground Transcripted immediately before the hotkey and it
// succeeds — points at the start being slower from the background, and there
// is a plausible mechanism: a menubar accessory app that is not frontmost is
// an App Nap candidate, App Nap demotes the QoS of the serial queue
// (`com.transcripted.parakeet.audio-engine`) every CoreAudio start operation
// runs on and coalesces the timers the fence machinery depends on, and a
// tripped fence is expensive (graph abandoned, input format marked unready, a
// slot consumed in the four-worker ParakeetTimedAudioEngineWorkLimiter
// circuit). But nobody has measured a stage actually exceeding its fence on
// the affected machine. It is an inference, not a diagnosis.
//
// So this file does the two things that are cheap, reversible, and correct
// under either reading — suppress App Nap for the session (see
// DictationProcessActivity) and give a background start's CoreAudio stages
// more room before they are declared blocked — while the diagnostics on the
// cancel path carry the number that would settle it (`pending_for_ms`).
//
// Foreground starts keep the existing fences exactly. Nothing here changes
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
        allowsForegroundActivationEscalation: false
    )
}

enum DictationStartReadinessPolicy {
    /// Trigger raw values (`DictationSessionController.DictationTrigger`) that
    /// can fire while another app owns the foreground. Raw strings rather than
    /// the enum itself so this policy stays free of the AppKit-bound
    /// controller and remains directly fast-testable.
    ///
    /// Only `physical_key` is listed because it is the only trigger anything
    /// emits for a global hotkey: `ContextCaptureEngine` uses it for both the
    /// push-to-talk press/release pair AND the hands-free toggle (the default
    /// mode). `DictationTrigger.keyboardShortcut` and `.rightOptionTap` are
    /// declared but never constructed anywhere in the tree — #1744's guard
    /// listed them, which read as coverage it did not have. Wire them up here
    /// if something ever emits them.
    static let hotkeyTriggerRawValues: Set<String> = [
        "physical_key",
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
            allowsForegroundActivationEscalation: isHotkeyTrigger(triggerRawValue)
        )
    }
}
