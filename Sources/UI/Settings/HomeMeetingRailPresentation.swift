import Foundation

/// Foundation-only rules for the Meetings card's second row (time range,
/// length and who was there), its paragraph summary, the "N voices to name"
/// trigger, and the opened card's playback shell: the speed button, the
/// two-tone clock, the rail's "14:25 · Priya" hover pill and the mini
/// transcript that follows the playhead. The views lay out from these values,
/// and `Tests/HomeMeetingCardTests.swift` checks them.
enum HomeMeetingRailPresentation {
    // MARK: Row 2: time range and length

    /// "2:00 – 2:42 PM · 42m", "11:02 AM – 12:23 PM · 1h 21m", "14:00 – 14:42 · 42m",
    /// or just the start time without an end. The day period is said once
    /// when both ends share it.
    static func timeRangeText(start: Date, end: Date?, clock: MeetingsPageClock) -> String {
        let parts = timeRangeParts(start: start, end: end, clock: clock)
        guard let length = parts.length else { return parts.range }
        return "\(parts.range) \u{00B7} \(length)"
    }

    /// The range ("2:00 – 2:42 PM") and the length ("42m") apart, so the
    /// card can draw the length a step quieter.
    static func timeRangeParts(start: Date, end: Date?, clock: MeetingsPageClock) -> (range: String, length: String?) {
        let startText = HomeMeetingCardPresentation.timeText(for: start, clock: clock)
        guard let end, end > start else { return (startText, nil) }
        let endText = HomeMeetingCardPresentation.timeText(for: end, clock: clock)
        let range = "\(sharedPeriodTrimmed(startText, endText, locale: clock.locale)) \u{2013} \(endText)"
        return (range, compactDuration(start: start, end: end))
    }

    /// "42m", "1h 21m", "2h", "<1m"; nil without a real span.
    static func compactDuration(start: Date?, end: Date?) -> String? {
        guard let seconds = HomeMeetingCardPresentation.durationSeconds(start: start, end: end) else { return nil }
        let minutes = Int((seconds / 60).rounded())
        if minutes < 1 { return "<1m" }
        if minutes < 60 { return "\(minutes)m" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(rest)m"
    }

    /// The start time without its AM/PM when the end says the same one.
    private static func sharedPeriodTrimmed(_ start: String, _ end: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        for symbol in [formatter.amSymbol, formatter.pmSymbol].compactMap({ $0 }) where !symbol.isEmpty {
            let suffix = " " + symbol
            let narrow = "\u{202F}" + symbol
            for tail in [suffix, narrow] where start.hasSuffix(tail) && end.hasSuffix(tail) {
                return String(start.dropLast(tail.count))
            }
        }
        return start
    }

    // MARK: Row 2: who was there

    /// Up to this many people are listed by name; more fold into a stack.
    static let listedPeopleLimit = 3
    /// Rings drawn in a folded stack.
    static let stackRingLimit = 5

    enum PeopleLayout: Equatable {
        case none
        /// Each person with their print and name.
        case list([String])
        /// Overlapping prints (the first `stackRingLimit`) and "You + 6 others".
        case stack(rings: [String], label: String)
    }

    static func peopleLayout(_ people: [String]) -> PeopleLayout {
        guard !people.isEmpty else { return .none }
        guard people.count > listedPeopleLimit else { return .list(people) }
        return .stack(rings: Array(people.prefix(stackRingLimit)), label: stackLabel(people))
    }

    /// "You + 6 others", "Priya + 1 other".
    static func stackLabel(_ people: [String]) -> String {
        guard let first = people.first else { return "" }
        let others = people.count - 1
        guard others > 0 else { return first }
        return "\(first) + \(others) \(others == 1 ? "other" : "others")"
    }

    /// The People popover's line under a name: "Your mic", "14 meetings".
    static func peopleRoleLine(isYou: Bool, meetingCount: Int?) -> String {
        if isYou { return "Your mic" }
        guard let meetingCount, meetingCount > 0 else { return "On this call" }
        return meetingCount == 1 ? "1 meeting" : "\(meetingCount) meetings"
    }

    static let peoplePopoverTitle = "People on this call"

    // MARK: Row 2: voices to name

    /// "1 voice to name", "3 voices to name"; nil with nothing to name.
    static func voicesToNameTitle(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 voice to name" : "\(count) voices to name"
    }

    // MARK: Row 3: the summary paragraph

    /// A closed card shows the summary as a paragraph of at most this many lines.
    static let closedSummaryLineLimit = 4

    /// The full summary, else the one-line takeaway, else nil (the card then
    /// shows the length-and-people fallback slot).
    static func summaryParagraph(summary: String?, summaryLine: String?) -> String? {
        for text in [summary, summaryLine] {
            if let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    // MARK: Playback shell

    /// "1×", "1.25×", "1.5×", "2×".
    static func speedLabel(_ rate: Float) -> String {
        let rounded = (Double(rate) * 100).rounded() / 100
        let text = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%g", rounded)
        return "\(text)\u{00D7}"
    }

    /// The clock's two halves: "14:22" and "42:08", or "-27:46" left.
    static func clockTexts(elapsed: TimeInterval, total: TimeInterval, showsRemaining: Bool) -> (elapsed: String, trailing: String) {
        let clampedTotal = max(total, 0)
        let clamped = min(max(elapsed, 0), clampedTotal)
        let trailing = showsRemaining
            ? "-" + MeetingAudioPlayback.clockText(clampedTotal - clamped)
            : MeetingAudioPlayback.clockText(clampedTotal)
        return (MeetingAudioPlayback.clockText(clamped), trailing)
    }

    /// How long a line can run past its start before the rail calls it
    /// silence (the transcript only says when each line starts).
    static let longestLineSpan: TimeInterval = 45

    /// The line being spoken at `time`: the last line that started at or
    /// before it. `starts` is each line's start (nil when the line has no
    /// usable time), in transcript order.
    static func activeLineIndex(starts: [TimeInterval?], at time: TimeInterval) -> Int? {
        var active: Int?
        for (index, start) in starts.enumerated() {
            guard let start else { continue }
            if start <= time { active = index } else { break }
        }
        return active
    }

    /// Who is speaking at `time`, for the rail's hover pill: the active
    /// line, until the next one starts or `longestLineSpan` has gone by
    /// (after that it's silence and the pill shows only the time).
    static func speakingLineIndex(starts: [TimeInterval?], at time: TimeInterval) -> Int? {
        guard let index = activeLineIndex(starts: starts, at: time), let start = starts[index] else { return nil }
        return time - start <= longestLineSpan ? index : nil
    }

    /// "14:25 · Priya", or "14:25" when nobody is speaking there.
    static func hoverPillText(time: TimeInterval, speaker: String?) -> String {
        let clock = MeetingAudioPlayback.clockText(max(time, 0))
        guard let speaker = speaker?.trimmingCharacters(in: .whitespacesAndNewlines), !speaker.isEmpty else { return clock }
        return "\(clock) \u{00B7} \(speaker)"
    }

    /// Lines the mini transcript lays out around the active one (it shows
    /// about three; the rest let it scroll without popping in).
    static let miniTranscriptReach = 3

    /// The window of line indices the mini transcript draws for `active`.
    static func miniTranscriptWindow(active: Int?, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let center = min(max(active ?? 0, 0), count - 1)
        let lower = max(0, center - miniTranscriptReach)
        let upper = min(count, center + miniTranscriptReach + 1)
        return lower..<upper
    }

    /// Whether the mini transcript is showing: once a card's audio has been
    /// played, scrubbed or skipped, until the card closes.
    static func showsMiniTranscript(hasStarted: Bool, isActive: Bool, hasLines: Bool) -> Bool {
        hasLines && (hasStarted || isActive)
    }
}
