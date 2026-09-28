import Foundation

/// Count-only Writing analytics (docs/writing-plan.md, "Analytics" and
/// decision 7). Both events go through `AnalyticsReporter.track`, which sends
/// nothing while the user's anonymous-analytics toggle is off.
///
/// Nothing here sees writing. The daily totals come from the text-free
/// outcome ledger summary, and everything else is a setup choice. No app
/// names, no bundle IDs, no per-suggestion events.
///
/// Uses only Foundation, `AnalyticsReporter` and `TildeModelChoice`, so the
/// root fast tests compile it directly.
enum WritingAnalytics {
    /// Which apps Writing works in.
    enum AppScope: String, Equatable, Sendable {
        case all
        case picked
    }

    /// The setup choices both events report.
    struct Setup: Equatable, Sendable {
        let saveEnabled: Bool
        let autocompleteEnabled: Bool
        let appScope: AppScope
        let model: TildeModelChoice
    }

    /// One whole local day, read from `OutcomeLedgerSummary`.
    struct DailyCounts: Equatable, Sendable {
        let suggestionsShown: Int
        let suggestionsAccepted: Int
        /// The ledger counts accepted characters, not words.
        let acceptedCharacters: Int
    }

    /// App-suite key (`WritingController.appSuiteName`): the last local day,
    /// as `yyyy-MM-dd`, whose counts were handled.
    static let dailyCountsLastDayKey = "WritingDailyCountsLastDay"

    /// The typing-speed "standard word": five characters, spaces included.
    /// The ledger stores accepted characters only.
    static let charactersPerWord = 5

    // MARK: - Emitting

    /// Sends `writing_daily_counts` for yesterday, at most once. The day is
    /// claimed before the ledger is read, so a wake right after launch can't
    /// send it twice. A day with nothing shown or accepted is claimed and
    /// skipped. `countsForDay` runs off the main thread.
    static func emitDailyCountsIfDue(
        now: Date = Date(),
        calendar: Calendar = .current,
        defaults: UserDefaults,
        setup: Setup,
        countsForDay: @escaping @Sendable (DateInterval) -> DailyCounts
    ) {
        guard let day = claimPreviousDay(now: now, calendar: calendar, defaults: defaults) else { return }
        Task.detached(priority: .utility) {
            guard let properties = dailyCountsProperties(countsForDay(day), setup: setup) else { return }
            AnalyticsReporter.track("writing_daily_counts", properties: properties)
        }
    }

    /// The Writing tab calls this when setup finishes.
    static func trackSetupCompleted(_ setup: Setup) {
        AnalyticsReporter.track("writing_setup_completed", properties: setupProperties(setup))
    }

    // MARK: - Once a day

    /// The whole local day before the one `now` falls in. 23 or 25 hours
    /// long across a daylight-saving change.
    static func previousDay(before now: Date, calendar: Calendar) -> DateInterval? {
        let startOfToday = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -1, to: startOfToday),
              start < startOfToday else { return nil }
        return DateInterval(start: start, end: startOfToday)
    }

    /// `yyyy-MM-dd` in `calendar`'s time zone. Sorts the same as the dates.
    static func dayKey(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Yesterday, when no day that late has been handled yet, and records it
    /// as handled. `nil` once it's been claimed, and after the clock moves
    /// back to an earlier day, so no day is ever reported twice.
    static func claimPreviousDay(now: Date, calendar: Calendar, defaults: UserDefaults) -> DateInterval? {
        guard let day = previousDay(before: now, calendar: calendar) else { return nil }
        let key = dayKey(for: day.start, calendar: calendar)
        if let last = defaults.string(forKey: dailyCountsLastDayKey), last >= key { return nil }
        defaults.set(key, forKey: dailyCountsLastDayKey)
        return day
    }

    // MARK: - Properties

    /// `nil` when nothing was shown or accepted, so an idle day sends nothing.
    static func dailyCountsProperties(_ counts: DailyCounts, setup: Setup) -> [String: String]? {
        let shown = max(0, counts.suggestionsShown)
        let accepted = max(0, counts.suggestionsAccepted)
        guard shown > 0 || accepted > 0 else { return nil }
        var properties = setupProperties(setup)
        properties["suggestions_shown"] = String(shown)
        properties["suggestions_accepted"] = String(accepted)
        properties["words_accepted_bucket"] = AnalyticsReporter.wordCountBucket(
            wordsAccepted(fromCharacters: counts.acceptedCharacters)
        )
        return properties
    }

    static func setupProperties(_ setup: Setup) -> [String: String] {
        [
            "save_enabled": setup.saveEnabled ? "true" : "false",
            "autocomplete_enabled": setup.autocompleteEnabled ? "true" : "false",
            "app_scope": setup.appScope.rawValue,
            "model_choice": modelChoice(setup.model),
        ]
    }

    static func modelChoice(_ model: TildeModelChoice) -> String {
        switch model {
        case .gemma4E2B: "gemma_e2b"
        case .qwen35B9B: "qwen_9b"
        }
    }

    /// Standard words, rounded to the nearest whole word.
    static func wordsAccepted(fromCharacters characters: Int) -> Int {
        (max(0, characters) + charactersPerWord / 2) / charactersPerWord
    }
}
