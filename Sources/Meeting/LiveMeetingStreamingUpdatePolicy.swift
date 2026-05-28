import Foundation

struct LiveMeetingStreamingUpdateState: Equatable {
    var lastText: String = ""
    var lastAppendedAt: Date?
}

enum LiveMeetingStreamingUpdatePolicy {
    static let defaultPartialAppendInterval: TimeInterval = 2.0

    static func normalizedText(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shouldAppend(
        text: String,
        isFinal: Bool,
        now: Date,
        state: LiveMeetingStreamingUpdateState,
        partialAppendInterval: TimeInterval = defaultPartialAppendInterval
    ) -> Bool {
        let normalized = normalizedText(text)
        guard !normalized.isEmpty else { return false }
        guard normalized != state.lastText else { return false }

        if isFinal {
            return true
        }

        guard let lastAppendedAt = state.lastAppendedAt else { return true }
        return now.timeIntervalSince(lastAppendedAt) >= partialAppendInterval
    }
}
