// Support/ActivationPolicyController.swift
// Dynamically switches NSApp's activation policy so an active recording
// session shows up in the macOS force-quit dialog (Cmd+Option+Esc).
//
// Background: Transcripted is a menubar app, so it normally runs with
// activation policy `.accessory` and `LSUIElement = true`. macOS hides
// `.accessory` apps from the force-quit dialog; if the app freezes during
// a recording, the user has to open Activity Monitor to kill it. Reported
// pain: Taylor's meeting widget froze and the only recovery was Activity
// Monitor.
//
// Fix shape: while a recording is active (meeting OR dictation), switch
// to `.regular` so the app appears in the force-quit dialog. When all
// sessions stop, switch back to `.accessory`. The Dock icon flickers in
// for the duration of the recording — acceptable trade for a recovery
// path. The menubar `NSStatusItem` is independent of activation policy
// and stays visible the whole time.
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

    /// Returns `.regular` if any session is active so the app shows in
    /// the force-quit dialog. Otherwise returns `.accessory` to keep
    /// the Dock clean.
    static func desiredPolicy(
        isMeetingRecording: Bool,
        isDictationRecording: Bool
    ) -> NSApplication.ActivationPolicy {
        if isMeetingRecording || isDictationRecording {
            return .regular
        }
        return .accessory
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
        initialPolicy: NSApplication.ActivationPolicy = .accessory,
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
