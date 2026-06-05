import Foundation

enum LiveMeetingCodexPreferences {
    static let enabledKey = "liveMeetingCodexModeEnabled"
    static let codexThreadIDKey = "liveMeetingCodexThreadID"
    static let defaultEnabled = false

    static func isEnabled(userDefaults: UserDefaults = .standard) -> Bool {
        userDefaults.bool(forKey: enabledKey)
    }

    static func setEnabled(_ enabled: Bool, userDefaults: UserDefaults = .standard) {
        userDefaults.set(enabled, forKey: enabledKey)
    }

    static func codexThreadID(userDefaults: UserDefaults = .standard) -> String? {
        normalizedCodexThreadID(userDefaults.string(forKey: codexThreadIDKey))
    }

    static func setCodexThreadID(_ threadID: String?, userDefaults: UserDefaults = .standard) {
        if let normalized = normalizedCodexThreadID(threadID) {
            userDefaults.set(normalized, forKey: codexThreadIDKey)
        } else {
            userDefaults.removeObject(forKey: codexThreadIDKey)
        }
    }

    static func normalizedCodexThreadID(_ rawValue: String?) -> String? {
        guard let rawValue else { return nil }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let url = URL(string: trimmed),
           url.scheme == "codex",
           url.host == "threads" {
            let candidate = url.path
                .split(separator: "/")
                .last
                .map(String.init)
            return normalizedCodexThreadID(candidate)
        }

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let separators = allowed.inverted
        let candidates = trimmed
            .components(separatedBy: separators)
            .filter { $0.count >= 16 }

        return candidates.first
    }
}
