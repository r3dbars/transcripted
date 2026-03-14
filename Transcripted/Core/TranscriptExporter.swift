import Foundation
import AppKit
import UniformTypeIdentifiers

/// Exports transcripts to Markdown (.md) or plain text (.txt) via NSSavePanel.
@available(macOS 14.0, *)
enum TranscriptExporter {

    enum Format { case markdown, plainText }

    /// Opens a save panel and writes the transcript to the user-chosen location.
    /// Must be called on the main thread (NSSavePanel.runModal() is synchronous).
    @MainActor
    static func export(summary: TranscriptSummary, lines: [TranscriptLine], format: Format) {
        let panel = NSSavePanel()
        if format == .plainText {
            panel.allowedContentTypes = [.plainText]
        }
        // No content type restriction for markdown — the .md extension in the filename is enough
        panel.nameFieldStringValue = defaultFilename(for: summary, format: format)
        panel.message = format == .markdown
            ? "Export transcript as Markdown"
            : "Export transcript as plain text"
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let content = format == .markdown
            ? markdownContent(from: lines, summary: summary)
            : plainTextContent(from: lines, summary: summary)

        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
            AppLogger.pipeline.info("Transcript exported", ["format": format == .markdown ? "md" : "txt", "path": url.lastPathComponent])
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            AppLogger.pipeline.error("Transcript export failed", ["error": "\(error)"])
        }
    }

    // MARK: - Markdown

    static func markdownContent(from lines: [TranscriptLine], summary: TranscriptSummary) -> String {
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        let dateStr = df.string(from: summary.date)

        var parts: [String] = []
        parts.append("# \(summary.title)")
        parts.append("")
        parts.append("**Date:** \(dateStr)  ")
        if !summary.duration.isEmpty {
            parts.append("**Duration:** \(summary.duration)  ")
        }
        if summary.speakerCount > 0 {
            parts.append("**Speakers:** \(summary.speakerCount)  ")
        }
        parts.append("")
        parts.append("---")
        parts.append("")

        for line in lines {
            if let ts = line.timestamp, let speaker = line.speaker {
                let displaySpeaker = speakerDisplayName(speaker)
                parts.append("**[\(ts)] \(displaySpeaker):** \(line.text)")
            } else {
                parts.append(line.text)
            }
        }

        parts.append("")
        parts.append("---")
        parts.append("*Exported from Transcripted*")
        return parts.joined(separator: "\n")
    }

    // MARK: - Plain Text

    static func plainTextContent(from lines: [TranscriptLine], summary: TranscriptSummary) -> String {
        let df = DateFormatter()
        df.dateStyle = .full
        df.timeStyle = .short
        let dateStr = df.string(from: summary.date)

        var parts: [String] = []
        parts.append(summary.title)
        parts.append(dateStr)
        if !summary.duration.isEmpty {
            parts.append("Duration: \(summary.duration)")
        }
        parts.append("")
        parts.append(String(repeating: "-", count: 40))
        parts.append("")

        for line in lines {
            if let ts = line.timestamp, let speaker = line.speaker {
                let displaySpeaker = speakerDisplayName(speaker)
                parts.append("[\(ts)] \(displaySpeaker): \(line.text)")
            } else {
                parts.append(line.text)
            }
        }

        return parts.joined(separator: "\n")
    }

    // MARK: - Helpers

    /// "Mic/You" → "You", "System/Speaker 1" → "Speaker 1"
    private static func speakerDisplayName(_ raw: String) -> String {
        let parts = raw.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : raw
    }

    static func defaultFilename(for summary: TranscriptSummary, format: Format) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        let dateStr = df.string(from: summary.date)

        // Truncate title to ~30 chars, replace path-unsafe chars
        let safeTitle = summary.title
            .prefix(30)
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let ext = format == .markdown ? "md" : "txt"
        return "\(dateStr) \(safeTitle).\(ext)"
    }
}
