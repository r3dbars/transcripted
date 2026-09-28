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

    static func todayWordsAccepted() -> Int {
        dayDict(todayKey)["wordsAccepted"] ?? 0
    }

    static func todaySuggestionsShown() -> Int {
        dayDict(todayKey)["suggestionsShown"] ?? 0
    }

    static func todaySuggestionsAccepted() -> Int {
        dayDict(todayKey)["suggestionsAccepted"] ?? 0
    }

    static func lifetimeWordsAccepted() -> Int {
        guard let suite = UserDefaults(suiteName: TildeSettings.keyboardSuiteName) else { return 0 }
        return sumWordsAccepted(in: suite.dictionaryRepresentation())
    }

    static func lifetimeSuggestionsShown() -> Int {
        guard let suite = UserDefaults(suiteName: TildeSettings.keyboardSuiteName) else { return 0 }
        return sumSuggestionsShown(in: suite.dictionaryRepresentation())
    }

    static func lifetimeSuggestionsAccepted() -> Int {
        guard let suite = UserDefaults(suiteName: TildeSettings.keyboardSuiteName) else { return 0 }
        return sumSuggestionsAccepted(in: suite.dictionaryRepresentation())
    }

    static func sumWordsAccepted(in values: [String: Any]) -> Int {
        sum("wordsAccepted", in: values)
    }

    static func sumSuggestionsShown(in values: [String: Any]) -> Int {
        sum("suggestionsShown", in: values)
    }

    static func sumSuggestionsAccepted(in values: [String: Any]) -> Int {
        sum("suggestionsAccepted", in: values)
    }

    /// Whole-percent acceptance rate. Zero when nothing has been shown yet,
    /// so callers should gate display on `shown > 0` rather than trusting 0%.
    static func acceptanceRate(accepted: Int, shown: Int) -> Int {
        guard shown > 0 else { return 0 }
        return Int((Double(accepted) / Double(shown) * 100).rounded())
    }

    private static func sum(_ key: String, in values: [String: Any]) -> Int {
        values.reduce(into: 0) { total, entry in
            guard entry.key.hasPrefix("stats."),
                  let counters = entry.value as? [String: Int]
            else { return }
            total += counters[key] ?? 0
        }
    }
}
