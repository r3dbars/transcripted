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

enum DictationAutoSendBlockReason: String, Equatable {
    case none
    case notEvaluated = "not_evaluated"
    case featureOff = "feature_off"
    case emptyText = "empty_text"
    case durationTooShort = "duration_too_short"
    case sourceAppUnknown = "source_app_unknown"
    case appNotAllowed = "app_not_allowed"
    case accessibilityMissing = "accessibility_missing"
    case eventCreationFailed = "event_creation_failed"
    case targetChanged = "target_changed"
    case pasteNotConfirmed = "paste_not_confirmed"
    case pasteConfirmationUnavailable = "paste_confirmation_unavailable"
    case pasteFailed = "paste_failed"
    case cancelled
}

struct DictationAutoSendRequestDecision: Equatable {
    let expected: Bool
    let key: DictationAutoSendKey
    let blockReason: DictationAutoSendBlockReason

    static let notEvaluated = DictationAutoSendRequestDecision(
        expected: false,
        key: .enter,
        blockReason: .notEvaluated
    )
}

enum DictationAutoSendPreferences {
    private static let enabledKey = "dictationAutoEnterEnabled"
    private static let keyKey = "dictationAutoEnterKey"
    private static let allowedBundleIDsKey = "dictationAutoEnterAllowedBundleIDs"

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

    static func allowedBundleIDs(userDefaults: UserDefaults = .standard) -> Set<String> {
        let rawValues = userDefaults.stringArray(forKey: allowedBundleIDsKey) ?? []
        return Set(rawValues.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
    }

    static func setAllowedBundleIDs(_ bundleIDs: Set<String>, userDefaults: UserDefaults = .standard) {
        let normalized = bundleIDs
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        userDefaults.set(normalized, forKey: allowedBundleIDsKey)
    }
}

enum DictationAutoSendPolicy {
    static func requestDecision(
        isEnabled: Bool,
        key: DictationAutoSendKey,
        text: String,
        duration: TimeInterval,
        sourceBundleID: String?,
        allowedBundleIDs: Set<String>
    ) -> DictationAutoSendRequestDecision {
        let blockReason: DictationAutoSendBlockReason
        if !isEnabled {
            blockReason = .featureOff
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockReason = .emptyText
        } else if duration < TranscriptedConstants.dictationAutoEnterMinimumDuration {
            blockReason = .durationTooShort
        } else if sourceBundleID == nil {
            blockReason = .sourceAppUnknown
        } else if let sourceBundleID, !allowedBundleIDs.contains(sourceBundleID) {
            blockReason = .appNotAllowed
        } else {
            blockReason = .none
        }

        return DictationAutoSendRequestDecision(
            expected: blockReason == .none,
            key: key,
            blockReason: blockReason
        )
    }

    static func isRequested(
        isEnabled: Bool,
        text: String,
        duration: TimeInterval,
        sourceBundleID: String?,
        allowedBundleIDs: Set<String>
    ) -> Bool {
        requestDecision(
            isEnabled: isEnabled,
            key: .enter,
            text: text,
            duration: duration,
            sourceBundleID: sourceBundleID,
            allowedBundleIDs: allowedBundleIDs
        ).expected
    }

    static func shouldSend(
        isEnabled: Bool,
        pasteOutcome: TextPasteOutcome,
        text: String,
        duration: TimeInterval,
        sourceBundleID: String?,
        allowedBundleIDs: Set<String>
    ) -> Bool {
        guard pasteOutcome.allowsAutoSend else { return false }
        return isRequested(
            isEnabled: isEnabled,
            text: text,
            duration: duration,
            sourceBundleID: sourceBundleID,
            allowedBundleIDs: allowedBundleIDs
        )
    }
}

extension TextPasteOutcome {
    var allowsAutoSend: Bool {
        switch self {
        case .pasted:
            return true
        case .copied(_, reason: .pasteConfirmationUnavailableAutoSendEligible):
            return true
        case .copied, .failed:
            return false
        }
    }

    var requiresClipboardReadinessBeforeAutoSend: Bool {
        switch self {
        case .pasted, .copied(_, reason: .pasteConfirmationUnavailableAutoSendEligible):
            return true
        case .copied, .failed:
            return false
        }
    }

    var autoSendBlockReason: DictationAutoSendBlockReason? {
        switch self {
        case .pasted, .copied(_, reason: .pasteConfirmationUnavailableAutoSendEligible):
            return nil
        case .copied(_, reason: .accessibilityMissing):
            return .accessibilityMissing
        case .copied(_, reason: .pasteEventCreationFailed):
            return .eventCreationFailed
        case .copied(_, reason: .focusChanged):
            return .targetChanged
        case .copied(_, reason: .pasteNotConfirmed):
            return .pasteNotConfirmed
        case .copied(_, reason: .pasteConfirmationUnavailable):
            return .pasteConfirmationUnavailable
        case .failed:
            return .pasteFailed
        }
    }
}

enum DictationAutoSendFailure: Equatable {
    case accessibilityMissing
    case targetChanged
    case eventCreationFailed

    var message: String {
        switch self {
        case .accessibilityMissing:
            return "Accessibility is off, so Transcripted could not send automatically."
        case .targetChanged:
            return "Target app changed before Auto Enter, so Transcripted did not press Return."
        case .eventCreationFailed:
            return "Transcripted could not create the auto-send key event."
        }
    }

    var blockReason: DictationAutoSendBlockReason {
        switch self {
        case .accessibilityMissing:
            return .accessibilityMissing
        case .targetChanged:
            return .targetChanged
        case .eventCreationFailed:
            return .eventCreationFailed
        }
    }
}

enum DictationAutoSendOutcome: Equatable {
    case disabled
    case sent(DictationAutoSendKey)
    case failed(DictationAutoSendFailure)

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

    var confirmationTitle: String? {
        switch self {
        case .sent(let key):
            return "Pasted + \(key.title)"
        case .disabled, .failed:
            return nil
        }
    }
}

struct DictationAutoSendTelemetry: Equatable {
    let expected: Bool
    let key: DictationAutoSendKey
    let blockReason: DictationAutoSendBlockReason

    static func snapshot(
        request: DictationAutoSendRequestDecision,
        pasteOutcome: TextPasteOutcome,
        sendOutcome: DictationAutoSendOutcome
    ) -> DictationAutoSendTelemetry {
        let blockReason: DictationAutoSendBlockReason
        if !request.expected {
            blockReason = request.blockReason
        } else if let pasteBlockReason = pasteOutcome.autoSendBlockReason {
            blockReason = pasteBlockReason
        } else {
            switch sendOutcome {
            case .disabled:
                blockReason = .cancelled
            case .sent:
                blockReason = .none
            case .failed(let failure):
                blockReason = failure.blockReason
            }
        }

        return DictationAutoSendTelemetry(
            expected: request.expected,
            key: request.key,
            blockReason: blockReason
        )
    }

    var analyticsProperties: [String: String] {
        [
            "auto_send_expected": "\(expected)",
            "auto_send_key": key.diagnosticName,
            "auto_send_block_reason": blockReason.rawValue,
        ]
    }
}

@MainActor
final class DictationAutoSender {
    func send(_ key: DictationAutoSendKey, target: DictationPasteTarget? = nil) -> DictationAutoSendOutcome {
        guard AXIsProcessTrusted() else {
            return .failed(.accessibilityMissing)
        }

        guard target?.matchesCurrentFrontmostApp() != false else {
            return .failed(.targetChanged)
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kVK_Return), keyDown: false) else {
            return .failed(.eventCreationFailed)
        }

        keyDown.flags = key.eventFlags
        keyDown.post(tap: .cghidEventTap)

        keyUp.flags = key.eventFlags
        keyUp.post(tap: .cghidEventTap)

        return .sent(key)
    }
}
