// MenuBarShortcutWarningPresentation.swift
// Foundation-pure copy and action for the menu bar header's shortcut warning,
// so the warning says what to do and clicking it opens the right place.

import Foundation

struct MenuBarShortcutWarningPresentation: Equatable {
    enum Action: Equatable {
        case openAccessibilitySettings
        case openKeyboardSettings
    }

    let text: String
    let action: Action?

    /// `hotkeyError` is the capture engine's single current warning. The two
    /// known warnings are matched by equality against the exact strings the
    /// engine produces, so any other text still shows, just without an action.
    static func resolve(
        hotkeyError: String?,
        accessibilityErrorMessage: String,
        functionKeyConflictWarning: String?,
        functionKeySystemActionTitle: String
    ) -> MenuBarShortcutWarningPresentation? {
        guard let hotkeyError, !hotkeyError.isEmpty else { return nil }
        if hotkeyError == accessibilityErrorMessage {
            return MenuBarShortcutWarningPresentation(
                text: "Shortcuts need Accessibility access. Click to turn it on.",
                action: .openAccessibilitySettings
            )
        }
        if let functionKeyConflictWarning, hotkeyError == functionKeyConflictWarning {
            return MenuBarShortcutWarningPresentation(
                text: "macOS also uses Fn for \(functionKeySystemActionTitle). Click, then set Press Fn/Globe key to Do Nothing.",
                action: .openKeyboardSettings
            )
        }
        return MenuBarShortcutWarningPresentation(text: hotkeyError, action: nil)
    }
}
