import Foundation

/// What the main app's speaker name field shows under the box while someone
/// is typing. Ranking is `SpeakerNameSelectionPolicy.sortedLabels` (prefix,
/// then word-start, then contains, ignoring case and accents). The island
/// popup uses that same ranking through `NotchIslandSpeakerReviewPolicy`.
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
        limit: Int = limit
    ) -> [Suggestion] {
        guard isFocused, !listDismissed else { return [] }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if let untouchedPrefill,
           SpeakerNameSelectionPolicy.normalizedSearchText(trimmed)
            == SpeakerNameSelectionPolicy.normalizedSearchText(untouchedPrefill) {
            return []
        }

        let candidates = people.filter { $0.id != excludedID }
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

    static func returnDecision(highlighted: Int?, suggestionCount: Int) -> ReturnDecision {
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
