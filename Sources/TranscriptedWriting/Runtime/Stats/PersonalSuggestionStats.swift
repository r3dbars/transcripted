#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Count-only daily split of the "Personal suggestions (experimental)"
/// policy's outcome (`PersonalSuggestionSource`), so the menu can show
/// today's personal/agreed/base split without reading the diagnostics log.
/// Same daily-bucket-in-the-keyboard-suite convention as `TildeStats`/
/// `GhostStats` (a `"personal-suggestions.\(yyyy-MM-dd)"` key holding a
/// `[String: Int]` dict) — three integers per local calendar day, never any
/// suggestion text. `GhostBrainServerHost` runs in this app's own process
/// (not the keyboard extension), so, unlike `GhostStats`, this writes
/// directly rather than batching: completion requests are already rare
/// enough (one per accepted pause, not per keystroke) that a synchronous
/// `UserDefaults` write per served suggestion is cheap.
enum PersonalSuggestionStats {
    private static let lock = NSLock()

    static func record(source: PersonalSuggestionSource, now: Date = Date()) {
        lock.withLock {
            let suite = UserDefaults(suiteName: TildeSettings.keyboardSuiteName) ?? .standard
            let key = dayKey(for: now)
            var counts = suite.dictionary(forKey: key) as? [String: Int] ?? [:]
            counts[source.rawValue, default: 0] += 1
            suite.set(counts, forKey: key)
        }
    }

    static func todayCounts(now: Date = Date()) -> [String: Int] {
        let suite = UserDefaults(suiteName: TildeSettings.keyboardSuiteName) ?? .standard
        return lock.withLock {
            suite.dictionary(forKey: dayKey(for: now)) as? [String: Int] ?? [:]
        }
    }

    static func dayKey(
        for date: Date,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "personal-suggestions.%04d-%02d-%02d", year, month, day)
    }
}
