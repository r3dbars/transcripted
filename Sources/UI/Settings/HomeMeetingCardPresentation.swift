import Foundation

/// Foundation-only rules for the Meetings page (`QuietMeetingCard`, the
/// failed and working rows, the titles opt-in line), so fast tests read the
/// same values the views lay out from.
///
/// The page is for finding a meeting: a closed card is the title, the time
/// range with who was there, and the summary paragraph. Opening a card
/// unfolds it in place; the transcript stays behind a "Full transcript"
/// reveal until asked for. Row 2, the summary paragraph and the player's
/// rules are `HomeMeetingRailPresentation`.
enum HomeMeetingCardPresentation {
    /// An opened transcript shows this many lines before "Show all N lines".
    static let openedLineLimit = 60
    /// The closed row's summary wraps to at most this many lines.
    static let summaryLineLimit = 2
    /// Names in a subtitle before "+N".
    static let participantLimit = 3

    // MARK: Days and times

    /// "Today", "Yesterday", then "Monday, Nov 16" in the reader's own order
    /// and words, with the year when it isn't this year ("Monday, Nov 16,
    /// 2025"), so two Nov 16s in search results never look the same.
    static func dayHeader(for date: Date, clock: MeetingsPageClock) -> String {
        let calendar = clock.calendar
        let today = calendar.startOfDay(for: clock.now)
        let day = calendar.startOfDay(for: date)
        if day == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), day == yesterday {
            return "Yesterday"
        }
        var style = Date.FormatStyle(locale: clock.locale, calendar: calendar, timeZone: clock.timeZone)
            .weekday(.wide).month(.abbreviated).day()
        if calendar.component(.year, from: day) != calendar.component(.year, from: today) {
            style = style.year()
        }
        return date.formatted(style)
    }

    /// A row's start time, "2:00 PM" or "14:00" as the reader's Mac is set.
    static func timeText(for date: Date, clock: MeetingsPageClock) -> String {
        date.formatted(Date.FormatStyle(
            date: .omitted, time: .shortened,
            locale: clock.locale, calendar: clock.calendar, timeZone: clock.timeZone
        ))
    }

    /// The rows grouped by day, newest first as given, each row carrying the
    /// exact header text its section shows (VoiceOver reads the same words).
    static func daySections<Item>(
        _ items: [Item],
        date: (Item) -> Date,
        clock: MeetingsPageClock
    ) -> [HomeDaySection<MeetingsPageDayRow<Item>>] {
        var buckets: [(day: Date, items: [Item])] = []
        for item in items {
            let day = clock.calendar.startOfDay(for: date(item))
            if let index = buckets.firstIndex(where: { $0.day == day }) {
                buckets[index].items.append(item)
            } else {
                buckets.append((day, [item]))
            }
        }
        return buckets.map { bucket in
            let header = dayHeader(for: bucket.day, clock: clock)
            return HomeDaySection(
                day: bucket.day,
                label: header,
                items: bucket.items.map { MeetingsPageDayRow(item: $0, dayHeader: header) }
            )
        }
    }

    // MARK: People and length

    /// Who was there, from the scanned metadata only (closed rows never read
    /// the transcript). The mic track is you: a recorded meeting leads with
    /// "You", unless every voice on the mic was given a name, which then
    /// stands in for "You" instead of being listed a second time
    /// (`micVoices`, the mic-track voices as written; empty for files that
    /// don't say). An imported file has no mic track and lists only the
    /// names found in it.
    static func people(speakerNames: [String], micVoices: [String] = [], isImported: Bool) -> [String] {
        var lead: [String] = []
        if !isImported {
            let mic = micVoices
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let named = mic.filter { !isUnnamedVoice($0) && $0.lowercased() != "you" }
            let micHasYou = mic.isEmpty || named.count < mic.count
            lead = (micHasYou ? ["You"] : []) + named
        }
        var seen = Set<String>()
        var people: [String] = []
        for name in lead + speakerNames {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !isUnnamedVoice(trimmed), seen.insert(trimmed.lowercased()).inserted else { continue }
            people.append(trimmed)
        }
        return people
    }

    /// "Speaker", "Speaker 2", "Unknown": a voice nobody has named yet.
    static func isUnnamedVoice(_ name: String) -> Bool {
        let lowered = name.lowercased()
        if lowered == "unknown" || lowered == "speaker" { return true }
        guard lowered.hasPrefix("speaker ") else { return false }
        return lowered.dropFirst("speaker ".count).allSatisfy(\.isNumber)
    }

    /// "You, Priya" or "You, Priya, Leo +2".
    static func participantsText(_ names: [String]) -> String? {
        guard !names.isEmpty else { return nil }
        let shown = names.prefix(participantLimit).joined(separator: ", ")
        let rest = names.count - participantLimit
        return rest > 0 ? "\(shown) +\(rest)" : shown
    }

    /// "<1 min", "32 min", "1 hr", "1 hr 5 min"; nil without both ends.
    static func durationText(start: Date?, end: Date?) -> String? {
        guard let minutes = minutes(start: start, end: end) else { return nil }
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }

    /// The meeting's length in seconds, for the scrubber's total before the
    /// audio has loaded.
    static func durationSeconds(start: Date?, end: Date?) -> TimeInterval? {
        guard let start, let end, end > start else { return nil }
        return end.timeIntervalSince(start)
    }

    private static func minutes(start: Date?, end: Date?) -> Int? {
        durationSeconds(start: start, end: end).map { Int(($0 / 60).rounded()) }
    }

    // MARK: The closed row's summary slot

    /// What sits under a row's title: one thing, never a stack.
    enum Slot: Equatable {
        /// The model's one-line takeaway (`ai_summary_line`).
        case summary(String)
        /// "48 min · You, Marcus, Priya" when there is no summary line.
        case fallback(String)
        /// Work in flight: "Transcribing" with a percent, "Retrying".
        case working(String, percent: Int?)
        /// Amber wording for a meeting that needs a hand, with a quiet action
        /// when there is one ("Not transcribed" + "Try again").
        case problem(String, actionTitle: String?)
        /// Nothing to say (no summary, no length, no names).
        case empty
    }

    /// A saved meeting: its summary line, else length and people.
    static func savedSlot(summaryLine: String?, start: Date?, end: Date?, people: [String]) -> Slot {
        if let line = summaryLine?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
            return .summary(line)
        }
        return fallbackLine(start: start, end: end, people: people).map(Slot.fallback) ?? .empty
    }

    /// "48 min · You, Marcus, Priya", "48 min", "You, Priya", or nil.
    static func fallbackLine(start: Date?, end: Date?, people: [String]) -> String? {
        let parts = [durationText(start: start, end: end), participantsText(people)].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    /// A failed or unfinished meeting, from the wording the failed row has
    /// always used (`HomeFailedMeetingInlinePresentation`).
    static func failedSlot(_ presentation: HomeFailedMeetingInlinePresentation, isRetrying: Bool) -> Slot {
        if isRetrying { return .working(presentation.statusText, percent: nil) }
        return .problem(presentation.statusText, actionTitle: presentation.canShowRetryAction ? "Try again" : nil)
    }

    /// The in-flight row above the list: transcribing (with its percent),
    /// saved, or failed. `isCaution` is the activity's attention tone.
    static func workingSlot(status: String, percent: Int?, isCaution: Bool) -> Slot {
        isCaution ? .problem(status, actionTitle: nil) : .working(status, percent: percent)
    }

    // MARK: The opened card

    /// "2:00 PM · 48 min · You, Marcus, Priya".
    static func openedSubtitle(time: String, start: Date?, end: Date?, people: [String]) -> String {
        ([time] + [durationText(start: start, end: end), participantsText(people)].compactMap { $0 })
            .joined(separator: " \u{00B7} ")
    }

    /// The reveal row under the player: "Full transcript", its chevron
    /// turned while open.
    static func revealTitle(isShown: Bool) -> String {
        "Full transcript"
    }

    /// "214 lines" on the reveal row's right; nil until the file is read.
    static func lineCountText(_ count: Int?) -> String? {
        guard let count else { return nil }
        return count == 1 ? "1 line" : "\(count) lines"
    }

    /// "Show all 214 lines" under a revealed transcript that holds back the rest.
    static func showAllTitle(totalLineCount: Int) -> String? {
        totalLineCount > openedLineLimit ? "Show all \(totalLineCount) lines" : nil
    }

    /// How many transcript lines a revealed transcript draws.
    static func shownLineCount(total: Int, showsAll: Bool) -> Int {
        showsAll ? total : min(total, openedLineLimit)
    }

    /// The opened card's ⋯ menu, before Option: Rename, Who spoke?,
    /// Transcribe again, Keep audio, Show in Finder, Delete (the conditional
    /// ones drop out as they always have; `HomeRowMenuPolicy`).
    static func openedMenuEntries(_ entries: [HomeRowMenuEntry]) -> [HomeRowMenuEntry] {
        HomeRowMenuPolicy.visibleMenuEntries(entries)
    }

    /// The scrubber's "0:42" and "48:00", or nil while the length is still
    /// unknown (a failed meeting before its audio has played), so it never
    /// reads "0:00 / 0:00".
    static func scrubberClockTexts(fraction: Double, total: TimeInterval) -> (elapsed: String, total: String)? {
        guard total > 0 else { return nil }
        let clamped = min(max(fraction, 0), 1)
        return (MeetingAudioPlayback.clockText(clamped * total), MeetingAudioPlayback.clockText(total))
    }

    // MARK: Who spoke?

    /// What the opened card knows about its transcript for "Who spoke?".
    enum TranscriptRead: Equatable {
        case notLoaded
        case failed
        case loaded(speakerLineCount: Int)
    }

    enum WhoSpokeAvailability: Equatable {
        /// Not in the menu (a closed row with nothing waiting).
        case hidden
        /// In the opened card's menu but greyed: the lines are still loading,
        /// or the transcript has no speaker lines to name.
        case disabled
        case enabled
    }

    /// "Who spoke?" in ⋯ always has a card to open: the review queue's card
    /// when this meeting has voices waiting, else one built from the opened
    /// transcript's speaker lines. The opened card always lists it; it is
    /// greyed until there is a card, so it never drops the reader on
    /// Speakers with nothing to answer.
    static func whoSpokeAvailability(isOpen: Bool, hasQueuedReview: Bool, transcript: TranscriptRead) -> WhoSpokeAvailability {
        if hasQueuedReview { return .enabled }
        guard isOpen else { return .hidden }
        if case .loaded(let count) = transcript, count > 0 { return .enabled }
        return .disabled
    }

    // MARK: The open card after its file changes

    /// Whether a change to saved meetings (`affectedIDs` from
    /// `CaptureLibraryChange`, empty for a library-wide change) touched the
    /// open card's transcript, so the card re-reads it.
    static func shouldRereadOpenCard(openTranscriptURL: URL?, affectedIDs: [String]) -> Bool {
        guard let openTranscriptURL else { return false }
        return affectedIDs.isEmpty || affectedIDs.contains(openTranscriptURL.standardizedFileURL.path)
    }

    // MARK: VoiceOver

    /// "Pricing page review, today 2:00 PM, 48 minutes".
    static func accessibilityLabel(title: String, dayHeader: String, time: String, start: Date?, end: Date?) -> String {
        let day = (dayHeader == "Today" || dayHeader == "Yesterday") ? dayHeader.lowercased() : dayHeader
        var parts = [title, "\(day) \(time)"]
        if let length = spokenDuration(start: start, end: end) { parts.append(length) }
        return parts.joined(separator: ", ")
    }

    /// What a slot says to VoiceOver as the row's value.
    static func spokenSlot(_ slot: Slot) -> String {
        switch slot {
        case .summary(let text), .fallback(let text), .working(let text, _), .problem(let text, _): return text
        case .empty: return ""
        }
    }

    /// A failed meeting's row for VoiceOver: label, value, and the named
    /// actions on the row itself. "Try again" is also its own button beside
    /// the status; the row's action reaches it without hunting for it.
    struct FailedRowAccessibility: Equatable {
        let label: String
        let value: String
        let actionNames: [String]
    }

    static func failedRowAccessibility(
        title: String,
        dayHeader: String,
        time: String,
        slot: Slot,
        retryIsEnabled: Bool
    ) -> FailedRowAccessibility {
        var actions: [String] = []
        if case .problem(_, let actionTitle?) = slot, retryIsEnabled { actions.append(actionTitle) }
        return FailedRowAccessibility(
            label: accessibilityLabel(title: title, dayHeader: dayHeader, time: time, start: nil, end: nil),
            value: spokenSlot(slot),
            actionNames: actions
        )
    }

    /// "48 minutes", "1 hour 5 minutes", "less than a minute".
    static func spokenDuration(start: Date?, end: Date?) -> String? {
        guard let minutes = minutes(start: start, end: end) else { return nil }
        if minutes < 1 { return "less than a minute" }
        func unit(_ value: Int, _ word: String) -> String { value == 1 ? "1 \(word)" : "\(value) \(word)s" }
        if minutes < 60 { return unit(minutes, "minute") }
        let rest = minutes % 60
        return rest == 0 ? unit(minutes / 60, "hour") : "\(unit(minutes / 60, "hour")) \(unit(rest, "minute"))"
    }
}

// MARK: - Clock

/// The calendar, locale, time zone and "now" the page's days and times are
/// read with. The page takes a fresh one when it appears and when the day,
/// the time zone or the locale changes, so "Today" turns into "Yesterday" at
/// midnight without a restart; tests pass a fixed one.
struct MeetingsPageClock: Equatable {
    let calendar: Calendar
    let locale: Locale
    let timeZone: TimeZone
    let now: Date

    init(now: Date, locale: Locale, timeZone: TimeZone, calendar: Calendar = Calendar(identifier: .gregorian)) {
        var calendar = calendar
        calendar.locale = locale
        calendar.timeZone = timeZone
        self.calendar = calendar
        self.locale = locale
        self.timeZone = timeZone
        self.now = now
    }

    /// The Mac's own settings (12/24-hour included) as of `now`.
    static func current(now: Date = Date()) -> MeetingsPageClock {
        MeetingsPageClock(
            now: now,
            locale: .autoupdatingCurrent,
            timeZone: .autoupdatingCurrent,
            calendar: .autoupdatingCurrent
        )
    }
}

/// One row in a day section, with the header its section shows.
struct MeetingsPageDayRow<Item> {
    let item: Item
    let dayHeader: String
}

// MARK: - Open state

/// Which row is open and whether its transcript is showing. Only one row is
/// open at a time, and opening a row (even the same one again) always starts
/// with the transcript closed. A rename changes a meeting's id (its path);
/// `followRename` carries the open card, its reveal and Show all across it,
/// and keeps the old id open until the list shows the renamed row.
struct MeetingsPageOpenState: Equatable {
    private(set) var openID: String?
    private(set) var isTranscriptShown = false
    private(set) var showsAllLines = false
    /// The open meeting's id before its last rename.
    private(set) var renamedFromID: String?

    /// Clicking a row: opens it, or closes it when it is the open one.
    static func nextOpenID(current: String?, tapped: String) -> String? {
        current == tapped ? nil : tapped
    }

    /// The open-row key for a failed meeting. Saved and failed rows share one
    /// open slot, so opening either closes the other; a path never starts
    /// with this.
    static func failedMeetingKey(_ id: UUID) -> String {
        "failed-meeting:\(id.uuidString)"
    }

    /// Follow the open row. A different row (or none) resets the transcript.
    /// True when that was a fresh open (the page scrolls the card into view).
    @discardableResult
    mutating func sync(openID newID: String?) -> Bool {
        guard newID != openID else { return false }
        openID = newID
        isTranscriptShown = false
        showsAllLines = false
        renamedFromID = nil
        return newID != nil
    }

    /// The open meeting was renamed from `oldID` to `newID`: same card.
    mutating func followRename(from oldID: String, to newID: String) {
        guard openID == oldID, oldID != newID else { return }
        openID = newID
        renamedFromID = oldID
    }

    /// Whether the row with `rowID` is the open one, given the shell's open
    /// id. The row still listed under its old path during a rename counts.
    func isOpen(_ rowID: String, expandedID: String?) -> Bool {
        guard let expandedID else { return false }
        if rowID == expandedID { return true }
        return openID == expandedID && renamedFromID == rowID
    }

    mutating func toggleTranscript() {
        guard openID != nil else { return }
        isTranscriptShown.toggle()
        if !isTranscriptShown { showsAllLines = false }
    }

    mutating func showAllLines() {
        guard isTranscriptShown else { return }
        showsAllLines = true
    }

    func isTranscriptShown(for id: String) -> Bool {
        matches(id) && isTranscriptShown
    }

    func showsAllLines(for id: String) -> Bool {
        matches(id) && showsAllLines
    }

    private func matches(_ id: String) -> Bool {
        openID != nil && (openID == id || renamedFromID == id)
    }
}

// MARK: - Titles opt-in line

/// The one quiet line under the Meetings header that offers on-device titles
/// and summaries. Turning it on uses the feature's own switch
/// (`MeetingTitlesController.setEnabled`), the same one Settings shows.
enum MeetingTitlesOptInLine {
    static let dismissedKey = "meetingTitlesOptInLineDismissed"
    static let offerTitle = "Get titles and summaries"
    /// The offer when the model still has to come down.
    static let offer = "\(offerTitle) \u{00B7} \(MeetingTitlesController.downloadSizeLabel)"
    static let turnOnTitle = "Turn on"
    static let dismissTitle = "Dismiss"

    enum State: Equatable {
        case hidden
        /// Off: the offer, Turn on and Dismiss. Says the download size only
        /// when the model isn't on disk already.
        case offer(String)
        /// On, model coming down: "Downloading 1.2 GB of 3.1 GB" and a fraction.
        case downloading(fraction: Double, text: String)
        /// On, and the download or the model stopped: amber reason and Try again.
        case failed(String)
    }

    /// Read straight from the titles controller's own published state
    /// (`isEnabled`, `modelStatus`), so the line agrees with the Settings row
    /// wherever it was turned on and whichever page was showing meanwhile.
    /// Once the model is ready it goes. Never during automated launches,
    /// never once dismissed, and not on an empty library (the first-run
    /// state says enough).
    static func state(
        isEnabled: Bool,
        status: MeetingTitlesController.ModelStatus,
        dismissed: Bool,
        isAutomatedLaunch: Bool,
        hasMeetings: Bool
    ) -> State {
        guard !isAutomatedLaunch, hasMeetings, !dismissed else { return .hidden }
        guard isEnabled else { return .offer(status == .ready ? offerTitle : offer) }
        switch status {
        case .ready:
            return .hidden
        case .notDownloaded:
            return .downloading(fraction: 0, text: "Starting download\u{2026}")
        case .downloading(let received, let total):
            let fraction = total > 0 ? min(1, max(0, Double(received) / Double(total))) : 0
            let text = "Downloading \(ModelCacheInventory.formattedByteCount(received)) of \(ModelCacheInventory.formattedByteCount(total))"
            return .downloading(fraction: fraction, text: text)
        case .failed(let failure):
            return .failed(MeetingTitlesSettingsCopy.message(for: failure))
        }
    }
}
