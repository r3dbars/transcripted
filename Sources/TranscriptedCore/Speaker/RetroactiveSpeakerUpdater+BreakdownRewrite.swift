import Foundation

// MARK: - Retroactive Speaker Updates: Speaker Breakdown Section Rewrite
//
// Extracted from RetroactiveSpeakerUpdater.swift (audit 2026-07-08 wave 2).
// Pure code motion: everything that rewrites the "#### Local/Remote Speaker
// Breakdown" markdown section, the scoped-replacement fallback used when a
// full-section rewrite can't prove it's unambiguous, and the post-naming
// consolidation pass that merges duplicate breakdown rows.

/// Markdown section-boundary markers that terminate a "#### ... Speaker
/// Breakdown" block. Shared by every function below that needs to find where
/// the section ends — used to be copy-pasted three times across this file
/// (audit 2026-07-08 wave 2).
private let breakdownSectionFooterCandidates: [String] = [
    "\n\n#### ",
    "\n\n### ",
    "\n\n## ",
    "\n\n---\n\n",
    "\n#### ",
    "\n### ",
    "\n## ",
    "\n---\n",
]

extension TranscriptSaver {

    /// Fallback used when `rewriteRemoteSpeakerBreakdown` / `rewriteLocalSpeakerBreakdownIfPresent`
    /// can't prove their rewrite is unambiguous: for each speaker with exactly one
    /// matching breakdown row, swap the row via a placeholder token first (so
    /// overlapping old/new names can't collide mid-pass), then resolve the tokens
    /// to the real new names.
    static func applyScopedBreakdownNameReplacements(
        in content: inout String,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        channels: Set<UtteranceChannel>,
        result: TranscriptionResult
    ) -> Bool {
        applyScopedReplacements(
            in: &content,
            updatesByChannelKey: updatesByChannelKey,
            result: result,
            channelFilter: channels,
            missingTargetFails: false,
            tokenKind: "breakdown",
            gateCountAtPlanTime: false,
            countOccurrences: { content, _, oldName, channel in
                countSpeakerBreakdownRows(in: content, oldName: oldName, channel: channel)
            },
            performReplace: { content, _, oldName, newName, channel in
                replaceSpeakerBreakdownName(in: &content, oldName: oldName, newName: newName, channel: channel)
            },
            replacedCountIsValid: { $0 == 1 }
        )
    }

    @discardableResult
    static func replaceSpeakerBreakdownName(
        in content: inout String,
        oldName: String,
        newName: String,
        channel: UtteranceChannel
    ) -> Int {
        guard let breakdownRange = speakerBreakdownContentRange(in: content, channel: channel) else { return 0 }

        let oldPrefix = "- **\(oldName):**"
        let newPrefix = "- **\(newName):**"
        var replacementCount = 0
        let replacement = String(content[breakdownRange])
            .components(separatedBy: "\n")
            .map { line -> String in
                guard line.hasPrefix(oldPrefix) else { return line }
                replacementCount += 1
                return newPrefix + line.dropFirst(oldPrefix.count)
            }
            .joined(separator: "\n")

        content.replaceSubrange(breakdownRange, with: replacement)
        return replacementCount
    }

    private static func countSpeakerBreakdownRows(
        in content: String,
        oldName: String,
        channel: UtteranceChannel
    ) -> Int {
        guard let breakdownRange = speakerBreakdownContentRange(in: content, channel: channel) else { return 0 }
        let oldPrefix = "- **\(oldName):**"
        return String(content[breakdownRange])
            .components(separatedBy: "\n")
            .filter { $0.hasPrefix(oldPrefix) }
            .count
    }

    private static func speakerBreakdownContentRange(
        in content: String,
        channel: UtteranceChannel
    ) -> Range<String.Index>? {
        let header = channel == .mic
            ? "#### Local Speaker Breakdown\n\n"
            : "#### Remote Speaker Breakdown\n\n"
        guard let headerRange = content.range(of: header) else { return nil }

        let footerStart = breakdownSectionFooterCandidates
            .compactMap { content.range(of: $0, range: headerRange.upperBound..<content.endIndex)?.lowerBound }
            .min() ?? content.endIndex
        return headerRange.upperBound..<footerStart
    }

    static func rewriteRemoteSpeakerBreakdown(
        in content: inout String,
        result: TranscriptionResult,
        updatesByChannelKey: [String: (oldName: String, newName: String)]
    ) -> Bool {
        guard content.contains("#### Remote Speaker Breakdown\n\n") else { return true }

        return rewriteSpeakerBreakdown(
            in: &content,
            header: "#### Remote Speaker Breakdown\n\n",
            utterances: result.systemUtterances,
            channel: .system,
            updatesByChannelKey: updatesByChannelKey
        )
    }

    static func rewriteLocalSpeakerBreakdownIfPresent(
        in content: inout String,
        result: TranscriptionResult,
        updatesByChannelKey: [String: (oldName: String, newName: String)]
    ) -> Bool {
        guard content.contains("#### Local Speaker Breakdown\n\n") else { return true }

        return rewriteSpeakerBreakdown(
            in: &content,
            header: "#### Local Speaker Breakdown\n\n",
            utterances: result.micUtterances,
            channel: .mic,
            updatesByChannelKey: updatesByChannelKey
        )
    }

    private static func rewriteSpeakerBreakdown(
        in content: inout String,
        header: String,
        utterances: [TranscriptionUtterance],
        channel: UtteranceChannel,
        updatesByChannelKey: [String: (oldName: String, newName: String)]
    ) -> Bool {
        guard let headerRange = content.range(of: header) else {
            return false
        }

        guard let footerRange = breakdownSectionFooterCandidates.compactMap({
            content.range(of: $0, range: headerRange.upperBound..<content.endIndex)
        }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return false
        }

        let speakerGroups = Dictionary(grouping: utterances, by: { $0.speakerId })
        let lines = speakerGroups.keys.sorted().map { speakerId in
            let utterances = speakerGroups[speakerId] ?? []
            let speakerKey = channel.speakerKey(diarizerSpeakerId: String(speakerId))
            let speakerName = updatesByChannelKey[speakerKey]?.newName
                ?? updatesByChannelKey[speakerKey]?.oldName
                ?? currentSpeakerName(in: content, diarizerSpeakerId: String(speakerId), channel: channel)
                ?? "Speaker \(speakerId)"
            let speakingTime = utterances.reduce(0.0) { $0 + ($1.end - $1.start) }
            let wordCount = utterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
            return "- **\(speakerName):** \(utterances.count) utterances, ~\(wordCount) words, \(DateFormattingHelper.formatDuration(speakingTime))"
        }

        content.replaceSubrange(headerRange.upperBound..<footerRange.lowerBound, with: lines.joined(separator: "\n"))
        return true
    }
}

// MARK: - Speaker Breakdown Consolidation

enum SpeakerBreakdownConsolidator {
    private static let breakdownHeader = "#### Remote Speaker Breakdown\n\n"
    private static let speakerCountPrefix = "- **Speakers Detected:** "
    private static let lineRegex = try? NSRegularExpression(
        pattern: #"- \*\*(.+?):\*\* (\d+) utterances?, ~(\d+) words?, (\d+):(\d+)"#
    )
    private static let footerRegex = try? NSRegularExpression(pattern: #"\| (\d+) speakers\*"#)

    struct SpeakerStats {
        var utterances = 0
        var words = 0
        var speakingSeconds = 0.0

        mutating func accumulate(_ entry: SpeakerBreakdownEntry) {
            utterances += entry.utterances
            words += entry.words
            speakingSeconds += entry.speakingSeconds
        }
    }

    struct SpeakerBreakdownEntry {
        let name: String
        let utterances: Int
        let words: Int
        let speakingSeconds: Double
    }

    static func consolidate(_ content: String) -> String {
        guard let breakdownStart = content.range(of: breakdownHeader) else {
            return content
        }

        let footerStart = breakdownSectionFooterCandidates.compactMap({
            content.range(of: $0, range: breakdownStart.upperBound..<content.endIndex)
        }).min(by: { $0.lowerBound < $1.lowerBound })?.lowerBound
        let breakdownEnd: String.Index
        if let footerStart {
            breakdownEnd = footerStart
        } else if let footerlessEnd = footerlessBreakdownContentEnd(in: content, from: breakdownStart.upperBound) {
            breakdownEnd = footerlessEnd
        } else {
            return content
        }

        let breakdownRange = breakdownStart.upperBound..<breakdownEnd
        let entries = parseEntries(from: String(content[breakdownRange]))
        guard !entries.isEmpty else { return content }

        var statsByName: [String: SpeakerStats] = [:]
        var nameOrder: [String] = []

        for entry in entries {
            if statsByName[entry.name] == nil {
                nameOrder.append(entry.name)
            }

            var stats = statsByName[entry.name] ?? SpeakerStats()
            stats.accumulate(entry)
            statsByName[entry.name] = stats
        }

        guard statsByName.count < entries.count else { return content }

        let oldSystemSpeakers = entries.count
        let newSystemSpeakers = statsByName.count

        var result = content
        result.replaceSubrange(
            breakdownRange,
            with: renderedBreakdown(nameOrder: nameOrder, statsByName: statsByName)
        )
        result = result.replacingOccurrences(
            of: "system_speakers: \(oldSystemSpeakers)",
            with: "system_speakers: \(newSystemSpeakers)"
        )
        result = result.replacingOccurrences(
            of: "\(speakerCountPrefix)\(oldSystemSpeakers)\n\n\(breakdownHeader.trimmingCharacters(in: .newlines))",
            with: "\(speakerCountPrefix)\(newSystemSpeakers)\n\n\(breakdownHeader.trimmingCharacters(in: .newlines))"
        )
        result = adjustFooterSpeakerCount(in: result, delta: oldSystemSpeakers - newSystemSpeakers)

        AppLogger.pipeline.info("Consolidated duplicate speaker names in breakdown", [
            "before": "\(oldSystemSpeakers)",
            "after": "\(newSystemSpeakers)"
        ])

        return result
    }

    private static func footerlessBreakdownContentEnd(
        in content: String,
        from start: String.Index
    ) -> String.Index? {
        var current = start
        var lastEntryEnd: String.Index?

        while current < content.endIndex {
            let lineEnd = content[current...].firstIndex(of: "\n") ?? content.endIndex
            let line = String(content[current..<lineEnd])
            let nextLineStart = lineEnd < content.endIndex
                ? content.index(after: lineEnd)
                : content.endIndex

            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                guard lastEntryEnd == nil else { break }
                current = nextLineStart
                continue
            }

            guard isBreakdownEntryLine(line) else { break }
            lastEntryEnd = nextLineStart
            current = nextLineStart
        }

        return lastEntryEnd
    }

    private static func isBreakdownEntryLine(_ line: String) -> Bool {
        guard let lineRegex else { return false }
        return lineRegex.firstMatch(
            in: line,
            range: NSRange(location: 0, length: (line as NSString).length)
        ) != nil
    }

    private static func parseEntries(from breakdownText: String) -> [SpeakerBreakdownEntry] {
        guard let lineRegex else { return [] }

        return breakdownText
            .components(separatedBy: "\n")
            .compactMap { line in
                let nsLine = line as NSString
                let range = NSRange(location: 0, length: nsLine.length)
                guard let match = lineRegex.firstMatch(in: line, range: range) else { return nil }

                let name = nsLine.substring(with: match.range(at: 1))
                let utterances = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
                let words = Int(nsLine.substring(with: match.range(at: 3))) ?? 0
                let minutes = Double(nsLine.substring(with: match.range(at: 4))) ?? 0
                let seconds = Double(nsLine.substring(with: match.range(at: 5))) ?? 0

                return SpeakerBreakdownEntry(
                    name: name,
                    utterances: utterances,
                    words: words,
                    speakingSeconds: minutes * 60 + seconds
                )
            }
    }

    private static func renderedBreakdown(
        nameOrder: [String],
        statsByName: [String: SpeakerStats]
    ) -> String {
        nameOrder.compactMap { name in
            guard let stats = statsByName[name] else { return nil }
            let mins = Int(stats.speakingSeconds) / 60
            let secs = Int(stats.speakingSeconds) % 60
            let timeStr = String(format: "%02d:%02d", mins, secs)
            return "- **\(name):** \(stats.utterances) utterances, ~\(stats.words) words, \(timeStr)\n"
        }.joined()
    }

    private static func adjustFooterSpeakerCount(in content: String, delta: Int) -> String {
        guard delta > 0,
              let footerRegex,
              let footerMatch = footerRegex.firstMatch(
                in: content,
                range: NSRange(location: 0, length: (content as NSString).length)
              ),
              let oldTotal = Int((content as NSString).substring(with: footerMatch.range(at: 1))) else {
            return content
        }

        let newTotal = oldTotal - delta
        return content.replacingOccurrences(
            of: "| \(oldTotal) speakers*",
            with: "| \(newTotal) speakers*"
        )
    }
}
