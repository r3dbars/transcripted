// SecureKeyboardEntryMonitor.swift
// Holds watch state and talks to the Secure Event Input probe / process namer
// through protocols so tests can drive it with fakes. Polling, app-activation,
// and flagsChanged stay in ContextCaptureEngine so this type stays UI-free.

import Foundation

@MainActor
final class SecureKeyboardEntryMonitor {
    private let source: SecureEventInputReading
    private let namer: SecureEventInputProcessNaming
    private let selfProcessID: Int32
    private var state = SecureEventInputWatchState.idle

    var onNoticeChange: ((String?) -> Void)?
    var onLog: ((SecureKeyboardEntryLogEvent) -> Void)?

    init(
        source: SecureEventInputReading,
        namer: SecureEventInputProcessNaming,
        selfProcessID: Int32 = ProcessInfo.processInfo.processIdentifier
    ) {
        self.source = source
        self.namer = namer
        self.selfProcessID = selfProcessID
    }

    var visibleNotice: String? { state.visibleNotice }

    func check(
        dictationUsesModifierKey: Bool,
        dictationShortcutsEnabled: Bool,
        dictationKeyDisplay: String,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) {
        let snapshot: SecureEventInputSnapshot
        if SecureKeyboardEntryWarningPolicy.shouldPoll(
            dictationUsesModifierKey: dictationUsesModifierKey,
            dictationShortcutsEnabled: dictationShortcutsEnabled
        ) {
            snapshot = makeSnapshot()
        } else {
            snapshot = .inactive
        }

        let (next, decision) = SecureKeyboardEntryWarningPolicy.evaluate(
            previous: state,
            snapshot: snapshot,
            dictationUsesModifierKey: dictationUsesModifierKey,
            dictationShortcutsEnabled: dictationShortcutsEnabled,
            dictationKeyDisplay: dictationKeyDisplay,
            selfProcessID: selfProcessID,
            now: now
        )
        state = next
        apply(decision)
    }

    func reset() {
        if state.visibleNotice != nil {
            onNoticeChange?(nil)
        }
        state = .idle
    }

    private func makeSnapshot() -> SecureEventInputSnapshot {
        guard source.isEnabled() else { return .inactive }
        let pid = source.ownerProcessID()
        let name = pid.flatMap { processID in
            SecureKeyboardEntryWarningPolicy.resolveOwnerDisplayName(
                processID: processID,
                runningApplicationName: namer.runningApplicationDisplayName(forProcessID: processID),
                processName: namer.processName(forProcessID: processID)
            )
        }
        return SecureEventInputSnapshot(
            isEnabled: true,
            ownerProcessID: pid,
            ownerDisplayName: name
        )
    }

    private func apply(_ decision: SecureKeyboardEntryDecision) {
        switch decision.notice {
        case .unchanged:
            break
        case .show(let text):
            onNoticeChange?(text)
        case .clear:
            onNoticeChange?(nil)
        }
        if let log = decision.log {
            onLog?(log)
        }
    }
}
