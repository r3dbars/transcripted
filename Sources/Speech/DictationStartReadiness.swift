// DictationStartReadiness.swift
// How a dictation start prepares the process, decided purely from "was
// Transcripted the active app when the start was requested".
//
// Issue #1743 context, and what is and is not established:
//
// ESTABLISHED. The error the reporter sees ("Mic wasn't ready yet. Nothing
// was recorded.") is produced in exactly one place —
// DictationSessionController.cancelPendingDictationStartAfterEarlyRelease —
// and only when the user's own hotkey ends a session whose microphone start
// had not landed yet (a push-to-talk release, or a hands-free second press;
// both arrive as `trigger: physical_key`). A start that exhausts the wait
// budget surfaces a different message entirely, with a Try Again button. So
// neither the wait budget nor the per-operation CoreAudio fences are part of
// this profile: raising either could not affect that symptom, because the
// user ends the session before either one expires.
//
// SETTLED, 2026-09-21, and not the way this file first guessed. The reporter
// posted his own log lines: three failures at 76ms, 22ms and 72ms, each with
// `format_ready=true`. He had Push to Talk configured and was tapping the key
// instead of holding it, so the session ended before the microphone could
// finish opening. He changed the setting and closed the issue himself.
//
// So the start was never slow, and the App Nap mechanism below — a menubar
// accessory app is an App Nap candidate, and App Nap demotes the QoS of
// `com.transcripted.parakeet.audio-engine` — did not explain #1743. It was
// labelled an inference rather than a diagnosis at the time, which was the
// right call. The suppression stays because it is cheap and correct on its
// own terms, not because it fixed that report; the diagnostics are what
// actually answered it. The user-facing half of the fix lives in
// DictationEarlyReleasePresentationPolicy.
//
// So this profile decides two things only, both cheap and both correct under
// either reading of #1743:
//
//   1. whether to hold the App Nap suppression assertion's "background" label
//      (the assertion itself is taken for every session — see
//      DictationProcessActivity), and what the diagnostics call this start;
//   2. whether a failed native start may escalate to the bounded
//      foreground-activation handshake.
//
// It deliberately does NOT carry CoreAudio timeouts. An earlier revision did,
// applied by setting mutable "fence in flight" properties on ParakeetEngine.
// That was wrong twice over: ParakeetEngine is @MainActor and a start
// suspends many times, so prewarm, device recovery and zombie recovery would
// read the widened values whenever they interleaved with a suspended start;
// and the recovery restarts (ParakeetDeviceRecovery, ParakeetZombieEngineRecovery,
// ParakeetSharedMeetingMicBridge) call `startRecording()` with the default, so
// later attempts silently dropped back to the foreground fences anyway. Doing
// it properly means threading a profile through `audioInputSnapshot` and
// `runTimedAudioEngineWork`, which is a real change to the least-covered code
// in the repo in service of a mechanism nobody has measured. Not worth it
// until #1743's timing question is answered.
//
// Nothing here changes the menu path, and nothing here changes stopping a
// live session.

import Foundation

/// The readiness plan for one dictation start.
struct DictationStartReadinessProfile: Equatable {
    /// True when Transcripted was not the active app at start-request time.
    ///
    /// Sampled synchronously from `NSApp.isActive` in `startDictation`, so it
    /// means "was frontmost at the instant the start was requested", not
    /// "stays frontmost while the microphone opens". The menu path in
    /// particular calls `sourceApp?.activate` on the line before, handing
    /// focus back to the user's app — AppKit activation is asynchronous, so
    /// that start still samples as foreground and then loses the foreground
    /// moments later. That is the intended reading: what this stands in for
    /// is "the process was being used a moment ago", which is what decides
    /// whether App Nap has had a chance to demote it.
    let isBackgroundStart: Bool

    /// Whether this start may escalate to the bounded foreground-activation
    /// handshake after a native start failure. Only hotkey-originated starts
    /// may: a menu or overlay start is already foreground, and a start the
    /// user did not trigger from another app must never steal their focus.
    let allowsForegroundActivationEscalation: Bool

    /// Stable name for diagnostics/telemetry.
    var name: String { isBackgroundStart ? "background" : "foreground" }

    static let foreground = DictationStartReadinessProfile(
        isBackgroundStart: false,
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
            allowsForegroundActivationEscalation: isHotkeyTrigger(triggerRawValue)
        )
    }
}

enum DictationMicrophoneStartStage: String {
    case openingMicrophone = "opening_microphone"
    case waitingForAudioRoute = "waiting_for_audio_route"
}

/// Reports the native-open boundary, not the surrounding readiness or focus
/// recovery waits. Reporting must not change the result: a late success still
/// needs the caller's existing cancellation cleanup to stop the microphone.
@MainActor
enum DictationMicrophoneStartReporting {
    static func run(
        isCurrentSession: () -> Bool,
        onStageChanged: ((DictationMicrophoneStartStage) -> Void)?,
        start: () async -> Bool
    ) async -> Bool {
        if !Task.isCancelled, isCurrentSession() {
            onStageChanged?(.openingMicrophone)
        }
        let started = await start()
        if !started, !Task.isCancelled, isCurrentSession() {
            onStageChanged?(.waitingForAudioRoute)
        }
        return started
    }
}
