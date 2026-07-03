import Foundation

/// Structured meeting-summary fields extracted from a saved capture.
public struct ParsedMeetingSummary: Equatable {
    public struct ActionItem: Equatable {
        /// Named owner if the bullet led with one (`Owner: do thing`); nil means
        /// unassigned. Generic placeholders ("unassigned", "TBD", ...) normalize
        /// to nil so rollups don't treat them as a person.
        public let owner: String?
        public let text: String
        /// Lowercased status token from a trailing `(status: done)` / `(done)`
        /// marker; nil means open. Editing the marker in the saved Markdown is
        /// the supported way to close an item, so rollup filters stay in sync
        /// with what the user (or an agent) wrote back to the file.
        public let status: String?
        /// Free-text due hint from a trailing `(due: Friday)` marker.
        public let due: String?

        public init(owner: String?, text: String, status: String? = nil, due: String? = nil) {
            self.owner = owner
            self.text = text
            self.status = status
            self.due = due
        }
    }

    public let title: String?
    public let attendees: [String]
    public let decisions: [String]
    public let actionItems: [ActionItem]
    public let openQuestions: [String]

    public init(
        title: String?,
        attendees: [String] = [],
        decisions: [String],
        actionItems: [ActionItem],
        openQuestions: [String]
    ) {
        self.title = title
        self.attendees = attendees
        self.decisions = decisions
        self.actionItems = actionItems
        self.openQuestions = openQuestions
    }

    public var isEmpty: Bool {
        let cleanTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanTitle?.isEmpty ?? true)
            && attendees.isEmpty
            && decisions.isEmpty
            && actionItems.isEmpty
            && openQuestions.isEmpty
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
/// - inline local AI summary written into the meeting transcript: frontmatter
///   `local_summary_version` plus a `## Local Summary` body block with `###`
///   subsections (and a pipe-joined `local_summary_*` frontmatter fallback).
/// - inline always-on quick summary written into `auto_summary_*` frontmatter.
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
                attendees: bulletItems(section("# Attendees", in: body, headingLevel: "#"))
                    + bulletItems(section("# Participants", in: body, headingLevel: "#")),
                decisions: bulletItems(section("# Decisions", in: body, headingLevel: "#")),
                actions: bulletItems(section("# Action Items", in: body, headingLevel: "#")),
                questions: bulletItems(section("# Open Questions", in: body, headingLevel: "#"))
            )
        }

        if values["local_summary_version"] != nil {
            let block = localSummaryBlock(in: body) ?? body
            if let localSummary = assemble(
                title: cleanTitle(values["local_summary_title"]),
                attendees: inlineItems("### Attendees", in: block, fallback: nil)
                    + inlineItems("### Participants", in: block, fallback: values["local_summary_participants"]),
                decisions: inlineItems("### Decisions", in: block, fallback: values["local_summary_decisions"]),
                actions: inlineItems("### Action Items", in: block, fallback: values["local_summary_action_items"]),
                questions: inlineItems("### Open Questions", in: block, fallback: values["local_summary_open_questions"])
            ) {
                return localSummary
            }
        }

        if values["auto_summary_version"] != nil {
            return assemble(
                title: nil,
                attendees: [],
                decisions: frontmatterItems(values["auto_summary_decisions"]),
                actions: frontmatterItems(values["auto_summary_action_items"]),
                questions: frontmatterItems(values["auto_summary_open_questions"])
            )
        }

        return nil
    }

    // MARK: - Assembly

    private static func assemble(
        title: String?,
        attendees: [String],
        decisions: [String],
        actions: [String],
        questions: [String]
    ) -> ParsedMeetingSummary? {
        let summary = ParsedMeetingSummary(
            title: title,
            attendees: unique(attendees),
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
        let (stripped, status, due) = extractTrailingMarkers(from: text)
        // The summarizer prompts action bullets as "<Owner if named: follow-up>".
        // Treat a short leading segment before the first ": " as the owner only
        // when it reads like a name/team — a Title-Case noun phrase. Sentence
        // fragments ("Discuss the new API: ...") carry lowercase function words,
        // so we keep them as plain text instead of shredding a fake owner out.
        if let colon = stripped.range(of: ": ") {
            let owner = String(stripped[..<colon.lowerBound]).trimmingCharacters(in: .whitespaces)
            let rest = String(stripped[colon.upperBound...]).trimmingCharacters(in: .whitespaces)
            if !rest.isEmpty, looksLikeOwner(owner) {
                let normalized = placeholderOwners.contains(owner.lowercased()) ? nil : owner
                return ParsedMeetingSummary.ActionItem(owner: normalized, text: rest, status: status, due: due)
            }
        }
        return ParsedMeetingSummary.ActionItem(owner: nil, text: stripped, status: status, due: due)
    }

    /// Status tokens a bare trailing `(<token>)` marker is allowed to carry.
    /// Anything else in parentheses is treated as normal bullet text, so real
    /// parenthetical content ("call Bob (the vendor)") is never shredded. Keep
    /// the closed-state subset aligned with the MCP index's open/done rollup
    /// predicate.
    private static let bareStatusTokens: Set<String> = [
        "open", "done", "complete", "completed", "resolved", "closed",
        "cancelled", "canceled",
    ]

    /// Pull optional trailing `(due: ...)` / `(status: ...)` / `(done)` markers
    /// off an action bullet. Markers may appear in either order; the first
    /// occurrence of each kind wins. Returns the bullet with markers removed.
    private static func extractTrailingMarkers(
        from raw: String
    ) -> (text: String, status: String?, due: String?) {
        var text = raw.trimmingCharacters(in: .whitespaces)
        var status: String?
        var due: String?

        // At most one status and one due marker, so two passes bound the loop.
        for _ in 0..<2 {
            guard text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { break }
            let inner = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
                .trimmingCharacters(in: .whitespaces)
            let lowered = inner.lowercased()

            let marker: (String) -> String? = { prefix in
                guard lowered.hasPrefix(prefix) else { return nil }
                let value = String(inner.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }

            if status == nil, let value = marker("status:") {
                status = value.lowercased()
            } else if due == nil, let value = marker("due:") {
                due = value
            } else if status == nil, bareStatusTokens.contains(lowered) {
                status = lowered
            } else {
                break
            }
            text = String(text[..<open]).trimmingCharacters(in: .whitespaces)
        }

        return (text, status, due)
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

    private static func unique(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for value in values {
            let normalized = value.lowercased()
            guard seen.insert(normalized).inserted else { continue }
            result.append(value)
        }
        return result
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
