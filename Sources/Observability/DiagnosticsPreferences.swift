// DiagnosticsPreferences.swift
// User preference for optional anonymous beta diagnostics.

import Foundation

enum DiagnosticsPreferences {
    static let enabledKey = "transcripted.diagnostics.enabled"

    static var isEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: enabledKey) != nil else { return false }
        return defaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
    }
}
