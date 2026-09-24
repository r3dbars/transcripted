enum DictationCancelHintPolicy {
    static func shortcutHint(
        dictationShortcutsEnabled: Bool,
        pushToTalkDisplay: String,
        handsFreeDisplay: String
    ) -> String {
        guard dictationShortcutsEnabled else { return "" }
        return "\(pushToTalkDisplay) / \(handsFreeDisplay)"
    }

    static func cancelHintText(for shortcutHint: String) -> String {
        guard !shortcutHint.isEmpty else { return "" }
        return "Cancel: \(shortcutHint)"
    }
}

/// Esc is a global key: people press it to close an autocomplete or leave an
/// edit box while dictating hands-free. A single stray press used to throw
/// away the whole take with no sound and no undo. So once real audio has been
/// captured for a while, the first Esc only asks, and a second Esc inside the
/// confirm window discards.
enum DictationEscapeCancelPolicy {
    enum Decision: Equatable {
        case cancel
        case askToConfirm
    }

    /// Takes shorter than this cancel on the first Esc; there is little to lose.
    static let instantCancelLimitSeconds: Double = 5
    /// A second Esc inside this window confirms the discard.
    static let confirmWindowSeconds: Double = 3
    static let confirmNotice = "Press Esc again to discard"

    /// `capturedSeconds` is nil before the mic has started recording.
    /// `secondsSinceFirstPress` is nil when no earlier Esc is waiting on a confirm.
    static func decision(capturedSeconds: Double?, secondsSinceFirstPress: Double?) -> Decision {
        guard let capturedSeconds, capturedSeconds >= instantCancelLimitSeconds else { return .cancel }
        if let secondsSinceFirstPress, secondsSinceFirstPress >= 0, secondsSinceFirstPress <= confirmWindowSeconds {
            return .cancel
        }
        return .askToConfirm
    }
}
