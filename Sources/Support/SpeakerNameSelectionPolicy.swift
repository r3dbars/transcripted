import Foundation

enum SpeakerNameSelectionPolicy {
    static func makeIdentityLabels<Option>(
        for options: [Option],
        id: (Option) -> UUID,
        displayName: (Option) -> String,
        callCount: (Option) -> Int
    ) -> (labels: [String], lookup: [String: Option]) {
        let duplicateCounts = Dictionary(grouping: options, by: { normalizedSearchText(displayName($0)) })
            .mapValues(\.count)
        var lookup: [String: Option] = [:]

        let labels = options.map { option in
            let name = displayName(option)
            let label: String
            if duplicateCounts[normalizedSearchText(name), default: 0] > 1 {
                let calls = callCount(option) == 1 ? "1 call" : "\(callCount(option)) calls"
                label = "\(name) • \(calls) • \(id(option).uuidString.prefix(8))"
            } else {
                label = name
            }
            lookup[label] = option
            return label
        }

        return (labels, lookup)
    }

    static func sortedLabels<Option>(
        matching query: String,
        labels: [String],
        optionsByLabel: [String: Option],
        displayName: (Option) -> String,
        callCount: (Option) -> Int
    ) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return labels }
        return labels
            .compactMap { label -> (label: String, rank: Int)? in
                let rank = matchRank(for: label, query: trimmed, optionsByLabel: optionsByLabel, displayName: displayName)
                guard rank < Int.max else { return nil }
                return (label, rank)
            }
            .sorted { lhs, rhs in
                if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
                let lhsCalls = optionsByLabel[lhs.label].map(callCount) ?? 0
                let rhsCalls = optionsByLabel[rhs.label].map(callCount) ?? 0
                if lhsCalls != rhsCalls { return lhsCalls > rhsCalls }
                return lhs.label.localizedStandardCompare(rhs.label) == .orderedAscending
            }
            .map { $0.label }
    }

    static func completedLabel<Option>(
        for partial: String,
        labels: [String],
        optionsByLabel: [String: Option],
        displayName: (Option) -> String,
        callCount: (Option) -> Int
    ) -> String? {
        let normalizedPartial = normalizedSearchText(partial)
        guard !normalizedPartial.isEmpty else { return nil }

        let matches = sortedLabels(
            matching: partial,
            labels: labels,
            optionsByLabel: optionsByLabel,
            displayName: displayName,
            callCount: callCount
        )

        let prefixMatches = matches.filter { label in
            let name = optionsByLabel[label].map(displayName) ?? label
            return normalizedSearchText(name).hasPrefix(normalizedPartial)
                || normalizedSearchText(label).hasPrefix(normalizedPartial)
        }

        guard prefixMatches.count == 1 else { return nil }
        return prefixMatches[0]
    }

    static func option<Option>(
        matching input: String,
        optionsByLabel: [String: Option],
        displayName: (Option) -> String
    ) -> Option? {
        if let exact = optionsByLabel[input] {
            return exact
        }

        let normalizedInput = normalizedSearchText(input)
        let displayMatches = optionsByLabel.values.filter {
            normalizedSearchText(displayName($0)) == normalizedInput
        }
        guard displayMatches.count == 1 else { return nil }
        return displayMatches[0]
    }

    static func normalizedSearchText(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func matchRank<Option>(
        for label: String,
        query: String,
        optionsByLabel: [String: Option],
        displayName: (Option) -> String
    ) -> Int {
        let normalizedQuery = normalizedSearchText(query)
        guard !normalizedQuery.isEmpty else { return 0 }

        let normalizedLabel = normalizedSearchText(label)
        let name = optionsByLabel[label].map(displayName) ?? label
        let normalizedDisplayName = normalizedSearchText(name)
        let displayWords = normalizedDisplayName.split(separator: " ")

        if normalizedDisplayName == normalizedQuery { return 0 }
        if normalizedDisplayName.hasPrefix(normalizedQuery) { return 1 }
        if displayWords.contains(where: { $0.hasPrefix(normalizedQuery) }) { return 2 }
        if normalizedLabel.hasPrefix(normalizedQuery) { return 3 }
        if normalizedDisplayName.contains(normalizedQuery) { return 4 }
        if normalizedLabel.contains(normalizedQuery) { return 5 }
        return Int.max
    }
}
