import Foundation
import TranscriptedCaptureKit

/// Extracts a structured summary preview (overview + decisions + action items)
/// from a saved meeting's Markdown, when the app has written a local summary
/// into it. Returns `nil` when no usable summary is present, so callers can fall
/// back to raw dialogue lines.
///
/// This mirrors the app-side parser in
/// `Sources/UI/Shared/RecentCaptureScanners.swift`
/// (`RecentMeetingSummaryPreviewParser` / `sectionsFromLocalSummaryBody` +
/// `sectionsFromFrontmatter`). It is ported here because the MCP server has no
/// compile-time dependency on the app target.
enum MeetingSummaryPreview {
    private static let startMarker = "<!-- transcripted:local-summary:start v=1 -->"
    private static let endMarker = "<!-- transcripted:local-summary:end -->"

    private static let maximumPreviewCharacters = 1_600

    /// Section titles surfaced in the preview, in display order. `Summary` is
    /// required; the rest are appended under their own labels when present.
    private static let previewSectionTitles = ["Summary", "Decisions", "Action Items", "Next Steps"]

    /// All local-summary section titles we know how to extract from the body.
    private static let bodySectionTitles = [
        "Participants",
        "Summary",
        "Next Steps",
        "Decisions",
        "Action Items",
        "Open Questions",
        "Risks or Follow-ups",
        "Accuracy Notes"
    ]

    /// Returns a structured preview string, or `nil` when the meeting has no
    /// usable local summary.
    static func preview(from content: String) -> String? {
        guard let document = CaptureMarkdownParser.parseFrontmatter(from: content),
              document.values["local_summary_version"] != nil else {
            return nil
        }

        let body = bodySections(document.body)
        let sections = body.isEmpty ? frontmatterSections(document.values) : body

        guard let summary = sections["Summary"], !summary.isEmpty else { return nil }

        let rendered = previewSectionTitles.compactMap { title -> String? in
            guard let text = sections[title], !text.isEmpty else { return nil }
            return title == "Summary" ? text : "\(title):\n\(text)"
        }.joined(separator: "\n\n")

        return limited(rendered, to: maximumPreviewCharacters)
    }

    /// Extracts `### Title` subsections from the local-summary block in the body.
    private static func bodySections(_ body: String) -> [String: String] {
        guard let block = localSummaryBlock(in: body) else { return [:] }
        var sections: [String: String] = [:]
        for title in bodySectionTitles {
            guard let raw = section("### \(title)", in: block, headingLevel: "###") else { continue }
            let text = cleanSectionText(raw)
            if !text.isEmpty { sections[title] = text }
        }
        return sections
    }

    /// Falls back to the `local_summary*` frontmatter keys when the body has no
    /// rendered block (older transcripts only carried the values in YAML).
    private static func frontmatterSections(_ values: [String: String]) -> [String: String] {
        let mapping: [(title: String, key: String)] = [
            ("Participants", "local_summary_participants"),
            ("Summary", "local_summary"),
            ("Next Steps", "local_summary_next_steps"),
            ("Decisions", "local_summary_decisions"),
            ("Action Items", "local_summary_action_items"),
            ("Open Questions", "local_summary_open_questions"),
            ("Risks or Follow-ups", "local_summary_risks_or_followups"),
            ("Accuracy Notes", "local_summary_accuracy_notes")
        ]
        var sections: [String: String] = [:]
        for entry in mapping {
            guard let text = cleanFrontmatterValue(values[entry.key]), !text.isEmpty else { continue }
            sections[entry.title] = text
        }
        return sections
    }

    private static func localSummaryBlock(in body: String) -> String? {
        guard let startRange = body.range(of: startMarker),
              let endRange = body.range(of: endMarker, range: startRange.upperBound..<body.endIndex) else {
            return nil
        }
        return String(body[startRange.upperBound..<endRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Returns the text under `heading` up to the next heading at the same level.
    private static func section(_ heading: String, in body: String, headingLevel: String) -> String? {
        let lines = body.components(separatedBy: .newlines)
        guard let startIndex = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespacesAndNewlines) == heading
        }) else {
            return nil
        }

        var endIndex = lines.endIndex
        for index in lines.index(after: startIndex)..<lines.endIndex {
            let trimmed = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("\(headingLevel) "), trimmed != heading {
                endIndex = index
                break
            }
        }

        return lines[lines.index(after: startIndex)..<endIndex]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func cleanSectionText(_ raw: String) -> String {
        let text = raw
            .components(separatedBy: .newlines)
            .map(cleanMarkdown)
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text == "None found." ? "" : text
    }

    private static func cleanFrontmatterValue(_ raw: String?) -> String? {
        let text = cleanMarkdown(raw)
            .replacingOccurrences(of: " | ", with: "\n")
        return text.isEmpty || text == "None found." ? nil : text
    }

    private static func cleanMarkdown(_ raw: String?) -> String {
        var text = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        for prefix in ["- ", "* "] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func limited(_ value: String, to characterLimit: Int) -> String {
        guard value.count > characterLimit else { return value }
        return String(value.prefix(characterLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
