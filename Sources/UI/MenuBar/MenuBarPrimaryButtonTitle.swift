// MenuBarPrimaryButtonTitle.swift
// Foundation-pure short titles for the menu bar's two side-by-side buttons.

import Foundation

/// The Record and Dictate buttons share one row, so each shows a short
/// title. The full title (for example "Record Meeting") stays the button's
/// accessibility label and the launch smoke's snapshot title.
enum MenuBarPrimaryButtonTitle {
    static func short(for title: String) -> String {
        switch title {
        case "Record Meeting":
            return "Record"
        case "Stop Meeting", "Stop Dictation":
            return "Stop"
        case "Saving Meeting…":
            return "Saving…"
        case "Start Dictation":
            return "Dictate"
        default:
            return title
        }
    }
}
