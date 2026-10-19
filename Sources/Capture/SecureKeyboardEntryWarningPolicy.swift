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
    var lastLogKey: String?
    var lastLogUptime: TimeInterval

    static let idle = SecureEventInputWatchState(
        visibleNotice: nil,
        noticedOwnerKey: nil,
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
    /// in the requested 2–3 s window. Stub is 0 so the spec fails until the
    /// implementation fills it in.
    static let pollIntervalNanoseconds: UInt64 = 0

    static let logInterval: TimeInterval = 2

    static let unknownOwnerDisplayName = "Another app"

    static func shouldPoll(
        dictationUsesModifierKey: Bool,
        dictationShortcutsEnabled: Bool
    ) -> Bool {
        _ = dictationUsesModifierKey
        _ = dictationShortcutsEnabled
        return false
    }

    static func noticeText(ownerDisplayName: String?, dictationKeyDisplay: String) -> String {
        _ = ownerDisplayName
        _ = dictationKeyDisplay
        return ""
    }

    static func resolveOwnerDisplayName(
        processID: Int32,
        runningApplicationName: String?,
        processName: String?
    ) -> String? {
        _ = processID
        _ = runningApplicationName
        _ = processName
        return nil
    }

    static func ownerProcessID(fromConsoleUsers users: [[String: Any]]) -> Int32? {
        _ = users
        return nil
    }

    static func ownerKey(processID: Int32?, displayName: String?) -> String {
        _ = processID
        _ = displayName
        return ""
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
        _ = snapshot
        _ = dictationUsesModifierKey
        _ = dictationShortcutsEnabled
        _ = dictationKeyDisplay
        _ = selfProcessID
        _ = now
        _ = logInterval
        return (previous, SecureKeyboardEntryDecision(notice: .unchanged, log: nil))
    }
}
