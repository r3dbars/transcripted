// Support/ActivationPolicyController.swift
// Keeps NSApp in the right activation mode for Dock visibility and
// recording safety.
//
// When the Dock toggle is on, Transcripted stays `.regular` all the
// time. When it is off, Transcripted idles as `.accessory` but still
// promotes itself to `.regular` during active dictation or meeting
// capture so it stays visible in Cmd+Option+Esc for recovery.
//
// Thread-safety: this type is `@MainActor` because `NSApplication`
// state is main-thread-only. Callers update the flags from the main
// thread; subscribers running elsewhere should hop before calling it.

import AppKit
import Foundation

/// Pure policy decision so we can unit-test it without an `NSApp`
/// instance.
enum ActivationPolicyDecision {
    static func desiredPolicy(
        showInDock: Bool,
        isMeetingRecording: Bool,
        isDictationRecording: Bool
    ) -> NSApplication.ActivationPolicy {
        if showInDock || isMeetingRecording || isDictationRecording {
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

    private var showInDock: Bool
    private var isMeetingRecording: Bool = false
    private var isDictationRecording: Bool = false

    /// Indirections so tests can capture policy changes without touching
    /// NSApp, and so the controller can correct AppKit/updater drift even
    /// when its cached desired policy has not changed.
    private let actualPolicy: (@MainActor () -> NSApplication.ActivationPolicy)?
    private let applyPolicy: @MainActor (NSApplication.ActivationPolicy) -> Void

    init(
        showInDock: Bool = DockVisibilityPreferences.isVisible(),
        applyPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Void = { policy in
            NSApp.setActivationPolicy(policy)
        },
        actualPolicy: (@MainActor () -> NSApplication.ActivationPolicy)? = nil
    ) {
        self.showInDock = showInDock
        self.currentPolicy = ActivationPolicyDecision.desiredPolicy(
            showInDock: showInDock,
            isMeetingRecording: false,
            isDictationRecording: false
        )
        self.actualPolicy = actualPolicy
        self.applyPolicy = applyPolicy
        applyPolicy(currentPolicy)
    }

    func setShowInDock(_ visible: Bool) {
        guard showInDock != visible else {
            applyIfDrifted(currentPolicy)
            return
        }
        showInDock = visible
        reconcile()
    }

    func setMeetingRecording(_ active: Bool) {
        guard isMeetingRecording != active else { return }
        isMeetingRecording = active
        reconcile()
    }

    func setDictationRecording(_ active: Bool) {
        guard isDictationRecording != active else { return }
        isDictationRecording = active
        reconcile()
    }

    /// Re-enforces the currently desired policy without changing user state.
    /// Sparkle relaunches, SwiftUI scene activation, and AppKit focus changes
    /// can leave the process `.regular` even though the cached user setting is
    /// hidden-Dock/accessory. This gives app lifecycle hooks a safe repair path.
    func reapplyCurrentPolicy() {
        applyIfDrifted(currentPolicy)
    }

    private func reconcile() {
        let desired = ActivationPolicyDecision.desiredPolicy(
            showInDock: showInDock,
            isMeetingRecording: isMeetingRecording,
            isDictationRecording: isDictationRecording
        )
        guard desired != currentPolicy else {
            applyIfDrifted(desired)
            return
        }
        currentPolicy = desired
        applyPolicy(desired)
    }

    private func applyIfDrifted(_ desired: NSApplication.ActivationPolicy) {
        guard let actualPolicy, desired != actualPolicy() else { return }
        applyPolicy(desired)
    }
}
