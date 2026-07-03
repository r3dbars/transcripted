import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// Always-on, dependency-free meeting field extraction.
///
/// The heavy local summarizer (`LocalMeetingSummarizer`) only runs when a user
/// opts into the ~12GB Gemma / Apple beta path, so structured fields
/// (Decisions / Action Items / Open Questions) historically existed for a
/// subset of meetings. That left the "ask my history" index covering only that
/// subset.
///
/// `MeetingQuickSummaryExtractor` is the cheap baseline that ships on every
/// save: a rule/heuristic pass over the already-styled transcript that fills a
/// basic version of the same `LocalMeetingSummarySections` shape with no model
/// dependency. The heavy summarizer remains the high-quality path; this only
/// guarantees coverage so the index can reach 100% of captures.
///
/// It is intentionally precision-leaning: a curated cue list, sentence-level
/// matching, dedupe, and per-section caps. Better to under-extract a soft
/// signal than to flood the index with greetings and audio checks.
enum MeetingQuickSummaryExtractor {
    /// A single speaker turn pulled from the styled transcript body.
    struct Turn: Equatable {
        let speaker: String?
        let text: String
    }

    static let maxBulletsPerSection = 12
    static let maxSummaryBullets = 4

    /// Build a baseline section set from raw transcript text (the body under
    /// `## Transcript` / `## Full Transcript`, already extracted by
    /// `LocalMeetingTranscriptExtractor`).
    static func sections(transcript: String) -> LocalMeetingSummarySections {
        let turns = self.turns(in: transcript)

        var decisions: [String] = []
        var actionItems: [String] = []
        var openQuestions: [String] = []
        var summaryCandidates: [(weight: Int, text: String)] = []

        for turn in turns {
            let owner = displayOwner(turn.speaker)
            for sentence in sentences(in: turn.text) {
                let normalized = sentence.lowercased()
                guard !isSmallTalk(normalized) else { continue }

                // One sentence lands in at most one structured bucket, in
                // priority order, so a "we'll decide X" line does not show up
                // as both a decision and an action item.
                if matchesAny(decisionCues, in: normalized) {
                    append(sentence, to: &decisions)
                } else if matchesAny(actionCues, in: normalized) {
                    append(ownerPrefixed(sentence, owner: owner), to: &actionItems)
                } else if isOpenQuestion(sentence, normalized: normalized) {
                    append(sentence, to: &openQuestions)
                }

                if isSummaryWorthy(sentence, normalized: normalized) {
                    summaryCandidates.append((weight: sentence.count, text: sentence))
                }
            }
        }

        let summary = buildSummary(from: summaryCandidates)

        return LocalMeetingSummarySections(
            title: nil,
            participants: LocalMeetingSummaryParticipantExtractor.participants(from: transcript),
            summary: bulletList(summary),
            decisions: bulletList(Array(decisions.prefix(maxBulletsPerSection))),
            actionItems: bulletList(Array(actionItems.prefix(maxBulletsPerSection))),
            openQuestions: bulletList(Array(openQuestions.prefix(maxBulletsPerSection))),
            risksOrFollowUps: "None found.",
            accuracyNotes: "Quick automatic extraction. Run the local AI summary for a higher-quality version."
        )
    }

    // MARK: - Turn parsing

    /// Parse the canonical styled transcript form produced by
    /// `MeetingTranscriptStyler` (`**<timestamp>**  [<label>]` header lines
    /// followed by one or more text lines), while still tolerating the
    /// `[<label>] <timestamp> text` inline form.
    static func turns(in transcript: String) -> [Turn] {
        var turns: [Turn] = []
        var currentSpeaker: String?
        var currentText: [String] = []

        func flush() {
            let text = currentText
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty {
                turns.append(Turn(speaker: currentSpeaker, text: text))
            }
            currentText = []
        }

        for rawLine in transcript.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if let header = parseHeaderLine(line) {
                flush()
                currentSpeaker = header.speaker
                if let inlineText = header.inlineText, !inlineText.isEmpty {
                    currentText.append(inlineText)
                }
            } else {
                currentText.append(line)
            }
        }
        flush()

        return turns
    }

    private struct ParsedHeader {
        let speaker: String?
        let inlineText: String?
    }

    private static func parseHeaderLine(_ line: String) -> ParsedHeader? {
        // Styled form: **<timestamp>**  [<label>]  (text on following lines)
        if line.hasPrefix("**") {
            let afterFirst = line.dropFirst(2)
            guard let closing = afterFirst.range(of: "**") else { return nil }
            let timestamp = String(afterFirst[afterFirst.startIndex..<closing.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard looksLikeTimestamp(timestamp) else { return nil }
            let remainder = String(afterFirst[closing.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let speaker = firstBracketValue(in: remainder)
            let inline = remainder
                .components(separatedBy: "]")
                .dropFirst()
                .joined(separator: "]")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ParsedHeader(speaker: speaker, inlineText: inline.isEmpty ? nil : inline)
        }

        // Inline form: [<label>] <timestamp> text  or  [<timestamp>] [<label>] text
        if line.hasPrefix("["), let end = line.firstIndex(of: "]") {
            let firstValue = String(line[line.index(after: line.startIndex)..<end])
            let remainder = String(line[line.index(after: end)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if looksLikeTimestamp(firstValue) {
                // [timestamp] [label] text
                let speaker = firstBracketValue(in: remainder)
                let text = remainder
                    .components(separatedBy: "]")
                    .dropFirst()
                    .joined(separator: "]")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return ParsedHeader(speaker: speaker, inlineText: text.isEmpty ? nil : text)
            }
            if startsWithTimestamp(remainder), !firstValue.isEmpty {
                // [label] timestamp text
                let text = dropLeadingTimestamp(remainder)
                return ParsedHeader(speaker: firstValue, inlineText: text.isEmpty ? nil : text)
            }
        }

        return nil
    }

    // MARK: - Heuristic cue sets

    private static let actionCues: [String] = [
        "i'll ", "i will ", "we'll ", "we will ", "i'm going to", "we're going to",
        "i am going to", "we are going to", "i can ", "i need to", "we need to",
        "you need to", "needs to ", "have to ", "let me ", "let's ", "follow up",
        "follow-up", "action item", "next step", "to-do", "todo", "make sure",
        "i'll send", "i'll email", "i'll share", "i'll write", "i'll set up",
        "i'll schedule", "by tomorrow", "by next week", "by monday", "by tuesday",
        "by wednesday", "by thursday", "by friday", "by end of", "i'll take care of",
        "i'll look into", "i'll reach out", "i'll circle back", "we should ",
    ]

    private static let decisionCues: [String] = [
        "we decided", "i decided", "we've decided", "decided to ", "decided that",
        "let's go with", "we'll go with", "we're going with", "going with ",
        "we agreed", "agreed to ", "agreed that", "let's use", "we'll use",
        "the plan is", "final decision", "we're going to go with", "approved",
        "we settled on", "settled on ", "the decision is", "we chose",
        "we'll move forward with", "moving forward with", "sign off",
    ]

    private static let questionCues: [String] = [
        "open question", "to be determined", "tbd", "not sure ", "i'm not sure",
        "we're not sure", "unclear ", "need to figure out", "still need to decide",
        "the question is", "remains unclear", "up in the air", "haven't decided",
    ]

    private static let questionLeadWords: Set<String> = [
        "what", "when", "where", "who", "whom", "whose", "why", "how", "which",
        "should", "shall", "could", "would", "can", "do", "does", "did", "is",
        "are", "will", "have", "has",
    ]

    private static let smallTalkMarkers: [String] = [
        "can you hear me", "are you there", "you there", "test test", "testing testing",
        "good morning", "good afternoon", "good evening", "how are you", "how's it going",
        "nice to meet", "thanks everyone", "thank you all", "see you", "talk soon",
        "have a good", "sounds good", "no worries", "you're welcome",
    ]

    private static func matchesAny(_ cues: [String], in normalized: String) -> Bool {
        cues.contains { normalized.contains($0) }
    }

    private static func isOpenQuestion(_ sentence: String, normalized: String) -> Bool {
        if matchesAny(questionCues, in: normalized) { return true }
        guard sentence.hasSuffix("?") else { return false }
        let words = normalized
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        guard words.count >= 4 else { return false }
        guard let lead = words.first else { return false }
        return questionLeadWords.contains(lead)
    }

    private static func isSummaryWorthy(_ sentence: String, normalized: String) -> Bool {
        guard !sentence.hasSuffix("?") else { return false }
        let wordCount = normalized.split(whereSeparator: { $0 == " " }).count
        return wordCount >= 6
    }

    private static func isSmallTalk(_ normalized: String) -> Bool {
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 3 { return true }
        return smallTalkMarkers.contains { trimmed.contains($0) }
    }

    // MARK: - Summary assembly

    private static func buildSummary(from candidates: [(weight: Int, text: String)]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        // Prefer the most substantive sentences but keep them in transcript order
        // for readability: take the heaviest N, then re-sort by first appearance.
        let topByWeight = candidates
            .sorted { $0.weight > $1.weight }
            .prefix(maxSummaryBullets * 2)
        let topKeys = Set(topByWeight.map { dedupeKey($0.text) })
        for candidate in candidates where topKeys.contains(dedupeKey(candidate.text)) {
            let key = dedupeKey(candidate.text)
            guard !seen.contains(key) else { continue }
            seen.insert(key)
            ordered.append(candidate.text)
            if ordered.count >= maxSummaryBullets { break }
        }
        return ordered
    }

    // MARK: - Formatting helpers

    private static func append(_ sentence: String, to bucket: inout [String]) {
        let cleaned = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        let key = dedupeKey(cleaned)
        guard !bucket.contains(where: { dedupeKey($0) == key }) else { return }
        bucket.append(cleaned)
    }

    private static func ownerPrefixed(_ sentence: String, owner: String) -> String {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(owner): \(trimmed)"
    }

    private static func bulletList(_ items: [String]) -> String {
        guard !items.isEmpty else { return "None found." }
        return items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func dedupeKey(_ text: String) -> String {
        text.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func displayOwner(_ speaker: String?) -> String {
        guard let speaker, !speaker.isEmpty else { return "Unassigned" }
        let base = speaker
            .split(separator: "/", omittingEmptySubsequences: false)
            .last
            .map(String.init) ?? speaker
        let cleaned = base
            .replacingOccurrences(of: "[", with: "")
            .replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return "Unassigned" }
        let lower = cleaned.lowercased()
        if lower == "mic" || lower == "local" || lower == "me" { return "You" }
        if lower == "remote" || lower == "unknown" || lower == "system" { return "Unassigned" }
        return cleaned
    }

    // MARK: - Sentence splitting

    static func sentences(in text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        for character in text {
            current.append(character)
            if character == "." || character == "!" || character == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { sentences.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { sentences.append(tail) }
        return sentences
    }

    // MARK: - Small parsing utilities (mirrors LocalMeetingSummary* helpers)

    private static func firstBracketValue(in raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("["), let end = text.firstIndex(of: "]") else { return nil }
        let value = String(text[text.index(after: text.startIndex)..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func startsWithTimestamp(_ value: String) -> Bool {
        let first = value.split(separator: " ", maxSplits: 1).first.map(String.init) ?? value
        return looksLikeTimestamp(first)
    }

    private static func dropLeadingTimestamp(_ value: String) -> String {
        let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, looksLikeTimestamp(parts[0]) else { return value }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func looksLikeTimestamp(_ value: String) -> Bool {
        let parts = value.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
    }
}
