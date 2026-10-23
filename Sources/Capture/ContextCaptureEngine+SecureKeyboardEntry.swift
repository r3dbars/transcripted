// ContextCaptureEngine+SecureKeyboardEntry.swift
// Watches Secure Keyboard Entry while dictation is bound to a non-modifier
// key. The tap cannot see F8 while another app holds it, so this polls and
// also checks on app activation and flagsChanged. Modifier bindings stay
// quiet: Right Option still arrives as flagsChanged.

import AppKit
import Foundation

extension ContextCaptureEngine {
    func startSecureKeyboardEntryWatch() {
        stopSecureKeyboardEntryWatch()
        guard !AutomatedLaunchEnvironment.isActive() else { return }

        let monitor = SecureKeyboardEntryMonitor(
            source: LiveSecureEventInputSource(),
            namer: LiveSecureEventInputProcessNamer()
        )
        monitor.onNoticeChange = { [weak self] text in
            self?.secureKeyboardEntryNotice = text
        }
        monitor.onLog = { event in
            EventReporter.shared.capture(
                level: event.isEnabled ? .warning : .info,
                engine: "capture",
                event: "secure_input_state_changed",
                message: event.isEnabled ? "Secure Keyboard Entry on" : "Secure Keyboard Entry off",
                context: [
                    "enabled": event.isEnabled ? "on" : "off",
                    "pid": event.ownerProcessID.map(String.init) ?? "none",
                    "owner": event.ownerDisplayName ?? "unknown",
                ]
            )
        }
        secureKeyboardEntryMonitor = monitor

        secureKeyboardEntryActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.evaluateSecureKeyboardEntry()
            }
        }

        secureKeyboardEntryFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.noteSecureKeyboardEntryFlagsChanged()
            }
        }

        evaluateSecureKeyboardEntry()
    }

    func stopSecureKeyboardEntryWatch() {
        secureKeyboardEntryPollTask?.cancel()
        secureKeyboardEntryPollTask = nil
        if let observer = secureKeyboardEntryActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            secureKeyboardEntryActivationObserver = nil
        }
        if let flagsMonitor = secureKeyboardEntryFlagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            secureKeyboardEntryFlagsMonitor = nil
        }
        secureKeyboardEntryFlagsCheckPending = false
        secureKeyboardEntryMonitor?.reset()
        secureKeyboardEntryMonitor = nil
        if secureKeyboardEntryNotice != nil {
            secureKeyboardEntryNotice = nil
        }
    }

    func evaluateSecureKeyboardEntry(refreshOwner: Bool = false) {
        // A flagsChanged or app-activation hop can already be queued when
        // stopSecureKeyboardEntryWatch runs. Those must not revive the poll.
        guard SecureKeyboardEntryWarningPolicy.shouldAcceptWatchCallback(
            isWatching: secureKeyboardEntryMonitor != nil
        ) else { return }

        let binding = PhysicalDictationTriggerPreferences.pushToTalkBinding()
        let usesModifier = PhysicalDictationTriggerPreferences.isModifierKey(binding.keyCode)
        let shortcutsEnabled = HotkeyPreferences.dictationShortcutsEnabled()
        secureKeyboardEntryMonitor?.check(
            dictationUsesModifierKey: usesModifier,
            dictationShortcutsEnabled: shortcutsEnabled,
            dictationKeyDisplay: PhysicalDictationTriggerPreferences.displayString(for: binding),
            refreshOwner: refreshOwner
        )
        updateSecureKeyboardEntryPoll(
            dictationUsesModifierKey: usesModifier,
            dictationShortcutsEnabled: shortcutsEnabled
        )
    }

    private func noteSecureKeyboardEntryFlagsChanged() {
        guard SecureKeyboardEntryWarningPolicy.shouldAcceptWatchCallback(
            isWatching: secureKeyboardEntryMonitor != nil
        ) else { return }
        guard !secureKeyboardEntryFlagsCheckPending else { return }
        secureKeyboardEntryFlagsCheckPending = true
        Task { @MainActor [weak self] in
            self?.secureKeyboardEntryFlagsCheckPending = false
            self?.evaluateSecureKeyboardEntry()
        }
    }

    private func updateSecureKeyboardEntryPoll(
        dictationUsesModifierKey: Bool,
        dictationShortcutsEnabled: Bool
    ) {
        let shouldPoll = SecureKeyboardEntryWarningPolicy.shouldStartPoll(
            isWatching: secureKeyboardEntryMonitor != nil,
            dictationUsesModifierKey: dictationUsesModifierKey,
            dictationShortcutsEnabled: dictationShortcutsEnabled
        )
        if !shouldPoll {
            secureKeyboardEntryPollTask?.cancel()
            secureKeyboardEntryPollTask = nil
            return
        }
        guard secureKeyboardEntryPollTask == nil else { return }
        secureKeyboardEntryPollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(
                    nanoseconds: SecureKeyboardEntryWarningPolicy.pollIntervalNanoseconds
                )
                guard !Task.isCancelled else { return }
                self?.evaluateSecureKeyboardEntry(refreshOwner: true)
            }
        }
    }
}
