// DictationProcessActivity.swift
// Reference-counted App Nap suppression for the length of a dictation
// session.
//
// Issue #1743: a menubar accessory app that is not frontmost and has no
// visible window is exactly what macOS App Nap targets. Under App Nap the
// process's dispatch queues are demoted and its timers are coalesced, so the
// CoreAudio start work in ParakeetEngine — which runs on a `.userInitiated`
// serial queue — can run slower purely because of where the app sits in the
// window server's ordering. The menu Start Dictation path never sees this:
// clicking the menu bar item makes Transcripted the active app first.
//
// This is the plausible mechanism, not a measured one. No stage has been
// timed running slow on the affected machine; `pending_stage` and
// `stage_pending_for_ms` on `dictation_cancelled_before_microphone_ready`
// are what would show it. Taking this assertion is cheap and correct whether
// or not App Nap turns out to be the cause, which is why it ships ahead of
// the answer.
//
// `ProcessInfo.beginActivity` is the documented, focus-free way to say "this
// process is doing latency-sensitive work right now, do not nap it". Taking
// it before the first microphone open is what makes a hotkey start prepare
// the audio session the way a menu start already does, without activating the
// app and stealing the user's typing focus.
//
// `.userInitiatedAllowingIdleSystemSleep` deliberately rather than
// `.userInitiated`: the latter also asserts `idleSystemSleepDisabled`, and
// dictation has no business changing the machine's sleep policy.
// `.latencyCritical` is the option Apple documents for audio/video capture
// work and is what suppresses timer coalescing.
//
// Reference counted because dictation re-admits a retained recording in a few
// places (see `DictationSessionController`'s stop-finalization readmission),
// and because a stray unbalanced release must never drop an assertion a live
// session still depends on. Balance is keyed on `isDictating` transitions, so
// every path that ends a session — success, cancel, interruption, failure —
// releases it without needing its own cleanup call.

import Foundation

@MainActor
final class DictationProcessActivity {
    static let shared = DictationProcessActivity()

    static let activityOptions: ProcessInfo.ActivityOptions = [
        .userInitiatedAllowingIdleSystemSleep,
        .latencyCritical,
    ]

    typealias Begin = (ProcessInfo.ActivityOptions, String) -> NSObjectProtocol
    typealias End = (NSObjectProtocol) -> Void

    private let begin: Begin
    private let end: End
    private var activity: NSObjectProtocol?
    private var holders = 0

    /// The reason string of the assertion currently held, for diagnostics.
    private(set) var currentReason: String?

    init(
        begin: @escaping Begin = { options, reason in
            ProcessInfo.processInfo.beginActivity(options: options, reason: reason)
        },
        end: @escaping End = { activity in
            ProcessInfo.processInfo.endActivity(activity)
        }
    ) {
        self.begin = begin
        self.end = end
    }

    var isHeld: Bool { activity != nil }
    var holderCount: Int { holders }

    /// Take (or join) the assertion. Safe to call before any audio work and
    /// cheap when App Nap is not engaged.
    func acquire(reason: String) {
        holders += 1
        guard activity == nil else { return }
        activity = begin(Self.activityOptions, reason)
        currentReason = reason
    }

    /// Release one holder. The assertion ends when the last one lets go.
    func release() {
        guard holders > 0 else { return }
        holders -= 1
        guard holders == 0, let activity else { return }
        end(activity)
        self.activity = nil
        currentReason = nil
    }
}
