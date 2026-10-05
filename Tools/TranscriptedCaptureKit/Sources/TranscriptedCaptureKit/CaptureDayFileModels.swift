// CaptureDayFileModels.swift
// Parsed shapes of the dictation and writing day files. The parsing itself is
// in CaptureMarkdownParser.swift; the grammar is in docs/capture-format.md.

import Foundation

/// Parsed dictation day file.
public struct ParsedDictationDayCapture {
    public struct Entry {
        public let id: String
        public let createdAt: String
        public let title: String
        public let text: String
        public let sourceAppName: String
        public let sourceAppBundleId: String?
        public let delivery: String
        public let wordCount: Int
        public let characterCount: Int
        /// The `Audio:` line: kept audio relative to the dictations folder
        /// (`audio/<uuid>.m4a`). Nil when absent. The file may have aged out,
        /// so callers must tolerate it missing.
        public let audioRelativePath: String?
    }

    public let captureType: String
    public let date: String
    /// `format_version` frontmatter when present. Absent means the day file
    /// predates capture-format versioning and parses as version 1.
    public let formatVersion: Int?
    public let markdownFilename: String
    public let entryCount: Int
    public let wordCount: Int
    /// Sorted ascending by `createdAt`.
    public let entries: [Entry]
}

/// Parsed writing day file (`<capture-library>/writing/Writing_<YYYY-MM-dd>.md`).
/// Same day-file shape as dictations, with `Accepted words:` in place of
/// `Delivery:`. See docs/capture-format.md and the phase 3 format contract.
public struct ParsedWritingDayCapture {
    public struct Entry {
        public let id: String
        /// `Captured:` value: ISO 8601 UTC of the entry's first keystroke.
        public let createdAt: String
        public let title: String
        public let text: String
        public let sourceAppName: String
        /// Nil when the `Bundle ID:` line is absent (the writer omits it when unknown).
        public let sourceAppBundleId: String?
        public let wordCount: Int
        public let characterCount: Int
        /// Words that came from accepted suggestions. 0 when the line is absent.
        public let acceptedWordCount: Int
    }

    public let captureType: String
    public let date: String
    /// `format_version` frontmatter when present. Absent means version 1.
    public let formatVersion: Int?
    public let markdownFilename: String
    public let entryCount: Int
    public let wordCount: Int
    public let acceptedWordCount: Int
    /// Sorted ascending by `createdAt`.
    public let entries: [Entry]
}
