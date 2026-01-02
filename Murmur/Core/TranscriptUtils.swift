import Foundation

/// Shared utilities for transcript file manipulation
enum TranscriptUtils {

    /// Update the transcript file with a meeting summary
    /// - Parameters:
    ///   - url: The URL of the transcript markdown file
    ///   - summary: The meeting summary text
    static func updateWithSummary(at url: URL, summary: String) {
        guard var content = try? String(contentsOf: url, encoding: .utf8) else {
            print("⚠️ Could not read transcript for summary update")
            return
        }

        // Pattern to match the existing summary section
        // Matches: ## Summary\n\n<any content including placeholder>\n---
        let summaryPattern = "## Summary\\n\\n.*?\\n---"
        let newSummarySection = """
        ## Summary

        ### Meeting Summary

        \(summary)

        ---
        """

        if let regex = try? NSRegularExpression(pattern: summaryPattern, options: [.dotMatchesLineSeparators]) {
            let range = NSRange(content.startIndex..., in: content)
            let matchCount = regex.numberOfMatches(in: content, options: [], range: range)

            if matchCount == 0 {
                print("⚠️ Summary section pattern not found in transcript")
                return
            }

            content = regex.stringByReplacingMatches(in: content, options: [], range: range, withTemplate: newSummarySection)

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                print("✅ Updated transcript with meeting summary")
            } catch {
                print("⚠️ Failed to write summary update: \(error.localizedDescription)")
            }
        } else {
            print("⚠️ Failed to create summary regex")
        }
    }

    /// Rename the transcript file with a descriptive title
    /// - Parameters:
    ///   - url: The current URL of the transcript file
    ///   - title: The meeting title
    /// - Returns: The new URL if renamed, or the original URL if rename failed
    @discardableResult
    static func renameWithTitle(at url: URL, title: String) -> URL {
        let sanitized = title
            .replacingOccurrences(of: " ", with: "_")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-")).inverted)
            .joined()
            .prefix(50)

        guard !sanitized.isEmpty else {
            print("⚠️ Title too short or empty, keeping original filename")
            return url
        }

        // Extract date from original filename (e.g., "Call_2025-12-27_15-01-35.md" -> "2025-12-27")
        let originalFilename = url.deletingPathExtension().lastPathComponent
        let components = originalFilename.components(separatedBy: "_")
        let dateString: String
        if components.count >= 2 {
            dateString = components[1]
        } else {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            dateString = formatter.string(from: Date())
        }

        let newFilename = "\(sanitized)_\(dateString).md"
        let newURL = url.deletingLastPathComponent().appendingPathComponent(newFilename)

        if FileManager.default.fileExists(atPath: newURL.path) {
            print("⚠️ File with title already exists, keeping original filename")
            return url
        }

        do {
            try FileManager.default.moveItem(at: url, to: newURL)
            print("✅ Renamed transcript to: \(newFilename)")
            return newURL
        } catch {
            print("⚠️ Failed to rename transcript: \(error.localizedDescription)")
            return url
        }
    }
}
