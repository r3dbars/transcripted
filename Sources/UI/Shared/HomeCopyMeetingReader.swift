import Foundation

/// What "Copy for agent" on a Home meeting row found on disk.
enum HomeCopyMeetingReadResult: Equatable {
    case missingFile
    case readFailure
    /// `usedBundle` is true when `text` is the portable meeting bundle rather than the raw Markdown.
    case success(text: String, usedBundle: Bool)
}

/// Decides what a meeting row's Copy for agent puts on the clipboard: the portable
/// meeting bundle when it can be built, the raw Markdown when it can't.
enum HomeCopyMeetingReader {
    static func read(title: String, date: Date, transcriptURL: URL) -> HomeCopyMeetingReadResult {
        guard let resolved = OwnFileResolver.resolveExistingFile(candidateURLs: [transcriptURL]) else {
            return .missingFile
        }
        if let bundle = AgentConnectionGuide.portableMeetingBundle(
            title: title,
            date: date,
            transcriptURL: resolved
        ) {
            return .success(text: bundle, usedBundle: true)
        } else if let raw = try? String(contentsOf: resolved, encoding: .utf8) {
            return .success(text: raw, usedBundle: false)
        } else {
            return .readFailure
        }
    }
}
