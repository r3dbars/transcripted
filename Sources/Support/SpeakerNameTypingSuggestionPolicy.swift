import Foundation

/// What the main app's speaker name field shows under the box while someone
/// is typing. Ranking is `SpeakerNameSelectionPolicy.sortedLabels` (exact,
/// prefix, hyphen-aware word-start, then contains, ignoring case and accents,
/// never transliterating). The island popup uses that same ranking through
/// `NotchIslandSpeakerReviewPolicy`.
enum SpeakerNameTypingSuggestionPolicy {
    static let limit = 5

    struct Suggestion: Equatable, Identifiable {
        var id: UUID { person.id }
        let person: SpeakerNameChoice
        let label: String
    }

    enum ReturnDecision: Equatable {
        case selectIndex(Int)
        case submitTyped
    }

    enum EscapeDecision: Equatable {
        case hideSuggestions
        case cancel
        case ignore
    }

    static func suggestions(
        query: String,
        isFocused: Bool,
        people: [SpeakerNameChoice],
        excluding excludedID: UUID? = nil,
        listDismissed: Bool = false,
        untouchedPrefill: String? = nil,
        isBrowsingAll: Bool = false,
        limit: Int = limit
    ) -> [Suggestion] {
        guard isFocused, !listDismissed else { return [] }
        let candidates = people.filter { $0.id != excludedID }
        if isBrowsingAll {
            return labeledSuggestions(for: candidates)
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let untouchedPrefill,
           SpeakerNameSelectionPolicy.normalizedSearchText(trimmed)
            == SpeakerNameSelectionPolicy.normalizedSearchText(untouchedPrefill) {
            return []
        }

        let built = SpeakerNameSelectionPolicy.makeIdentityLabels(
            for: candidates,
            id: { $0.id },
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
        let ranked = SpeakerNameSelectionPolicy.sortedLabels(
            matching: trimmed,
            labels: built.labels,
            optionsByLabel: built.lookup,
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
        return ranked.prefix(limit).compactMap { label in
            guard let person = built.lookup[label] else { return nil }
            return Suggestion(person: person, label: label)
        }
    }

    /// Full saved-people directory, highest call count first, then the name.
    /// Used by the chevron; typing still goes through `sortedLabels` and the cap.
    private static func labeledSuggestions(for people: [SpeakerNameChoice]) -> [Suggestion] {
        let built = SpeakerNameSelectionPolicy.makeIdentityLabels(
            for: people,
            id: { $0.id },
            displayName: { $0.displayName },
            callCount: { $0.callCount }
        )
        let ordered = built.labels.sorted { lhs, rhs in
            let lhsCalls = built.lookup[lhs].map(\.callCount) ?? 0
            let rhsCalls = built.lookup[rhs].map(\.callCount) ?? 0
            if lhsCalls != rhsCalls { return lhsCalls > rhsCalls }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        return ordered.compactMap { label in
            guard let person = built.lookup[label] else { return nil }
            return Suggestion(person: person, label: label)
        }
    }

    /// `nil` highlight means nobody has used the arrows yet. Down lands on
    /// the first row, up on the last; further arrows stay on the end.
    static func movedHighlight(from highlighted: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0, delta != 0 else { return highlighted }
        let start: Int
        if let highlighted, (0..<count).contains(highlighted) {
            start = highlighted
        } else {
            start = delta > 0 ? -1 : count
        }
        return min(max(start + delta, 0), count - 1)
    }

    /// The painted row. Arrows win over hover so the highlight matches
    /// `returnDecision`. Hover only paints when nobody has used the arrows.
    static func paintedHighlight(keyboard: Int?, hover: Int?) -> Int? {
        keyboard ?? hover
    }

    /// Return commits the keyboard (arrow-key) highlight only. `hoverHighlight`
    /// is visual paint and is ignored so brushing a row cannot file a voice
    /// under the wrong person.
    static func returnDecision(
        highlighted: Int?,
        suggestionCount: Int,
        hoverHighlight _: Int? = nil
    ) -> ReturnDecision {
        if let highlighted, (0..<suggestionCount).contains(highlighted) {
            return .selectIndex(highlighted)
        }
        return .submitTyped
    }

    static func escapeDecision(suggestionsVisible: Bool, hasCancelHandler: Bool) -> EscapeDecision {
        if suggestionsVisible { return .hideSuggestions }
        if hasCancelHandler { return .cancel }
        return .ignore
    }
}
