import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Personal suggestion daily buckets")
struct PersonalSuggestionStatsTests {
    @Test("User-facing source counters follow the local calendar")
    func localDayBuckets() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = try! #require(utc.date(from: DateComponents(
            year: 2026, month: 8, day: 12, hour: 0, minute: 50
        )))
        var chicago = Calendar(identifier: .gregorian)
        chicago.timeZone = TimeZone(identifier: "America/Chicago")!
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        #expect(PersonalSuggestionStats.dayKey(for: date, calendar: chicago)
            == "personal-suggestions.2026-08-11")
        #expect(PersonalSuggestionStats.dayKey(for: date, calendar: tokyo)
            == "personal-suggestions.2026-08-12")
    }
}
