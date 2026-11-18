import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Writes the on-device title, line and summary into a saved meeting's
/// frontmatter (`ai_*` keys; see docs/capture-format.md). Same safety as
/// `MeetingQuickSummaryWriter`: one read-modify-write under the transcript
/// serializer, an atomic rewrite, idempotent, and the body is never touched.
/// The file is never renamed, and `title:` is never changed.
enum MeetingTitlesFrontmatterWriter {
    static let version = "1"
    static let model = "gemma-4-e2b-it-q4km"

    enum Outcome: Equatable {
        case written
        /// Not a meeting, no frontmatter, already done at this version, or
        /// nothing to write.
        case skipped
        case failed
    }

    /// True when the file already carries this version's keys.
    static func isCurrent(values: [String: String]) -> Bool {
        values[MeetingTitlesKeys.version] == version
    }

    /// `replaceableTitle` is the app-made `title:` the model's title may
    /// stand in for. `ai_title` is written only when the file's `title:`
    /// still equals it, so a rename (before or after) always wins.
    static func apply(
        _ label: MeetingTitlesLabel,
        replaceableTitle: String?,
        at url: URL,
        generatedAt: Date = Date(),
        fileManager: FileManager = .default,
        shouldWrite: () -> Bool = { true }
    ) -> Outcome {
        do {
            return try MeetingTranscriptFileUpdateSerializer.sync(protecting: [url]) {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return .failed }
                guard let updated = markdown(
                    byApplying: label,
                    replaceableTitle: replaceableTitle,
                    to: raw,
                    generatedAt: generatedAt
                ), updated != raw else { return .skipped }
                // Checked inside the serialized section, right before the write.
                guard shouldWrite() else { return .skipped }
                try TranscriptFileRewrite.write(updated, to: url)
                fileManager.restrictFileToOwnerOnly(at: url)
                return .written
            }
        } catch {
            return .failed
        }
    }

    /// Adds `title_set_by_user: true` (see `MeetingTitlesTitleOwnership`).
    /// Meetings only; the body and every other line stay as they are.
    @discardableResult
    static func markTitleSetByUser(
        at url: URL,
        fileManager: FileManager = .default,
        shouldWrite: () -> Bool = { true }
    ) -> Outcome {
        do {
            return try MeetingTranscriptFileUpdateSerializer.sync(protecting: [url]) {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return .failed }
                guard TranscriptFrontmatter.document(in: raw)?.values["capture_type"] == "meeting" else { return .skipped }
                let updated = MeetingTitlesKeys.markingTitleSetByUser(raw)
                guard updated != raw, shouldWrite() else { return .skipped }
                try TranscriptFileRewrite.write(updated, to: url)
                fileManager.restrictFileToOwnerOnly(at: url)
                return .written
            }
        } catch {
            return .failed
        }
    }

    /// Why a meeting has `ai_summary_version` but no summary. Values carry no
    /// content.
    enum NoSummaryStatus: String, Sendable {
        case tooShort = "too_short"
        case noUsableReply = "no_usable_reply"
    }

    /// Records that this version had nothing to write, so the meeting isn't
    /// read or sent to the model again until the version changes.
    @discardableResult
    static func recordNoSummary(
        _ status: NoSummaryStatus,
        at url: URL,
        generatedAt: Date = Date(),
        fileManager: FileManager = .default,
        shouldWrite: () -> Bool = { true }
    ) -> Outcome {
        do {
            return try MeetingTranscriptFileUpdateSerializer.sync(protecting: [url]) {
                guard let raw = try? String(contentsOf: url, encoding: .utf8) else { return .failed }
                guard let updated = markdown(recordingNoSummary: status, to: raw, generatedAt: generatedAt),
                      updated != raw else { return .skipped }
                guard shouldWrite() else { return .skipped }
                try TranscriptFileRewrite.write(updated, to: url)
                fileManager.restrictFileToOwnerOnly(at: url)
                return .written
            }
        } catch {
            return .failed
        }
    }

    static func markdown(recordingNoSummary status: NoSummaryStatus, to raw: String, generatedAt: Date = Date()) -> String? {
        guard let document = TranscriptFrontmatter.document(in: raw),
              document.values["capture_type"] == "meeting",
              !isCurrent(values: document.values) else { return nil }
        let retained = document.lines.filter { line in
            guard let key = frontmatterKey(in: line) else { return true }
            return !MeetingTitlesKeys.all.contains(key)
        }
        let appended = [
            yamlLine(MeetingTitlesKeys.status, status.rawValue),
            yamlLine(MeetingTitlesKeys.model, model),
            yamlLine(MeetingTitlesKeys.version, version),
            yamlLine(MeetingTitlesKeys.generatedAt, DateFormattingHelper.formatISO8601(generatedAt)),
        ]
        return "---\n\((retained + appended).joined(separator: "\n"))\n---\n\(document.body)"
    }

    /// Pure transform. Nil when nothing should change.
    static func markdown(
        byApplying label: MeetingTitlesLabel,
        replaceableTitle: String?,
        to raw: String,
        generatedAt: Date = Date()
    ) -> String? {
        guard !label.isEmpty,
              let document = TranscriptFrontmatter.document(in: raw),
              document.values["capture_type"] == "meeting",
              !isCurrent(values: document.values) else { return nil }

        let savedTitle = document.values["title"].map(MeetingTitlesKeys.normalizedTitle)
        let mayReplaceTitle = document.values[MeetingTitlesKeys.titleSetByUser] != "true"
            && savedTitle != nil
            && !(savedTitle ?? "").isEmpty
            && replaceableTitle.map(MeetingTitlesKeys.normalizedTitle) == savedTitle

        let retained = document.lines.filter { line in
            guard let key = frontmatterKey(in: line) else { return true }
            return !MeetingTitlesKeys.all.contains(key)
        }
        var appended: [String] = []
        if let title = label.title, mayReplaceTitle, let savedTitle {
            appended.append(yamlLine(MeetingTitlesKeys.title, title))
            appended.append(yamlLine(MeetingTitlesKeys.titleReplaces, savedTitle))
        }
        if let line = label.line { appended.append(yamlLine(MeetingTitlesKeys.line, line)) }
        if let summary = label.summary { appended.append(yamlLine(MeetingTitlesKeys.summary, summary)) }
        guard !appended.isEmpty else { return nil }
        appended += [
            yamlLine(MeetingTitlesKeys.model, model),
            yamlLine(MeetingTitlesKeys.version, version),
            yamlLine(MeetingTitlesKeys.generatedAt, DateFormattingHelper.formatISO8601(generatedAt)),
        ]
        return "---\n\((retained + appended).joined(separator: "\n"))\n---\n\(document.body)"
    }

    private static func frontmatterKey(in line: String) -> String? {
        guard line.first?.isWhitespace != true else { return nil }
        return line.split(separator: ":", maxSplits: 1).first.map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func yamlLine(_ key: String, _ value: String) -> String {
        let flat = value.split(whereSeparator: \.isNewline).joined(separator: " ")
        return "\(key): \(TranscriptFrontmatter.quotedYAMLScalar(flat))"
    }
}
