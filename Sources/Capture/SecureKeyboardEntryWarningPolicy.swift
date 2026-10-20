// SecureKeyboardEntryWarningPolicy.swift
// Pure decisions for the Secure Keyboard Entry warning: when to show, clear,
// and locally log. IOKit / Carbon / AppKit stay behind the protocols in
// SecureEventInputSource.swift so this file can be fast-tested with fakes.

import Foundation

struct SecureEventInputSnapshot: Equatable {
    var isEnabled: Bool
    var ownerProcessID: Int32?
    var ownerDisplayName: String?

    static let inactive = SecureEventInputSnapshot(
        isEnabled: false,
        ownerProcessID: nil,
        ownerDisplayName: nil
    )
}

enum SecureKeyboardEntryNoticeEffect: Equatable {
    case unchanged
    case show(String)
    case clear
}

struct SecureKeyboardEntryLogEvent: Equatable {
    var isEnabled: Bool
    var ownerDisplayName: String?
    var ownerProcessID: Int32?
}

struct SecureKeyboardEntryDecision: Equatable {
    var notice: SecureKeyboardEntryNoticeEffect
    var log: SecureKeyboardEntryLogEvent?
}

struct SecureEventInputWatchState: Equatable {
    var visibleNotice: String?
    var noticedOwnerKey: String?
    var lastOwnerProcessID: Int32?
    var lastOwnerDisplayName: String?
    var lastLogKey: String?
    var lastLogUptime: TimeInterval

    static let idle = SecureEventInputWatchState(
        visibleNotice: nil,
        noticedOwnerKey: nil,
        lastOwnerProcessID: nil,
        lastOwnerDisplayName: nil,
        lastLogKey: nil,
        lastLogUptime: -.infinity
    )
}

enum SecureEventInputRegistryKeys {
    static let consoleUsers = "IOConsoleUsers"
    static let secureInputPID = "kCGSSessionSecureInputPID"
    static let onConsole = "kCGSSessionOnConsoleKey"
}

enum SecureKeyboardEntryWarningPolicy {
    /// Cheap poll while dictation is bound to a non-modifier key. 2.5 s sits
    /// in the requested 2–3 s window.
    static let pollIntervalNanoseconds: UInt64 = 2_500_000_000

    /// Local `secure_input_state_changed` at most once per poll. Shorter than
    /// the poll would let a queued flagsChanged log on the same hold.
    static let logInterval: TimeInterval = Double(pollIntervalNanoseconds) / 1_000_000_000.0

    static let unknownOwnerDisplayName = "Another app"

    static func shouldPoll(
        dictationUsesModifierKey: Bool,
        dictationShortcutsEnabled: Bool
    ) -> Bool {
        dictationShortcutsEnabled && !dictationUsesModifierKey
    }

    /// App-activation and flagsChanged hops already queued at stop must not
    /// revive the 2.5 s poll. The live watch still polls for F-key bindings.
    static func shouldStartPoll(
        isWatching: Bool,
        dictationUsesModifierKey: Bool,
        dictationShortcutsEnabled: Bool
    ) -> Bool {
        isWatching && shouldPoll(
            dictationUsesModifierKey: dictationUsesModifierKey,
            dictationShortcutsEnabled: dictationShortcutsEnabled
        )
    }

    /// A deferred flagsChanged or activation is a no-op once the watch stopped.
    static func shouldAcceptWatchCallback(isWatching: Bool) -> Bool {
        isWatching
    }

    static func noticeText(ownerDisplayName: String?, dictationKeyDisplay: String) -> String {
        let owner = cleaned(ownerDisplayName) ?? unknownOwnerDisplayName
        let key = cleaned(dictationKeyDisplay)
        let keyPhrase = key.map { "\($0) dictation" } ?? "Dictation"
        return "Shortcuts are blocked until \(owner) releases Secure Keyboard Entry. \(keyPhrase) won't work."
    }

    static func resolveOwnerDisplayName(
        processID: Int32,
        runningApplicationName: String?,
        processName: String?
    ) -> String? {
        _ = processID
        return cleaned(runningApplicationName) ?? cleaned(processName)
    }

    static func ownerProcessID(fromConsoleUsers users: [[String: Any]]) -> Int32? {
        for user in users {
            if boolValue(user[SecureEventInputRegistryKeys.onConsole]) == false {
                continue
            }
            if let pid = processID(from: user[SecureEventInputRegistryKeys.secureInputPID]) {
                return pid
            }
        }
        return nil
    }

    static func ownerKey(processID: Int32?, displayName: String?) -> String {
        if let processID, processID > 0 {
            return "pid:\(processID)"
        }
        if let displayName = cleaned(displayName) {
            return "name:\(displayName)"
        }
        return "unknown"
    }

    static func evaluate(
        previous: SecureEventInputWatchState,
        snapshot: SecureEventInputSnapshot,
        dictationUsesModifierKey: Bool,
        dictationShortcutsEnabled: Bool,
        dictationKeyDisplay: String,
        selfProcessID: Int32,
        now: TimeInterval,
        logInterval: TimeInterval = logInterval
    ) -> (SecureEventInputWatchState, SecureKeyboardEntryDecision) {
        if !dictationShortcutsEnabled || dictationUsesModifierKey {
            return clearNotice(from: previous, logRelease: false)
        }

        let heldBySelf = snapshot.isEnabled
            && snapshot.ownerProcessID != nil
            && snapshot.ownerProcessID == selfProcessID
        let blocking = snapshot.isEnabled && !heldBySelf

        if !blocking {
            return clearNotice(from: previous, logRelease: previous.visibleNotice != nil, now: now, logInterval: logInterval)
        }

        let key = ownerKey(processID: snapshot.ownerProcessID, displayName: snapshot.ownerDisplayName)
        let text = noticeText(
            ownerDisplayName: snapshot.ownerDisplayName,
            dictationKeyDisplay: dictationKeyDisplay
        )

        if previous.visibleNotice != nil, previous.noticedOwnerKey == key {
            if previous.visibleNotice == text {
                return (previous, SecureKeyboardEntryDecision(notice: .unchanged, log: nil))
            }
            var next = previous
            next.visibleNotice = text
            next.lastOwnerProcessID = snapshot.ownerProcessID
            next.lastOwnerDisplayName = snapshot.ownerDisplayName
            return (next, SecureKeyboardEntryDecision(notice: .show(text), log: nil))
        }

        let logEvent = SecureKeyboardEntryLogEvent(
            isEnabled: true,
            ownerDisplayName: snapshot.ownerDisplayName,
            ownerProcessID: snapshot.ownerProcessID
        )
        let log = rateLimitedLog(from: previous, event: logEvent, now: now, logInterval: logInterval)
        var next = previous
        next.visibleNotice = text
        next.noticedOwnerKey = key
        next.lastOwnerProcessID = snapshot.ownerProcessID
        next.lastOwnerDisplayName = snapshot.ownerDisplayName
        if log != nil {
            next.lastLogKey = logKey(for: logEvent)
            next.lastLogUptime = now
        }
        return (next, SecureKeyboardEntryDecision(notice: .show(text), log: log))
    }

    private static func clearNotice(
        from previous: SecureEventInputWatchState,
        logRelease: Bool,
        now: TimeInterval = 0,
        logInterval: TimeInterval = logInterval
    ) -> (SecureEventInputWatchState, SecureKeyboardEntryDecision) {
        guard previous.visibleNotice != nil else {
            return (previous, SecureKeyboardEntryDecision(notice: .unchanged, log: nil))
        }

        var next = previous
        next.visibleNotice = nil
        var log: SecureKeyboardEntryLogEvent?
        if logRelease {
            let event = SecureKeyboardEntryLogEvent(
                isEnabled: false,
                ownerDisplayName: previous.lastOwnerDisplayName,
                ownerProcessID: previous.lastOwnerProcessID
            )
            log = rateLimitedLog(from: previous, event: event, now: now, logInterval: logInterval)
            if log != nil {
                next.lastLogKey = logKey(for: event)
                next.lastLogUptime = now
            }
        }
        return (next, SecureKeyboardEntryDecision(notice: .clear, log: log))
    }

    private static func rateLimitedLog(
        from previous: SecureEventInputWatchState,
        event: SecureKeyboardEntryLogEvent,
        now: TimeInterval,
        logInterval: TimeInterval
    ) -> SecureKeyboardEntryLogEvent? {
        let key = logKey(for: event)
        if previous.lastLogKey == key, now - previous.lastLogUptime < logInterval {
            return nil
        }
        return event
    }

    private static func logKey(for event: SecureKeyboardEntryLogEvent) -> String {
        let enabled = event.isEnabled ? "on" : "off"
        let pid = event.ownerProcessID.map(String.init) ?? "none"
        let owner = event.ownerDisplayName ?? "unknown"
        return "\(enabled):\(pid):\(owner)"
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func processID(from value: Any?) -> Int32? {
        let number: Int32?
        if let value = value as? Int32 {
            number = value
        } else if let value = value as? Int {
            number = Int32(value)
        } else if let value = value as? UInt32, value <= UInt32(Int32.max) {
            number = Int32(value)
        } else if let value = value as? NSNumber {
            number = value.int32Value
        } else {
            number = nil
        }
        guard let number, number > 0 else { return nil }
        return number
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }
}
