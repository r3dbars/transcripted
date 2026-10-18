import Foundation

/// One action in a Home row's ⋯ menu.
enum HomeRowMenuEntry: Equatable, CaseIterable {
    case openMarkdown
    case revealDictation
    case renameMeeting
    case reportIssue
    case showTranscript
    case reviewSpeakers
    case boostMic
    case retranscribe
    case showAudio
    case deleteMeeting

    /// The menu title, when it never changes. Re-transcribe's title says why
    /// it's off (`RecentMeetingRetranscriptionMenuActionPolicy`).
    var fixedTitle: String? {
        switch self {
        case .openMarkdown: return "Open Markdown"
        case .revealDictation: return "Reveal in Finder"
        case .reportIssue: return "Report issue"
        case .showTranscript: return "Show transcript in Finder"
        case .reviewSpeakers: return "Review speakers"
        case .boostMic: return "Boost mic next meeting"
        case .showAudio: return "Show audio in Finder"
        case .deleteMeeting: return "Delete meeting"
        case .renameMeeting: return HomeMeetingRenameAffordance.title
        case .retranscribe: return nil
        }
    }

    var symbolName: String {
        switch self {
        case .openMarkdown, .showTranscript: return "doc.text"
        case .revealDictation: return "folder"
        case .renameMeeting: return HomeMeetingRenameAffordance.symbolName
        case .reportIssue: return "flag"
        case .reviewSpeakers: return "person.crop.circle.badge.questionmark"
        case .boostMic: return "mic.badge.plus"
        case .retranscribe: return "person.2.fill"
        case .showAudio: return "waveform"
        case .deleteMeeting: return "trash"
        }
    }

    var isDestructive: Bool { self == .deleteMeeting }
}

/// Which actions a Home row's ⋯ menu offers, in order. The Settings view maps
/// each entry to its handler; this decides what's there.
enum HomeRowMenuPolicy {
    /// No Report issue and no Delete here: dictations are quiet rows; the
    /// Dictations page drives per-entry delete itself through the inline-undo
    /// flow (QuietDictationLibrary), with no dialog.
    static let dictationEntries: [HomeRowMenuEntry] = [.openMarkdown, .revealDictation]

    /// Re-transcribe and Show audio need retained audio with a Finder target;
    /// re-transcribe also needs audio it can feed back through the pipeline.
    static func meetingEntries(
        hasPendingSpeakerReview: Bool,
        offersMicBoost: Bool,
        hasAudioRevealTarget: Bool,
        hasRetranscriptionInput: Bool
    ) -> [HomeRowMenuEntry] {
        var entries: [HomeRowMenuEntry] = [.renameMeeting, .reportIssue, .showTranscript]
        if hasPendingSpeakerReview {
            entries.append(.reviewSpeakers)
        }
        if offersMicBoost {
            entries.append(.boostMic)
        }
        if hasAudioRevealTarget {
            if hasRetranscriptionInput {
                entries.append(.retranscribe)
            }
            entries.append(.showAudio)
        }
        entries.append(.deleteMeeting)
        return entries
    }
}
