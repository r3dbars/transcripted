import Foundation

/// Where a row action shows up. Most live in the ⋯ menu; a few ride along
/// without adding a visible menu line.
enum HomeRowMenuPlacement: Equatable {
    /// A normal ⋯ menu line.
    case menu
    /// Shown in place of the line above it while Option is held (Show audio
    /// in Finder under Show in Finder).
    case optionAlternate
    /// Not in the menu: the card's amber issue line carries it (Boost mic
    /// sits on "Mic was muffled"). VoiceOver still gets it as an action.
    case issueLine
}

/// One action in a Home row's ⋯ menu.
enum HomeRowMenuEntry: Equatable, CaseIterable {
    case openMarkdown
    case revealDictation
    case renameMeeting
    /// "Keep audio", off. It sets the transcript's `starred` flag, which is
    /// what retention reads, so a kept meeting keeps its audio.
    case starMeeting
    /// "Keep audio", on (checked). Turning it off clears the same flag.
    case unstarMeeting
    /// Not offered on meetings any more: Feedback lives in the sidebar.
    case reportIssue
    case showTranscript
    case reviewSpeakers
    case boostMic
    case retranscribe
    case showAudio
    case deleteMeeting

    /// The menu title, when it never changes. Transcribe again's title says
    /// why it's off (`RecentMeetingRetranscriptionMenuActionPolicy`).
    var fixedTitle: String? {
        switch self {
        case .openMarkdown: return "Open Markdown"
        case .revealDictation: return "Reveal in Finder"
        case .starMeeting, .unstarMeeting: return "Keep audio"
        case .reportIssue: return "Report issue"
        case .showTranscript: return "Show in Finder"
        case .reviewSpeakers: return "Who spoke?"
        case .boostMic: return "Boost mic next meeting"
        case .showAudio: return "Show audio in Finder"
        case .deleteMeeting: return "Delete"
        case .renameMeeting: return HomeMeetingRenameAffordance.title
        case .retranscribe: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .openMarkdown: return "doc.text"
        case .revealDictation, .showTranscript: return "folder"
        case .renameMeeting: return HomeMeetingRenameAffordance.symbolName
        case .starMeeting, .unstarMeeting: return "pin"
        case .reportIssue: return "flag"
        case .reviewSpeakers: return "person.crop.circle.badge.questionmark"
        case .boostMic: return "mic.badge.plus"
        case .retranscribe: return "arrow.clockwise"
        case .showAudio: return "waveform"
        case .deleteMeeting: return "trash"
        }
    }

    /// Hover help for an item whose title doesn't say everything.
    var toolTip: String? {
        switch self {
        case .starMeeting:
            return "Keep this meeting's audio past the limit in Storage settings."
        case .unstarMeeting:
            return "This meeting keeps its audio. Turn off to let Storage settings clean it up like the rest."
        default:
            return nil
        }
    }

    /// Checked in the menu: Keep audio is on.
    var isChecked: Bool { self == .unstarMeeting }

    var placement: HomeRowMenuPlacement {
        switch self {
        case .showAudio: return .optionAlternate
        case .boostMic: return .issueLine
        default: return .menu
        }
    }

    var isDestructive: Bool { self == .deleteMeeting }
}

/// Which actions a Home row's ⋯ menu offers, in order. The Settings view maps
/// each entry to its handler; this decides what's there.
enum HomeRowMenuPolicy {
    /// "Who spoke? · 2 to name", or just "Who spoke?" when the count isn't
    /// known yet. It opens the meeting's card on Speakers.
    static func whoSpokeTitle(voicesToName: Int) -> String {
        voicesToName > 0 ? "Who spoke? \u{00B7} \(voicesToName) to name" : "Who spoke?"
    }

    /// No Report issue and no Delete here: dictations are quiet rows; the
    /// Dictations page drives per-entry delete itself through the inline-undo
    /// flow (QuietDictationLibrary), with no dialog.
    static let dictationEntries: [HomeRowMenuEntry] = [.openMarkdown, .revealDictation]

    /// A meeting card's actions. The visible menu is Rename, Who spoke?,
    /// Transcribe again, Keep audio, Show in Finder, Delete; the conditional
    /// ones drop out when they don't apply. Show audio in Finder is Show in
    /// Finder's Option-alternate, and Boost mic rides on the card's amber
    /// "Mic was muffled" line (`HomeRowMenuEntry.placement`).
    ///
    /// Transcribe again and Show audio need retained audio with a Finder
    /// target; Transcribe again also needs audio it can feed back through the
    /// pipeline. Keep audio shows whenever there is audio to keep, and on any
    /// meeting that already keeps it, so it can always be turned off.
    static func meetingEntries(
        hasPendingSpeakerReview: Bool,
        offersMicBoost: Bool,
        hasAudioRevealTarget: Bool,
        hasRetranscriptionInput: Bool,
        isStarred: Bool = false
    ) -> [HomeRowMenuEntry] {
        var entries: [HomeRowMenuEntry] = [.renameMeeting]
        if hasPendingSpeakerReview {
            entries.append(.reviewSpeakers)
        }
        if hasAudioRevealTarget, hasRetranscriptionInput {
            entries.append(.retranscribe)
        }
        if hasAudioRevealTarget || isStarred {
            entries.append(isStarred ? .unstarMeeting : .starMeeting)
        }
        entries.append(.showTranscript)
        if hasAudioRevealTarget {
            entries.append(.showAudio)
        }
        if offersMicBoost {
            entries.append(.boostMic)
        }
        entries.append(.deleteMeeting)
        return entries
    }

    /// The lines the ⋯ menu draws, in order: every `.menu` item, each
    /// `.optionAlternate` right where it stands (it replaces the line above
    /// while Option is held), nothing that rides the issue line, and a
    /// separator before a destructive line. `HomeView` builds the real menu
    /// from this, so the tests check what the menu shows.
    static func menuLines<Item>(
        _ items: [Item],
        placement: (Item) -> HomeRowMenuPlacement,
        isDestructive: (Item) -> Bool
    ) -> [HomeRowMenuLine<Item>] {
        var lines: [HomeRowMenuLine<Item>] = []
        for item in items {
            let itemPlacement = placement(item)
            guard itemPlacement != .issueLine else { continue }
            lines.append(HomeRowMenuLine(
                item: item,
                isOptionAlternate: itemPlacement == .optionAlternate,
                separatorBefore: isDestructive(item) && !lines.isEmpty
            ))
        }
        return lines
    }

    static func menuLines(_ entries: [HomeRowMenuEntry]) -> [HomeRowMenuLine<HomeRowMenuEntry>] {
        menuLines(entries, placement: \.placement, isDestructive: \.isDestructive)
    }

    /// The lines a person sees in the ⋯ menu, before holding Option.
    static func visibleMenuEntries(_ entries: [HomeRowMenuEntry]) -> [HomeRowMenuEntry] {
        menuLines(entries).filter { !$0.isOptionAlternate }.map(\.item)
    }
}

/// One line of a Home row's ⋯ menu (`HomeRowMenuPolicy.menuLines`).
struct HomeRowMenuLine<Item> {
    var item: Item
    /// Shown instead of the line above while Option is held.
    var isOptionAlternate: Bool
    /// Delete sits under a separator, apart from the rest.
    var separatorBefore: Bool
}
