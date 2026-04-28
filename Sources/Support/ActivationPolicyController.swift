// Support/ActivationPolicyController.swift
// Locks NSApp's activation policy to `.regular` so the app has a
// permanent Dock presence (and shows up in Cmd+Option+Esc).
//
// History: this controller used to flip between `.accessory` (menubar
// only) and `.regular` (during a recording) so the app would appear in
// the force-quit dialog only when needed. The product now ships with a
// permanent Dock icon, so the dynamic flip is gone and the recording
// flags are no-ops. Force-quit visibility comes for free as a side
// effect of the always-regular policy. The menubar `NSStatusItem` is
// independent of activation policy and stays visible the whole time.
//
// Thread-safety: this type is `@MainActor` because `NSApplication`
// state is main-thread-only. Callers update the recording flags from
// the main thread; subscribers running on other threads should hop
// before calling `update(...)`.

import AppKit
import Foundation

/// Pure policy decision so we can unit-test it without an `NSApp`
/// instance. Given the current recording flags, returns the activation
/// policy the app should have.
enum ActivationPolicyDecision {

    /// Always `.regular` — the app keeps a permanent Dock presence
    /// regardless of recording state. The recording-flag parameters are
    /// retained so existing callers and tests continue to compile.
    static func desiredPolicy(
        isMeetingRecording: Bool,
        isDictationRecording: Bool
    ) -> NSApplication.ActivationPolicy {
        _ = isMeetingRecording
        _ = isDictationRecording
        return .regular
    }
}

@MainActor
final class ActivationPolicyController {

    /// Most-recently applied policy. Used so we don't redundantly call
    /// `setActivationPolicy(_:)` (which has side effects on the Dock
    /// tile and key-window state).
    private(set) var currentPolicy: NSApplication.ActivationPolicy

    private var isMeetingRecording: Bool = false
    private var isDictationRecording: Bool = false

    /// Indirection so tests can capture policy changes without touching
    /// NSApp.
    private let applyPolicy: (NSApplication.ActivationPolicy) -> Void

    init(
        initialPolicy: NSApplication.ActivationPolicy = .regular,
        applyPolicy: @escaping (NSApplication.ActivationPolicy) -> Void = { policy in
            NSApp.setActivationPolicy(policy)
        }
    ) {
        self.currentPolicy = initialPolicy
        self.applyPolicy = applyPolicy
        applyPolicy(initialPolicy)
    }

    /// Update the meeting-recording flag. Recomputes and applies the
    /// desired policy if it changed.
    func setMeetingRecording(_ active: Bool) {
        guard isMeetingRecording != active else { return }
        isMeetingRecording = active
        reconcile()
    }

    /// Update the dictation-recording flag. Recomputes and applies the
    /// desired policy if it changed.
    func setDictationRecording(_ active: Bool) {
        guard isDictationRecording != active else { return }
        isDictationRecording = active
        reconcile()
    }

    private func reconcile() {
        let desired = ActivationPolicyDecision.desiredPolicy(
            isMeetingRecording: isMeetingRecording,
            isDictationRecording: isDictationRecording
        )
        guard desired != currentPolicy else { return }
        currentPolicy = desired
        applyPolicy(desired)
    }
}
