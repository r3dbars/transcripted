// MenuBarShortcutLabel.swift
// Foundation-pure shortcut text for the menu bar's half-width buttons.

import Foundation

/// A button shows its shortcut beside the title when there's room. Dictation
/// can have two triggers ("Fn / Right ⌥": push-to-talk, then hands-free), and
/// the pair doesn't fit a half-width button, so the button tries the full
/// text first and then just the first key.
enum MenuBarShortcutLabel {
    static func candidates(for shortcut: String) -> [String] {
        let full = shortcut.trimmingCharacters(in: .whitespaces)
        guard !full.isEmpty else { return [] }
        let first = full.components(separatedBy: " / ").first?
            .trimmingCharacters(in: .whitespaces) ?? full
        return first.isEmpty || first == full ? [full] : [full, first]
    }
}
