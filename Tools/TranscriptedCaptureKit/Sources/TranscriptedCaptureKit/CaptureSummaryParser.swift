import Foundation

/// Structured meeting-summary fields extracted from a saved capture. Carries the
/// rollup-friendly subset the index needs (decisions, action items, open
/// questions); each item is one bullet so cross-meeting tools can aggregate.
public struct ParsedMeetingSummary: Equatable {
    public struct ActionItem: Equatable {
        /// Named owner if the bullet led with one (`Owner: do thing`); nil means
        /// unassigned. Generic placeholders ("unassigned", "TBD", ...) normalize
        /// to nil so rollups don't treat them as a person.
        public let owner: String?
        public let text: String

        public init(owner: String?, text: String) {
            self.owner = owner
            self.text = text
        }
    }

    public let title: String?
    public let decisions: [String]
    public let actionItems: [ActionItem]
    public let openQuestions: [String]

    public init(
        title: String?,
        decisions: [String],
        actionItems: [ActionItem],
        openQuestions: [String]
    ) {
        self.title = title
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    public var isEmpty: Bool {
        decisions.isEmpty && actionItems.isEmpty && openQuestions.isEmpty
    }
}

/// Parses the structured summary sections (Decisions / Action Items / Open
/// Questions) out of a Transcripted capture.
///
/// This mirrors the section-parsing logic the app uses for the Home preview
/// (`RecentMeetingSummaryPreviewParser` in `Sources/UI/Shared/RecentCaptureScanners.swift`).
/// The app target's parser can't be imported by the standalone tools, so the
/// proven string logic lives here in the shared kit. It understands both shapes:
///
/// - inline summary written into the meeting transcript: frontmatter
///   `local_summary_version` plus a `## Local Summary` body block with `###`
///   subsections (and a pipe-joined `local_summary_*` frontmatter fallback).
/// - a generated `meeting_summary` sidecar file with `#` sections.
public enum CaptureSummaryParser {
    private static let startMarker = "<!-- transcripted:local-summary:start v=1 -->"
    private static let endMarker = "<!-- transcripted:local-summary:end -->"
    private static let placeholder = "None found."

    /// Returns nil when the content carries no structured summary, or when every
    /// indexable section is empty.
    public static func parse(from content: String) -> ParsedMeetingSummary? {
        guard let document = CaptureMarkdownParser.parseFrontmatter(from: content) else {
            return nil
        }
        let values = document.values
        let body = document.body

        if values["capture_type"] == "meeting_summary" {
            return assemble(
                title: cleanTitle(values["summary_title"]),
                decisions: bulletItems(section("# Decisions", in: body, headingLevel: "#")),
                actions: bulletItems(section("# Action Items", in: body, headingLevel: "#")),
                questions: bulletItems(section("# Open Questions", in: body, headingLevel: "#"))
            )
        }

        guard values["local_summary_version"] != nil else { return nil }

        let block = localSummaryBlock(in: body) ?? body
        return assemble(
            title: cleanTitle(values["local_summary_title"]),
            decisions: inlineItems("### Decisions", in: block, fallback: values["local_summary_decisions"]),
            actions: inlineItems("### Action Items", in: block, fallback: values["local_summary_action_items"]),
            questions: inlineItems("### Open Questions", in: block, fallback: values["local_summary_open_questions"])
        )
    }

    // MARK: - Assembly

    private static func assemble(
        title: String?,
        decisions: [String],
        actions: [String],
        questions: [String]
    ) -> ParsedMeetingSummary? {
        let summary = ParsedMeetingSummary(
            title: title,
            decisions: decisions,
            actionItems: actions.map(actionItem(from:)),
            openQuestions: questions
        )
        return summary.isEmpty ? nil : summary
    }

    /// Body `### Heading` wins; falls back to the pipe-joined `local_summary_*`
    /// frontmatter value when the body block is missing the heading entirely.
    private static func inlineItems(_ heading: String, in block: String, fallback: String?) -> [String] {
        if let raw = section(heading, in: block, headingLevel: "###") {
            return bulletItems(raw)
        }
        return frontmatterItems(fallback)
    }

    private static let placeholderOwners: Set<String> = [
        "unassigned", "tbd", "n/a", "na", "none", "unknown", "everyone", "all", "team"
    ]

    private static func actionItem(from text: String) -> ParsedMeetingSummary.ActionItem {
        // The summarizer prompts action bullets as "<Owner if named: follow-up>".
        // Treat a short leading segment before the first ": " as the owner only
        // when it reads like a name/team — a Title-Case noun phrase. Sentence
        // fragments ("Discuss the new API: ...") carry lowercase function words,
        // so we keep them as plain text instead of shredding a fake owner out.
        if let colon = text.range(of: ": ") {
            let owner = String(text[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(text[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, looksLikeOwner(owner) {
                let normalized = placeholderOwners.contains(owner.lowercased()) ? nil : owner
                return ParsedMeetingSummary.ActionItem(owner: normalized, text: rest)
            }
        }
        return ParsedMeetingSummary.ActionItem(owner: nil, text: text)
    }

    private static func looksLikeOwner(_ candidate: String) -> Bool {
        guard !candidate.isEmpty, candidate.count <= 24, !candidate.contains(".") else { return false }
        let words = candidate.split(separator: " ")
        guard (1...3).contains(words.count) else { return false }
        // Every word must lead with an uppercase letter (or a non-letter, e.g.
        // initials like "JW"). A lowercase function word ("the", "and") marks a
        // sentence fragment, not a name.
        return words.allSatisfy { word in
            guard let first = word.first else { return false }
            return !first.isLowercase
        }
    }

    // MARK: - Section extraction (ported from the app's preview parser)

    /// Returns the raw text under `heading` up to the next same-level heading, or
    /// nil when the heading is absent. Local-summary HTML markers are stripped so
    /// the start/end comment lines never bound a section.
    private static func section(_ heading: String, in body: String, headingLevel: String) -> String? {
        let stripped = body
            .replacingOccurrences(of: startMarker, with: "")
            .replacingOccurrences(of: endMarker, with: "")
        let lines = stripped.components(separatedBy: .newlines)
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

    private static func localSummaryBlock(in body: String) -> String? {
        guard let startRange = body.range(of: startMarker),
              let endRange = body.range(of: endMarker, range: startRange.upperBound..<body.endIndex) else {
            return nil
        }
        return String(body[startRange.lowerBound..<endRange.upperBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Item cleaning

    private static func bulletItems(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .components(separatedBy: .newlines)
            .map(cleanMarkdown)
            .filter { !$0.isEmpty && $0 != placeholder }
    }

    /// Frontmatter fallback values are pipe-joined ("a | b | c").
    private static func frontmatterItems(_ value: String?) -> [String] {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return value
            .components(separatedBy: " | ")
            .map(cleanMarkdown)
            .filter { !$0.isEmpty && $0 != placeholder }
    }

    private static func cleanTitle(_ raw: String?) -> String? {
        let title = cleanMarkdown(raw)
        guard !title.isEmpty, title != placeholder else { return nil }
        return String(title.prefix(96))
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
}
