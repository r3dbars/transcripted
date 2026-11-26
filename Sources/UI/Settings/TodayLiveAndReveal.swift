import Foundation

// Link between Stats / Today items and the Dictations page so clicking a
// dictation item can locate and scroll to its saved entry.

extension TodayRecentItem {
    /// The saved dictation's own id (`SavedDictationEntry.id`) for a
    /// dictation row, so a click can find it on Dictations. Nil otherwise.
    var dictationEntryID: String? {
        guard kind == .dictation, id.hasPrefix(Self.dictationIDPrefix) else { return nil }
        let entryID = String(id.dropFirst(Self.dictationIDPrefix.count))
        return entryID.isEmpty ? nil : entryID
    }

    /// `TodayViewModel` builds dictation row ids as this prefix plus the entry id.
    static let dictationIDPrefix = "dictation-"
}

/// How long the Dictations page keeps loading older entries to find a
/// requested entry.
enum TodayDictationRevealPolicy {
    static let maximumExtraPages = 30
    static let giveUpAfter: Duration = .seconds(10)
}

/// A dictation the shell is waiting to scroll to, and how many older pages
/// it has loaded looking for it.
struct DictationPendingReveal: Equatable {
    let entryID: String
    var extraPagesLoaded = 0
}
