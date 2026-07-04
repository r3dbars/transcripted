import Foundation

enum TimelineChatPromptError: Error, Equatable, CustomStringConvertible {
    case cloudNoticeRequired(String)

    var description: String {
        switch self {
        case .cloudNoticeRequired(let provider):
            return "Timeline chat needs a one-time notice before sending day context to \(provider)."
        }
    }
}

struct ChatPromptBuilder {
    func buildPrompt(context: TimelineChatPromptContext) throws -> String {
        switch context.privacyMode {
        case .localOnly:
            break
        case .cloudProvider(let name, let noticeAccepted):
            guard noticeAccepted else {
                throw TimelineChatPromptError.cloudNoticeRequired(name)
            }
        }

        var lines: [String] = []
        lines.append("You answer questions about one Transcripted timeline day.")
        lines.append("Use only the supplied timeline cards, observations, and meeting excerpts.")
        lines.append("Do not claim to have seen screenshots, audio, files, or apps directly.")
        lines.append("If the context is missing something, say what is missing.")
        lines.append("")
        lines.append("Question:")
        lines.append(context.question)
        lines.append("")
        lines.append("Timeline cards:")

        if context.cards.isEmpty {
            lines.append("- No timeline cards were found in the selected range.")
        } else {
            for card in context.cards.sorted(by: { $0.start < $1.start }) {
                lines.append("- \(timeRange(card.start, card.end)) [\(card.kind), \(card.category)] \(card.title): \(card.summary)")
                if let detailedSummary = card.detailedSummary, !detailedSummary.isEmpty {
                    lines.append("  Details: \(detailedSummary)")
                }
                if let captureID = card.captureID, !captureID.isEmpty {
                    lines.append("  Capture ID: \(captureID)")
                }
            }
        }

        if !context.observations.isEmpty {
            lines.append("")
            lines.append("Local observations:")
            for observation in context.observations.sorted(by: { $0.start < $1.start }) {
                lines.append("- \(timeRange(observation.start, observation.end)): \(observation.text)")
            }
        }

        if !context.meetingMarkdownByCaptureID.isEmpty {
            lines.append("")
            lines.append("Meeting excerpts:")
            for captureID in context.meetingMarkdownByCaptureID.keys.sorted() {
                let excerpt = context.meetingMarkdownByCaptureID[captureID] ?? ""
                lines.append("Capture ID \(captureID):")
                lines.append(Self.trimmedExcerpt(excerpt))
            }
        }

        return lines.joined(separator: "\n")
    }

    static func cloudNoticeText(providerName: String) -> String {
        "Timeline chat can send timeline text and meeting excerpts to \(providerName). Screenshots stay on this Mac. Continue only if you want this question answered by \(providerName)."
    }

    private func timeRange(_ start: Date, _ end: Date) -> String {
        "\(Self.timeFormatter.string(from: start))-\(Self.timeFormatter.string(from: end))"
    }

    private static func trimmedExcerpt(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4_000 else { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 4_000)
        return String(trimmed[..<end]) + "\n[excerpt truncated]"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()
}

