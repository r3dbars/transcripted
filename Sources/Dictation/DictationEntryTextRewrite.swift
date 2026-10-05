// DictationEntryTextRewrite.swift
// Replaces one saved dictation's text in its day file (Transcribe again).

import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Rewrites one entry of a `Dictations_YYYY-MM-DD.md` day file in place.
///
/// Only the target section changes: its heading title, `Words:`,
/// `Characters:`, and the body. `Entry ID:`, `Captured:`, the source app,
/// `Delivery:`, and `Audio:` stay byte for byte, and so does every other
/// section and the frontmatter. The grammar is in docs/capture-format.md.
enum DictationEntryTextRewrite {
    enum RewriteError: Error, Equatable {
        /// The day file couldn't be read.
        case unreadable
        /// No section in the file carries this Entry ID.
        case entryNotFound
        /// The new text is empty; the old text is kept.
        case emptyText
    }

    struct Result: Equatable {
        let content: String
        let title: String
        let wordCount: Int
        let characterCount: Int
    }

    /// The day file with `entryID`'s text replaced, or `entryNotFound`.
    /// Pure: no disk access.
    static func rewrite(
        dayFile content: String,
        entryID: String,
        newText: String,
        createdAt: Date
    ) throws -> Result {
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw RewriteError.emptyText }

        var lines = content.components(separatedBy: "\n")
        let headings = lines.indices.filter { DictationTranscriptStore.isEntryHeading(lines[$0]) }
        for (offset, start) in headings.enumerated() {
            let end = offset + 1 < headings.count ? headings[offset + 1] : lines.count
            let layout = SectionLayout(lines: Array(lines[start..<end]))
            guard layout.entryID == entryID else { continue }

            let title = DictationTranscriptWriter.buildTitle(from: text, createdAt: createdAt)
            let wordCount = text.split(whereSeparator: \.isWhitespace).count
            let characterCount = text.count
            var section = Array(lines[start..<end])
            section[0] = rewrittenHeading(section[0], title: title)
            if let index = layout.wordsIndex {
                section[index] = "Words: \(wordCount)"
            }
            if let index = layout.charactersIndex {
                section[index] = "Characters: \(characterCount)"
            }
            var replacement = Array(section[0..<layout.bodyStart])
            if let last = replacement.last, !last.trimmingCharacters(in: .whitespaces).isEmpty {
                replacement.append("")
            }
            replacement.append(contentsOf: text.components(separatedBy: "\n"))
            replacement.append(contentsOf: section[layout.bodyEnd...])
            lines.replaceSubrange(start..<end, with: replacement)
            return Result(
                content: lines.joined(separator: "\n"),
                title: title,
                wordCount: wordCount,
                characterCount: characterCount
            )
        }
        throw RewriteError.entryNotFound
    }

    /// `## 5:30 AM - old title` → `## 5:30 AM - new title`.
    private static func rewrittenHeading(_ heading: String, title: String) -> String {
        let raw = String(heading.dropFirst(3))
        let time = raw.components(separatedBy: " - ").first ?? raw
        return "## \(time) - \(title.replacingOccurrences(of: "\n", with: " "))"
    }

    /// Where the metadata and body sit inside one section's lines, read the
    /// same way `DictationTranscriptStore.parseEntry` reads them: metadata
    /// lines after the heading, a blank line, then the body.
    private struct SectionLayout {
        var entryID: String?
        var wordsIndex: Int?
        var charactersIndex: Int?
        /// First body line (or `lines.count` when there's no body).
        var bodyStart: Int
        /// One past the last non-blank body line; trailing blank lines are
        /// the gap before the next section and stay as they are.
        var bodyEnd: Int

        private static let metadataPrefixes = [
            "Entry ID:", "Captured:", "Timestamp:", "Source app:", "Bundle ID:",
            "Delivery:", "Words:", "Characters:", "Audio:",
        ]

        init(lines: [String]) {
            var sawMetadata = false
            var start: Int?
            for index in lines.indices.dropFirst() {
                let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty {
                    if sawMetadata {
                        start = index + 1
                        break
                    }
                    continue
                }
                if Self.metadataPrefixes.contains(where: { trimmed.hasPrefix($0) }) {
                    sawMetadata = true
                    if trimmed.hasPrefix("Entry ID:") {
                        entryID = String(trimmed.dropFirst("Entry ID:".count))
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
                    } else if trimmed.hasPrefix("Words:") {
                        wordsIndex = index
                    } else if trimmed.hasPrefix("Characters:") {
                        charactersIndex = index
                    }
                } else if !sawMetadata {
                    start = index
                    break
                }
            }
            let bodyStart = start ?? lines.count
            var bodyEnd = lines.count
            while bodyEnd > bodyStart, lines[bodyEnd - 1].trimmingCharacters(in: .whitespaces).isEmpty {
                bodyEnd -= 1
            }
            self.bodyStart = bodyStart
            self.bodyEnd = bodyEnd
        }
    }
}

extension DictationTranscriptStore {
    /// Replaces one saved dictation's text (Transcribe again), matched by its
    /// Entry ID, under the day-file lock. Throws
    /// `DictationEntryTextRewrite.RewriteError` when the file can't be read,
    /// the entry is gone, or the new text is empty; the file is untouched then.
    @discardableResult
    static func replaceEntryText(
        entryID: String,
        in url: URL,
        with newText: String,
        createdAt: Date
    ) throws -> DictationEntryTextRewrite.Result {
        let result: DictationEntryTextRewrite.Result = try DictationTranscriptMutationLock.withLock {
            guard let content = try? String(contentsOf: url, encoding: .utf8) else {
                throw DictationEntryTextRewrite.RewriteError.unreadable
            }
            let result = try DictationEntryTextRewrite.rewrite(
                dayFile: content,
                entryID: entryID,
                newText: newText,
                createdAt: createdAt
            )
            try TranscriptFileRewrite.write(result.content, to: url)
            FileManager.default.restrictFileToOwnerOnly(at: url)
            return result
        }
        NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: url)
        return result
    }
}
