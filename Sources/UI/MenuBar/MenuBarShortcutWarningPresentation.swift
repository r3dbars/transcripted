// MenuBarShortcutWarningPresentation.swift
// Foundation-pure copy and action for the menu bar header's shortcut warning,
// so the warning says what to do and clicking it opens the right place.

import Foundation

struct MenuBarShortcutWarningPresentation: Equatable {
    enum Action: Equatable {
        case openAccessibilitySettings
    }

    let text: String
    let action: Action?

    /// `hotkeyError` is the capture engine's single current warning. Known
    /// warnings are matched by equality against the exact strings the engine
    /// produces; any other text still shows, just without an action.
    ///
    /// The macOS Fn key conflict stays out of the menu: shortcuts still work,
    /// and Settings > Shortcuts already explains it with a button to fix it.
    static func resolve(
        hotkeyError: String?,
        accessibilityErrorMessage: String,
        functionKeyConflictWarning: String?
    ) -> MenuBarShortcutWarningPresentation? {
        guard let hotkeyError, !hotkeyError.isEmpty else { return nil }
        if hotkeyError == accessibilityErrorMessage {
            return MenuBarShortcutWarningPresentation(
                text: "Shortcuts need Accessibility access. Click to turn it on.",
                action: .openAccessibilitySettings
            )
        }
        if let functionKeyConflictWarning, hotkeyError == functionKeyConflictWarning {
            return nil
        }
        return MenuBarShortcutWarningPresentation(text: hotkeyError, action: nil)
    }
}
