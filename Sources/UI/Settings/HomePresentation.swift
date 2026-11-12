import Foundation

struct HomeDaySection<Item>: Identifiable {
    let day: Date
    let label: String
    let items: [Item]

    var id: TimeInterval { day.timeIntervalSinceReferenceDate }
}

// MARK: - Capture list copy

/// Empty-state copy for the Home capture lists. Foundation-pure constants so the
/// strings can be pinned by fast tests; `HomeView` reads them directly.
enum HomeCaptureListCopy {
    static let emptyMeetings = "No recent meetings. Record one or transcribe an existing audio file."
    static let emptyDictations = "No recent dictations."
    static let noMeetingMatches = "No meetings match your search."
    static let searchingMeetings = "Searching all meetings…"
    static let noStarredMeetings = "No starred meetings yet. Star one from its \u{22EF} menu."

    /// What an empty Meetings list says. A search (or the Starred filter)
    /// doesn't claim "none" before its pass over the library has looked.
    static func meetingsEmptyMessage(
        isSearching: Bool,
        starredOnly: Bool,
        query: String,
        isSearchPassRunning: Bool
    ) -> String {
        guard isSearching else { return emptyMeetings }
        if isSearchPassRunning { return searchingMeetings }
        if starredOnly, !HomeMeetingSearchPaging.isActive(query: query) { return noStarredMeetings }
        return noMeetingMatches
    }

    /// The Settings row that opens the picker for an audio or video file to
    /// transcribe. The QA import smoke presses it by this identifier.
    enum ImportFileRow {
        static let title = "Transcribe a file"
        static let value = "Choose"
        static let help = "Pick an audio or video file. The transcript lands with your meetings."
        static let automationIdentifier = "transcripted.settings.general.transcribe-audio-file"
    }

    /// The empty Meetings list's second button, which opens the same picker.
    enum EmptyMeetingsImportAction {
        static let title = "Transcribe a file…"
        static let automationIdentifier = "transcripted.home.meetings.empty.import-audio"
    }
}

// MARK: - Meeting rename affordance

/// Pinned copy and identifiers for the Home meeting-title rename control.
enum HomeMeetingRenameAffordance {
    static let title = "Rename"
    static let help = "Rename meeting"
    static let symbolName = "pencil"
    static let automationIdentifier = "transcripted.home.meeting-preview.rename"
}

enum HomeMeetingTitleEditPolicy {
    static func titleToCommit(draft: String, currentTitle: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != currentTitle else { return nil }
        return trimmed
    }
}

// MARK: - Day section labels

/// Foundation-pure day-section label derivation for the Home capture lists.
///
/// `HomeViewModel.dayLabel(for:)` maps a day-start `Date` to the section header
/// string ("Today", "Yesterday", or a formatted weekday/date). The decision and
/// formatting live here so they stay testable without SwiftUI; the view model
/// delegates to keep runtime output byte-for-byte identical.
enum HomeDaySectionLabel {
    static func label(for day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return formatter.string(from: day)
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateFormat = "EEEE, MMM d"
        return f
    }()
}

// MARK: - Day-grouped row identity

/// Identity and divider flags for one row in a Home / Dictations day section.
///
/// Meetings and Dictations share `HomeDayGroupedList`. Each row's `ForEach`
/// identity must be the capture's own id. A refresh can prepend or reorder
/// captures, changing their offsets without changing which capture they are.
/// Load More appends older rows while preserving the earlier row identities.
enum HomeDayGroupedRows {
    struct Row<Item>: Identifiable {
        let id: AnyHashable
        let item: Item
        let showsDividerAfter: Bool
    }

    /// The identity `ForEach` should use for a row. Must be the item's own
    /// id, never the offset in the current page.
    static func rowID<Item>(
        offset _: Int,
        item: Item,
        id: (Item) -> AnyHashable
    ) -> AnyHashable {
        // Prepending a capture can change the position of an existing row.
        id(item)
    }

    static func make<Item>(
        items: [Item],
        id: (Item) -> AnyHashable,
        showsRowDividers: Bool
    ) -> [Row<Item>] {
        let lastIndex = items.count - 1
        return items.enumerated().map { offset, item in
            Row(
                id: rowID(offset: offset, item: item, id: id),
                item: item,
                showsDividerAfter: showsRowDividers && offset < lastIndex
            )
        }
    }
}

// MARK: - Meeting speaker palette selection

/// Foundation-pure palette-slot selection for meeting speaker chips.
///
/// `HomeMeetingSpeakerColor.color(for:)` returns a SwiftUI `Color`, but the
/// underlying decision — which stable palette slot a speaker name maps to — is
/// deterministic and Foundation-only. That selection lives here so it can be
/// fast-tested; `color(for:)` keeps the slot -> `Color` mapping in `HomeView`.
enum HomeMeetingSpeakerPalette {
    /// Number of palette slots the speaker-color mapping spreads names across.
    static let slotCount = 8

    /// Stable palette slot index in `0..<slotCount` for a speaker name.
    static func slotIndex(for speaker: String, slotCount: Int = slotCount) -> Int {
        let normalized = speaker.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.unicodeScalars.reduce(UInt32(0)) { partial, scalar in
            partial &+ scalar.value
        }
        return Int(value % UInt32(slotCount))
    }
}
