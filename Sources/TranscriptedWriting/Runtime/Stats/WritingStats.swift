import Foundation

/// Reads the keyboard's aggregate-only daily counters. No typed text, prompts,
/// completions, app names, fields, or document identifiers cross this bridge.
enum TildeStats {
    private static func dayDict(_ key: String) -> [String: Int] {
        UserDefaults(suiteName: TildeSettings.keyboardSuiteName)?
            .dictionary(forKey: "stats.\(key)") as? [String: Int] ?? [:]
    }

    private static var todayKey: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    static func todaySuggestionsAccepted() -> Int {
        dayDict(todayKey)["suggestionsAccepted"] ?? 0
    }
}
