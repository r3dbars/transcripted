import Foundation

/// Rewrites an already-saved transcript file in place without making it look new.
///
/// Speaker renames, merges, discards, meeting renames, summaries and dictionary fixes
/// all rewrite saved Markdown after the fact. A plain atomic write swaps in a brand-new
/// file, so Finder, Obsidian and every other tool see a fresh "Created" date, and a
/// write whose bytes didn't change still bumps "Modified". A user reported dozens of
/// old meetings jumping to today's date with their text intact.
///
/// This helper:
/// - skips the write entirely when the file already holds exactly these bytes, so no
///   date moves at all
/// - otherwise writes atomically (same crash safety as before) and puts the original
///   creation date back
///
/// The modification date is left to move on a real change on purpose: the MCP index,
/// Home's capture cache and the dictionary-fix scan all use it to notice edits.
public enum TranscriptFileRewrite {
    public enum Outcome: Equatable, Sendable {
        case unchanged
        case written
    }

    @discardableResult
    public static func write(
        _ content: String,
        to url: URL,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        try write(Data(content.utf8), to: url, fileManager: fileManager)
    }

    @discardableResult
    public static func write(
        _ data: Data,
        to url: URL,
        fileManager: FileManager = .default
    ) throws -> Outcome {
        if let existing = try? Data(contentsOf: url), existing == data {
            return .unchanged
        }

        let creationDate = (try? fileManager.attributesOfItem(atPath: url.path))?[.creationDate] as? Date
        try data.write(to: url, options: .atomic)
        if let creationDate {
            try? fileManager.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
        }
        return .written
    }
}
