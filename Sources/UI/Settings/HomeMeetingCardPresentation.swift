import Foundation

/// Foundation-only rules for the Meetings page (`QuietMeetingCard`, the
/// failed and working rows, the titles opt-in line), so fast tests read the
/// same values the views lay out from.
///
/// The page is for finding a meeting: a closed row is play, title, one
/// summary and the start time. Opening a row turns it into a quiet card in
/// place; the transcript stays behind a "Transcript" reveal until asked for.
enum HomeMeetingCardPresentation {
    /// An opened transcript shows this many lines before "Show all N lines".
    static let openedLineLimit = 60
    /// The closed row's summary wraps to at most this many lines.
    static let summaryLineLimit = 2
    /// Names in a subtitle before "+N".
    static let participantLimit = 3

    // MARK: Day headers

    /// "Today", "Yesterday", then "Monday, Nov 16" (`HomeDaySectionLabel`).
    static func dayHeader(for day: Date, calendar: Calendar = .current) -> String {
        HomeDaySectionLabel.label(for: day, calendar: calendar)
    }

    // MARK: People and length

    /// Who was there, from the scanned metadata only (closed rows never read
    /// the transcript). The mic track is always you, so a recorded meeting
    /// leads with "You"; an imported file has no mic track and lists only
    /// the names found in it.
    static func people(speakerNames: [String], isImported: Bool) -> [String] {
        var seen = Set<String>()
        var people: [String] = []
        for name in (isImported ? [] : ["You"]) + speakerNames {
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

    /// The reveal row: "Transcript" / "Hide transcript".
    static func revealTitle(isShown: Bool) -> String {
        isShown ? "Hide transcript" : "Transcript"
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

    // MARK: VoiceOver

    /// "Pricing page review, today 2:00 PM, 48 minutes".
    static func accessibilityLabel(title: String, dayHeader: String, time: String, start: Date?, end: Date?) -> String {
        let day = (dayHeader == "Today" || dayHeader == "Yesterday") ? dayHeader.lowercased() : dayHeader
        var parts = [title, "\(day) \(time)"]
        if let length = spokenDuration(start: start, end: end) { parts.append(length) }
        return parts.joined(separator: ", ")
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

// MARK: - Open state

/// Which row is open and whether its transcript is showing. Only one row is
/// open at a time, and opening a row (even the same one again) always starts
/// with the transcript closed.
struct MeetingsPageOpenState: Equatable {
    private(set) var openID: String?
    private(set) var isTranscriptShown = false
    private(set) var showsAllLines = false

    /// Clicking a row: opens it, or closes it when it is the open one.
    static func nextOpenID(current: String?, tapped: String) -> String? {
        current == tapped ? nil : tapped
    }

    /// Follow the open row. A different row (or none) resets the transcript.
    mutating func sync(openID newID: String?) {
        guard newID != openID else { return }
        openID = newID
        isTranscriptShown = false
        showsAllLines = false
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
        openID == id && isTranscriptShown
    }

    func showsAllLines(for id: String) -> Bool {
        openID == id && showsAllLines
    }
}

// MARK: - Titles opt-in line

/// The one quiet line under the Meetings header that offers on-device titles
/// and summaries. Turning it on uses the feature's own switch
/// (`MeetingTitlesController.setEnabled`), the same one Settings shows.
enum MeetingTitlesOptInLine {
    static let dismissedKey = "meetingTitlesOptInLineDismissed"
    static let offer = "Get titles and summaries \u{00B7} \(MeetingTitlesController.downloadSizeLabel)"
    static let turnOnTitle = "Turn on"
    static let dismissTitle = "Dismiss"

    enum State: Equatable {
        case hidden
        /// Off: the offer, Turn on and Dismiss.
        case offer
        /// Turned on from this line: "1.2 GB of 3.1 GB" and a fraction.
        case downloading(fraction: Double, text: String)
        /// The download from this line stopped: amber reason and Try again.
        case failed(String)
    }

    /// `startedHere` is true once this line's Turn on was pressed this
    /// session: only then does it stay to show the download. Once the model
    /// is ready it goes. Never during automated launches, never once
    /// dismissed, and not on an empty library (the first-run state says
    /// enough).
    static func state(
        isEnabled: Bool,
        status: MeetingTitlesController.ModelStatus,
        dismissed: Bool,
        isAutomatedLaunch: Bool,
        hasMeetings: Bool,
        startedHere: Bool
    ) -> State {
        guard !isAutomatedLaunch, hasMeetings else { return .hidden }
        guard isEnabled else { return dismissed ? .hidden : .offer }
        guard startedHere else { return .hidden }
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
