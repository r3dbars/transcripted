// StyleUtils.swift
// Pure utility functions extracted from StyleEngine for testability.
// All methods are static and take explicit parameters — no @MainActor, no ObservableObject.

import Foundation

enum StyleUtils {

    // MARK: - Refinement Scheduling

    /// Determine whether refinement should run now based on example count and edit distance trends.
    /// - Parameters:
    ///   - exampleCount: Total number of training pair examples recorded
    ///   - styleFileContents: Full contents of style.md (used to extract edit distances)
    static func shouldRefineNow(exampleCount: Int, styleFileContents: String) -> Bool {
        guard exampleCount > 0 else { return false }

        if exampleCount <= 20 {
            // Early phase: refine every 3 examples (learning fast)
            return exampleCount % 3 == 0
        }

        // Mature phase: check if profile has stabilized
        let recentAvg = averageRecentEditDistance(last: TranscriptedConstants.refinementDistanceWindow, styleFileContents: styleFileContents)

        if recentAvg < TranscriptedConstants.editDistanceStabilizedThreshold {
            // Profile is working well — refine every 10
            return exampleCount % 10 == 0
        } else {
            // Still learning — refine every 5
            return exampleCount % 5 == 0
        }
    }

    /// Average edit distance of the N most recent examples (0 = AI nails it, 1 = completely rewritten).
    static func averageRecentEditDistance(last n: Int, styleFileContents: String) -> Double {
        let distances = extractRecentEditDistances(last: n, styleFileContents: styleFileContents)
        guard !distances.isEmpty else { return 1.0 }
        return distances.reduce(0, +) / Double(distances.count)
    }

    /// Parse EDIT_DISTANCE values from the last N examples in style.md content.
    static func extractRecentEditDistances(last n: Int, styleFileContents: String) -> [Double] {
        let blocks = styleFileContents.components(separatedBy: "### Example")
        // First element is everything before examples — skip it
        let exampleBlocks = Array(blocks.dropFirst().suffix(n))
        return exampleBlocks.compactMap { block in
            guard let range = block.range(of: "EDIT_DISTANCE: ") else { return nil }
            let afterTag = block[range.upperBound...]
            let line = afterTag.prefix(while: { $0 != "\n" })
            return Double(line)
        }
    }

    // MARK: - Word Edit Distance

    /// Simple word-overlap edit distance (0 = identical, 1 = completely different).
    static func wordEditDistance(_ a: String, _ b: String) -> Double {
        let wordsA = Set(a.lowercased().split(whereSeparator: \.isWhitespace))
        let wordsB = Set(b.lowercased().split(whereSeparator: \.isWhitespace))
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 0 }
        let common = wordsA.intersection(wordsB).count
        let total = max(wordsA.count, wordsB.count)
        return 1.0 - (Double(common) / Double(total))
    }

    // MARK: - Text Extraction

    /// Minimum USER_SENT length for an example to be included in refinement.
    /// Short examples (< 20 chars) are likely testing/keyboard mashing and poison the style profile.
    private static let minimumUserSentLength = 20

    /// Extract only the last N quality examples as text for recency-weighted refinement.
    /// Filters out examples where USER_SENT is too short (testing/garbage data).
    static func extractRecentExamplesText(last n: Int, styleFileContents: String) -> String {
        let blocks = styleFileContents.components(separatedBy: "### Example")
        // First element is everything before examples — skip it
        let allBlocks = Array(blocks.dropFirst())

        // Filter out low-quality examples (short USER_SENT = likely testing)
        let qualityBlocks = allBlocks.filter { block in
            guard let userSentRange = block.range(of: "USER_SENT:\n") else { return false }
            let afterUserSent = String(block[userSentRange.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return afterUserSent.count >= minimumUserSentLength
        }

        let recentBlocks = qualityBlocks.suffix(n)
        guard !recentBlocks.isEmpty else { return "" }
        return recentBlocks.map { "### Example" + $0 }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
