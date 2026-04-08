// DiffSummary.swift
// Pure-function utilities for word-level diff computation and edit description.
// No SwiftUI, no MainActor — testable in the pure test suite.

import Foundation

/// A single word-level diff operation.
enum DiffOp: Equatable {
    case equal(String)
    case insert(String)
    case delete(String)
    case replace(old: String, new: String)
}

/// Word-level diff computation and human-readable edit descriptions.
enum DiffSummary {

    // MARK: - Word-Level Diff

    /// Compute word-level diff operations between the original generated text
    /// and the user's edited version.
    /// Uses Swift stdlib CollectionDifference with .inferringMoves() to detect replacements.
    static func computeWordDiff(original: String, edited: String) -> [DiffOp] {
        let oldWords = tokenize(original)
        let newWords = tokenize(edited)

        guard !oldWords.isEmpty || !newWords.isEmpty else { return [] }
        if oldWords.isEmpty { return newWords.map { .insert($0) } }
        if newWords.isEmpty { return oldWords.map { .delete($0) } }

        let diff = newWords.difference(from: oldWords).inferringMoves()

        // Build lookup tables: offset → element for removals and insertions
        var removals: [Int: String] = [:]   // offset in oldWords
        var insertions: [Int: String] = [:] // offset in newWords

        for change in diff {
            switch change {
            case .remove(let offset, let element, _):
                removals[offset] = element
            case .insert(let offset, let element, _):
                insertions[offset] = element
            }
        }

        // Walk both arrays to produce a linear sequence of DiffOps
        var ops: [DiffOp] = []
        var oi = 0  // old index
        var ni = 0  // new index

        while oi < oldWords.count || ni < newWords.count {
            let isRemoved = oi < oldWords.count && removals[oi] != nil
            let isInserted = ni < newWords.count && insertions[ni] != nil

            if isRemoved && isInserted {
                // Both sides changed at this position — treat as replace
                ops.append(.replace(old: oldWords[oi], new: newWords[ni]))
                oi += 1
                ni += 1
            } else if isRemoved {
                ops.append(.delete(oldWords[oi]))
                oi += 1
            } else if isInserted {
                ops.append(.insert(newWords[ni]))
                ni += 1
            } else if oi < oldWords.count && ni < newWords.count {
                ops.append(.equal(oldWords[oi]))
                oi += 1
                ni += 1
            } else if oi < oldWords.count {
                ops.append(.delete(oldWords[oi]))
                oi += 1
            } else {
                ops.append(.insert(newWords[ni]))
                ni += 1
            }
        }

        return ops
    }

    // MARK: - Edit Description

    /// Generate a human-readable, one-line description of what the user changed.
    /// Pure heuristic — no LLM call, runs in microseconds.
    static func describeEdit(original: String, edited: String, platform: String) -> String {
        let origWords = tokenize(original)
        let editWords = tokenize(edited)

        if editWords.isEmpty { return "deleted the entire draft" }
        if origWords.isEmpty { return "wrote from scratch" }

        var notes: [String] = []

        // Word count change
        let countDelta = editWords.count - origWords.count
        let changeRatio = abs(Double(countDelta)) / Double(max(origWords.count, 1))

        if changeRatio > 0.3 {
            if countDelta < 0 {
                notes.append("shortened by \(abs(countDelta)) words")
            } else {
                notes.append("expanded by \(countDelta) words")
            }
        }

        // First sentence changed (greeting)
        let origFirst = firstSentence(original)
        let editFirst = firstSentence(edited)
        if !origFirst.isEmpty && !editFirst.isEmpty {
            let firstOverlap = wordOverlap(origFirst, editFirst)
            if firstOverlap < 0.3 {
                if editWords.count < origWords.count {
                    notes.append("removed the greeting")
                } else {
                    notes.append("changed the opening")
                }
            }
        }

        // Last sentence changed (signoff)
        let origLast = lastSentence(original)
        let editLast = lastSentence(edited)
        if !origLast.isEmpty && !editLast.isEmpty && origLast != origFirst {
            let lastOverlap = wordOverlap(origLast, editLast)
            if lastOverlap < 0.3 {
                notes.append("changed the signoff")
            }
        }

        // Overall edit distance
        if notes.isEmpty {
            let distance = StyleUtils.wordEditDistance(original, edited)
            if distance > 0.5 {
                notes.append("significant rewrite")
            } else if distance > 0.25 {
                notes.append("moderate edits")
            } else {
                notes.append("minor tweaks")
            }
        }

        let platformLabel = platform == "generic" ? "" : " on \(platform.capitalized)"
        return notes.joined(separator: ", ") + platformLabel
    }

    // MARK: - Milestones

    /// Returns a celebration message for milestone example counts, or nil if not a milestone.
    static func milestoneMessage(exampleCount: Int) -> String? {
        switch exampleCount {
        case 5:   return "5 examples learned — Transcripted is finding your voice"
        case 10:  return "10 examples — your style profile is taking shape"
        case 20:  return "20 examples — Transcripted is getting good at this"
        case 50:  return "50 examples — Transcripted writes like you now"
        case 100: return "100 examples — master level style matching"
        default:  return nil
        }
    }

    // MARK: - Edit Detection

    /// Whether the edit is substantive enough to warrant showing the diff flash.
    /// Returns false if original == edited or if only whitespace/case differs.
    static func hasSubstantiveEdits(original: String, edited: String) -> Bool {
        let a = normalize(original)
        let b = normalize(edited)
        return a != b
    }

    // MARK: - Private Helpers

    private static func tokenize(_ text: String) -> [String] {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    private static func normalize(_ text: String) -> String {
        text.split(omittingEmptySubsequences: true, whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
    }

    private static func firstSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Split on sentence-ending punctuation
        if let range = trimmed.range(of: "[.!?]", options: .regularExpression) {
            return String(trimmed[trimmed.startIndex...range.lowerBound])
        }
        // No punctuation — take first 10 words
        let words = tokenize(trimmed)
        return words.prefix(10).joined(separator: " ")
    }

    private static func lastSentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Find last sentence boundary
        let sentences = trimmed.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return sentences.last ?? ""
    }

    private static func wordOverlap(_ a: String, _ b: String) -> Double {
        let wordsA = Set(tokenize(a).map { $0.lowercased() })
        let wordsB = Set(tokenize(b).map { $0.lowercased() })
        guard !wordsA.isEmpty || !wordsB.isEmpty else { return 1.0 }
        let common = wordsA.intersection(wordsB).count
        let total = max(wordsA.count, wordsB.count)
        return Double(common) / Double(total)
    }
}
