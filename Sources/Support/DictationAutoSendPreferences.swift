import ApplicationServices
import Carbon
import Foundation

enum DictationAutoSendKey: String, CaseIterable, Identifiable {
    case enter
    case commandEnter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .enter:
            return "Enter"
        case .commandEnter:
            return "Cmd + Enter"
        }
    }

    var diagnosticName: String {
        switch self {
        case .enter:
            return "enter"
        case .commandEnter:
            return "command_enter"
        }
    }

    var eventFlags: CGEventFlags {
        switch self {
        case .enter:
            return []
        case .commandEnter:
            return .maskCommand
        }
    }
}

enum DictationAutoSendPreferences {
    private static let enabledKey = "dictationAutoEnterEnabled"
    private static let keyKey = "dictationAutoEnterKey"

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    static func sendKey(userDefaults: UserDefaults = .standard) -> DictationAutoSendKey {
        guard let rawValue = userDefaults.string(forKey: keyKey),
              let key = DictationAutoSendKey(rawValue: rawValue) else {
            return .enter
        }

        return key
    }

    static func setSendKey(_ key: DictationAutoSendKey, userDefaults: UserDefaults = .standard) {
        userDefaults.set(key.rawValue, forKey: keyKey)
    }
}

enum DictationAutoSendPolicy {
    static func shouldSend(
        isEnabled: Bool,
        delivery: DictationDelivery,
        text: String,
        duration: TimeInterval
    ) -> Bool {
        guard isEnabled else { return false }
        guard delivery == .pasted else { return false }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard duration >= TranscriptedConstants.dictationAutoEnterMinimumDuration else { return false }
        return true
    }
}

enum DictationAutoSendOutcome: Equatable {
    case disabled
    case sent(DictationAutoSendKey)
    case failed(String)

    var diagnosticName: String {
        switch self {
        case .disabled:
            return "disabled"
        case .sent(let key):
            return "sent_\(key.diagnosticName)"
        case .failed:
            return "failed"
        }
    }
}

@MainActor
final class DictationAutoSender {
    func send(_ key: DictationAutoSendKey) -> DictationAutoSendOutcome {
        guard AXIsProcessTrusted() else {
            return .failed("Accessibility is off, so Transcripted could not send automatically.")
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else {
            return .failed("Transcripted could not create the auto-send key event.")
        }

        keyDown.flags = key.eventFlags
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = key.eventFlags
        keyUp.post(tap: .cghidEventTap)

        return .sent(key)
    }
}
