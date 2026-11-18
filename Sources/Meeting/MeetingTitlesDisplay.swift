import Foundation

/// The on-device title, line and summary read back from a saved meeting's
/// frontmatter, and which title to show.
///
/// Precedence: a title the person set with Rename wins, then `ai_title`,
/// then the app's own title. Rename marks the file `title_set_by_user: true`,
/// and `ai_title_replaces` records the exact `title:` the model's title stood
/// in for, so once `title:` is anything else the saved title shows again.
struct MeetingTitlesFields: Equatable, Sendable, Codable {
    var aiTitle: String?
    var aiTitleReplaces: String?
    var line: String?
    var summary: String?
    var titleSetByUser = false

    static let empty = MeetingTitlesFields()

    init(
        aiTitle: String? = nil,
        aiTitleReplaces: String? = nil,
        line: String? = nil,
        summary: String? = nil,
        titleSetByUser: Bool = false
    ) {
        self.aiTitle = aiTitle
        self.aiTitleReplaces = aiTitleReplaces
        self.line = line
        self.summary = summary
        self.titleSetByUser = titleSetByUser
    }

    /// `values` are `TranscriptFrontmatter` values (already unquoted).
    init(frontmatterValues values: [String: String]) {
        aiTitle = Self.nonEmpty(values[MeetingTitlesKeys.title])
        aiTitleReplaces = values[MeetingTitlesKeys.titleReplaces].map(MeetingTitlesKeys.normalizedTitle)
        line = Self.nonEmpty(values[MeetingTitlesKeys.line])
        summary = Self.nonEmpty(values[MeetingTitlesKeys.summary])
        titleSetByUser = values[MeetingTitlesKeys.titleSetByUser] == "true"
    }

    func displayTitle(savedTitle: String) -> String {
        guard !titleSetByUser, let aiTitle, let aiTitleReplaces,
              MeetingTitlesKeys.normalizedTitle(savedTitle) == aiTitleReplaces else { return savedTitle }
        return aiTitle
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

enum MeetingTitlesKeys {
    static let title = "ai_title"
    static let titleReplaces = "ai_title_replaces"
    static let line = "ai_summary_line"
    static let summary = "ai_summary"
    static let model = "ai_summary_model"
    static let version = "ai_summary_version"
    static let generatedAt = "ai_summary_generated_at"
    /// Set instead of a summary when there was nothing to write (`too_short`,
    /// `no_usable_reply`).
    static let status = "ai_summary_status"
    /// Written by Rename. Not an `ai_*` key: the model never writes it.
    static let titleSetByUser = "title_set_by_user"

    /// Every key the titles writer owns and may replace.
    static let all: Set<String> = [title, titleReplaces, line, summary, model, version, generatedAt, status]

    /// Adds `title_set_by_user: true` after the frontmatter's `title:` line
    /// (or at the end of the frontmatter) unless it is already there. Text
    /// without frontmatter comes back unchanged.
    static func markingTitleSetByUser(_ raw: String) -> String {
        var lines = raw.components(separatedBy: "\n")
        guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else { return raw }
        let frontmatter = lines[1..<close]
        if frontmatter.contains(where: { $0.hasPrefix(titleSetByUser + ":") }) {
            guard let index = frontmatter.firstIndex(where: { $0.hasPrefix(titleSetByUser + ":") }) else { return raw }
            lines[index] = "\(titleSetByUser): true"
            return lines.joined(separator: "\n")
        }
        let insertAt = frontmatter.lastIndex(where: { $0.hasPrefix("title:") }).map { $0 + 1 } ?? close
        lines.insert("\(titleSetByUser): true", at: insertAt)
        return lines.joined(separator: "\n")
    }

    /// Titles compare after collapsing whitespace, the way a heading or file
    /// name shows them.
    static func normalizedTitle(_ title: String) -> String {
        title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
