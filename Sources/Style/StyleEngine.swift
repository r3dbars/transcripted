// StyleEngine.swift
// Manages style.md — the single file that teaches Haiku how the user writes

import Foundation
import SwiftUI

@MainActor
class StyleEngine: ObservableObject {
    @Published var exampleCount = 0
    @Published var styleFileContents = ""

    private let storageDir: URL
    private let styleFileURL: URL

    private static let defaultSystemPrompt = """
        You are a writing assistant. Take the user's rough spoken text and rewrite it as a clear, \
        well-structured message. Preserve the original meaning, intent, and tone. Don't add \
        information that wasn't in the original. Keep it concise and natural-sounding.
        """

    private static let styleAnalysisPrompt = """
        Analyze these accepted writing samples from a single person. Write a 2-3 sentence description of \
        their writing style. Focus on: tone (formal/casual), sentence length, greeting patterns, \
        closing patterns, punctuation habits, and vocabulary preferences. Be specific and concise. \
        Write in second person ("You write...").
        """

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        storageDir = appSupport.appendingPathComponent("Draft", isDirectory: true)
        styleFileURL = storageDir.appendingPathComponent("style.md")

        // Create directory if needed
        try? FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)

        // Load existing file
        loadStyleFile()
    }

    // MARK: - Public Interface

    /// Build system prompt — includes only the Style Summary (not all examples)
    func buildSystemPrompt() -> String {
        let summary = extractStyleSummary()
        guard !summary.isEmpty else {
            return Self.defaultSystemPrompt
        }

        return """
            You are a writing assistant adapting to the user's personal writing style.

            \(summary)

            Take the user's rough text and rewrite it matching the style described above. \
            Preserve the original meaning and intent. Don't add information that wasn't in the original.
            """
    }

    /// Extract just the Style Summary section from style.md
    private func extractStyleSummary() -> String {
        guard let summaryStart = styleFileContents.range(of: "## Style Summary\n") else { return "" }
        let afterSummary = styleFileContents[summaryStart.upperBound...]
        // Summary ends at the next "##" section or end of file
        if let nextSection = afterSummary.range(of: "\n##") {
            let summary = String(afterSummary[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            // Don't return the placeholder text
            return summary == "(Will be generated after 5 examples)" ? "" : summary
        }
        let summary = String(afterSummary).trimmingCharacters(in: .whitespacesAndNewlines)
        return summary == "(Will be generated after 5 examples)" ? "" : summary
    }

    /// Record an accepted example (called on Copy or Paste-to-last-app)
    func recordExample(acceptedMessage: String) {
        exampleCount += 1
        let exampleBlock = """

            ### Example \(exampleCount)
            \(acceptedMessage.trimmingCharacters(in: .whitespacesAndNewlines))
            """

        if styleFileContents.isEmpty {
            // First example — create the file structure
            styleFileContents = """
                # Writing Style Profile

                ## Style Summary
                (Will be generated after 5 examples)

                ## Accepted Examples
                \(exampleBlock)
                """
        } else {
            // Append to existing file
            styleFileContents += "\n" + exampleBlock
        }

        saveStyleFile()
    }

    /// Regenerate the Style Summary section using Haiku
    func regenerateStyleSummary(apiKey: String) async {
        // Extract just the examples section for analysis
        let examples = extractExamplesText()
        guard !examples.isEmpty else { return }

        do {
            let analysis = try await AnthropicAPI.draft(
                rawText: examples,
                apiKey: apiKey,
                systemPrompt: Self.styleAnalysisPrompt
            )

            // Replace the Style Summary section
            if let summaryRange = styleFileContents.range(of: "## Style Summary\n"),
               let examplesRange = styleFileContents.range(of: "\n## Accepted Examples") {
                let replacement = "## Style Summary\n" + analysis + "\n"
                styleFileContents.replaceSubrange(summaryRange.lowerBound..<examplesRange.lowerBound, with: replacement)
                saveStyleFile()
            }
        } catch {
            print("⚠️ Style summary regeneration failed: \(error)")
        }
    }

    // MARK: - File I/O

    private func loadStyleFile() {
        if FileManager.default.fileExists(atPath: styleFileURL.path) {
            styleFileContents = (try? String(contentsOf: styleFileURL, encoding: .utf8)) ?? ""
            // Count examples by counting "### Example" occurrences
            exampleCount = styleFileContents.components(separatedBy: "### Example").count - 1
        }
    }

    private func saveStyleFile() {
        try? styleFileContents.write(to: styleFileURL, atomically: true, encoding: .utf8)
    }

    private func extractExamplesText() -> String {
        guard let range = styleFileContents.range(of: "## Accepted Examples") else { return "" }
        return String(styleFileContents[range.lowerBound...])
    }
}
