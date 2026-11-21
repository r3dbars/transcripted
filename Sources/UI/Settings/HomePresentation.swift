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
    /// The Keep audio filter with nothing kept. (The filter reads the
    /// transcript's `starred` flag, which is what Keep audio sets.)
    static let noStarredMeetings = "No meetings keep their audio yet. Turn on Keep audio from a meeting's \u{22EF} menu."

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

    /// The Meetings header ⋯ menu's import item: the file picker, same as
    /// the Settings row (Advanced › Transcription), ⌘O, and dropping files
    /// on the page.
    enum TranscribeFileAction {
        static let title = "Transcribe a file\u{2026}"
        static let help = "Choose audio or video to transcribe on this Mac. You can also drop files here or press \u{2318}O."
        static let automationIdentifier = "transcripted.home.new.transcribe-file"
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

/// Foundation-pure palette choice for transcript speaker names. It is the
/// voice-print palette (`VoicePrintStyle`), so a saved person is the same
/// color in a transcript, on the Speakers page and in the island review.
/// `HomeMeetingSpeakerColor` (HomeMeetingAudioPlayer.swift) turns the index
/// into a readable SwiftUI color.
enum HomeMeetingSpeakerPalette {
    /// Number of palette slots: the voice-print palette.
    static var slotCount: Int { VoicePrintStyle.palette.count }

    /// A saved person keys by profile ID, exactly like their print; an
    /// unsaved voice by its transcript key, so it stays put across launches.
    /// Takes the identity's parts (`HomeMeetingSpeakerIdentity.persistentSpeakerID`
    /// and `.stableID`) so this file stays free of the preview types.
    static func colorIndex(persistentSpeakerID: UUID?, stableID: String) -> Int {
        if let persistentSpeakerID {
            return VoicePrintStyle(id: persistentSpeakerID).preferredColorIndex
        }
        return VoicePrintStyle(seedString: stableID).preferredColorIndex
    }
}
