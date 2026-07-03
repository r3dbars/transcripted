import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Writes the always-on cheap extraction (`MeetingQuickSummaryExtractor`) into a
/// saved meeting transcript's YAML frontmatter, under a dedicated
/// `auto_summary_*` namespace.
///
/// Why a separate namespace instead of the heavy summarizer's `local_summary_*`
/// keys: the heavy path's keys also drive Home UI gating (the inline summary
/// card and the "Run AI summary" affordance key off `local_summary_version`).
/// Reusing them would make the cheap heuristic masquerade as the AI summary and
/// hide the upgrade affordance. Keeping a parallel `auto_summary_*` set means:
///
/// - the index (Moat #1) gets the same logical fields for 100% of meetings,
/// - the heavy summarizer stays the high-quality path and overwrites nothing,
/// - existing Home/Settings UI is untouched.
///
/// Field shape for the indexer (Moat #1) — value format mirrors
/// `local_summary_*` exactly (bullet lines flattened with " | "):
///
/// - `auto_summary_version`            ("1")
/// - `auto_summary_generated_at`       (ISO8601)
/// - `auto_summary_method`             ("heuristic-v1")
/// - `auto_summary_participants`
/// - `auto_summary`                    (summary)
/// - `auto_summary_decisions`
/// - `auto_summary_action_items`
/// - `auto_summary_open_questions`
/// - `auto_summary_risks_or_followups`
/// - `auto_summary_accuracy_notes`
///
/// Index precedence: prefer `local_summary_*` when present (heavy, higher
/// quality), else fall back to `auto_summary_*`.
enum MeetingQuickSummaryWriter {
    static let version = "1"
    static let method = "heuristic-v1"

    static let managedFrontmatterKeys: Set<String> = [
        "auto_summary_version",
        "auto_summary_generated_at",
        "auto_summary_method",
        "auto_summary_participants",
        "auto_summary",
        "auto_summary_decisions",
        "auto_summary_action_items",
        "auto_summary_open_questions",
        "auto_summary_risks_or_followups",
        "auto_summary_accuracy_notes",
    ]

    /// Read a saved meeting transcript, extract baseline fields, and persist them
    /// into the `auto_summary_*` frontmatter. No-op (returns false) when the file
    /// is not a meeting, already carries an `auto_summary_version`, or nothing
    /// changes. Frontmatter-only: the transcript body is preserved verbatim.
    @discardableResult
    static func ensureQuickSummary(
        at url: URL,
        fileManager: FileManager = .default,
        generatedAt: Date = Date()
    ) -> Bool {
        guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return false }
        guard let updated = markdown(byApplyingQuickSummaryTo: raw, generatedAt: generatedAt) else {
            return false
        }
        guard updated != raw else { return false }
        do {
            try updated.write(to: url, atomically: true, encoding: .utf8)
            fileManager.restrictFileToOwnerOnly(at: url)
            return true
        } catch {
            return false
        }
    }

    /// Pure transform used by `ensureQuickSummary` and tests. Returns the rewritten
    /// markdown, or nil when extraction should be skipped (not a meeting, already
    /// processed, or no frontmatter).
    static func markdown(
        byApplyingQuickSummaryTo raw: String,
        generatedAt: Date = Date()
    ) -> String? {
        guard let document = TranscriptFrontmatter.document(in: raw) else { return nil }
        guard document.values["capture_type"] == "meeting" else { return nil }
        // Idempotent: never re-run once a version has been written. Restyle and
        // renames can re-touch the file; the first save owns the extraction.
        guard document.values["auto_summary_version"] == nil else { return nil }

        let transcript = LocalMeetingTranscriptExtractor.transcriptText(from: raw)
        let sections = MeetingQuickSummaryExtractor.sections(transcript: transcript)

        let retained = document.lines.filter { line in
            guard let key = frontmatterKey(in: line) else { return true }
            return !managedFrontmatterKeys.contains(key)
        }
        let generatedAtString = ISO8601DateFormatter().string(from: generatedAt)
        let appended = [
            "auto_summary_version: \"\(version)\"",
            "auto_summary_generated_at: \"\(generatedAtString)\"",
            yamlLine("auto_summary_method", method),
            yamlLine("auto_summary_participants", flatten(sections.participants)),
            yamlLine("auto_summary", flatten(sections.summary)),
            yamlLine("auto_summary_decisions", flatten(sections.decisions)),
            yamlLine("auto_summary_action_items", flatten(sections.actionItems)),
            yamlLine("auto_summary_open_questions", flatten(sections.openQuestions)),
            yamlLine("auto_summary_risks_or_followups", flatten(sections.risksOrFollowUps)),
            yamlLine("auto_summary_accuracy_notes", flatten(sections.accuracyNotes)),
        ]

        return "---\n\((retained + appended).joined(separator: "\n"))\n---\n\(document.body)"
    }

    // MARK: - Helpers (mirror LocalMeetingSummaryMarkdownUpdater formatting)

    private static func frontmatterKey(in line: String) -> String? {
        guard line.first?.isWhitespace != true else { return nil }
        return line.split(separator: ":", maxSplits: 1).first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func yamlLine(_ key: String, _ value: String) -> String {
        "\(key): \"\(yamlValue(value))\""
    }

    private static func yamlValue(_ raw: String) -> String {
        raw.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func flatten(_ raw: String) -> String {
        let flattened = raw.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " | ")
        return String(flattened.prefix(1_200))
    }
}
