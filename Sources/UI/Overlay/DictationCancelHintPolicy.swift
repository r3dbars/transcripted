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
