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
        []
    }

    static func movedHighlight(from highlighted: Int?, by delta: Int, count: Int) -> Int? {
        highlighted
    }

    static func returnDecision(highlighted: Int?, suggestionCount: Int) -> ReturnDecision {
        .submitTyped
    }

    static func escapeDecision(suggestionsVisible: Bool, hasCancelHandler: Bool) -> EscapeDecision {
        .ignore
    }
}
