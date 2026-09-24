import Foundation

// MARK: - Retroactive Speaker Updates: Full Transcript Section Rewrite
//
// Extracted from RetroactiveSpeakerUpdater.swift (audit 2026-07-08 wave 2).
// Everything that rewrites speaker labels inside the "## Full Transcript" /
// "## Transcript" markdown section (legacy and styled formats), plus the
// scoped-replacement fallback used when a full-section rewrite can't prove
// it's unambiguous. The styled pass aligns rows by (timestamp, source) rather
// than by count (APPLE-MACOS-1R edge cases).

extension TranscriptSaver {

    /// Fallback used when `rewriteFullTranscriptSection` can't prove its rewrite is
    /// unambiguous: for each speaker whose transcript-label occurrence count exactly
    /// matches the number of utterances we expect for them, swap the labels via a
    /// placeholder token first (so overlapping old/new names can't collide mid-pass),
    /// then resolve the tokens to the real new names.
    static func applyScopedTranscriptLabelReplacements(
        in content: inout String,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        result: TranscriptionResult
    ) -> Bool {
        applyScopedReplacements(
            in: &content,
            updatesByChannelKey: updatesByChannelKey,
            result: result,
            channelFilter: nil,
            missingTargetFails: true,
            tokenKind: "transcript",
            gateCountAtPlanTime: true,
            countOccurrences: { content, prefix, oldName, _ in
                countTranscriptSpeakerLabels(in: content, prefix: prefix, oldName: oldName)
            },
            performReplace: { content, prefix, oldName, newName, _ in
                replaceTranscriptSpeakerLabels(in: &content, prefix: prefix, oldName: oldName, newName: newName)
            },
            replacedCountIsValid: { $0 > 0 }
        )
    }

    @discardableResult
    static func replaceTranscriptSpeakerLabels(
        in content: inout String,
        prefix: String,
        oldName: String,
        newName: String
    ) -> Int {
        let replacements = [
            ("[\(prefix)/\(oldName)]", "[\(prefix)/\(newName)]"),
            ("[\(prefix)/[[\(oldName)]]]", "[\(prefix)/[[\(newName)]]]"),
        ]
        var lines = content.components(separatedBy: "\n")
        var changed = false
        var replacementCount = 0

        for index in lines.indices {
            var line = lines[index]
            for (oldLabel, newLabel) in replacements {
                guard let labelRange = line.range(of: oldLabel),
                      isTranscriptLabelPrefix(line[..<labelRange.lowerBound]) else {
                    continue
                }

                line.replaceSubrange(labelRange, with: newLabel)
                lines[index] = line
                changed = true
                replacementCount += 1
                break
            }
        }

        if changed {
            content = lines.joined(separator: "\n")
        }
        return replacementCount
    }

    private static func countTranscriptSpeakerLabels(
        in content: String,
        prefix: String,
        oldName: String
    ) -> Int {
        let labels = [
            "[\(prefix)/\(oldName)]",
            "[\(prefix)/[[\(oldName)]]]",
        ]

        return content.components(separatedBy: "\n").reduce(0) { count, line in
            guard let labelRange = labels.compactMap({ line.range(of: $0) }).first,
                  isTranscriptLabelPrefix(line[..<labelRange.lowerBound]) else {
                return count
            }
            return count + 1
        }
    }

    private static func isTranscriptLabelPrefix(_ prefix: Substring) -> Bool {
        let normalized = String(prefix)
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = normalized.split(separator: ":")
        guard parts.count >= 2, parts.count <= 3 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isNumber }
        }
    }

    static func rewriteFullTranscriptSection(
        in content: inout String,
        result: TranscriptionResult,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        obsidianEnabled: Bool
    ) -> Bool {
        if let range = fullTranscriptContentRange(in: content) {
            return rewriteLegacyTranscriptSection(
                in: &content,
                range: range,
                result: result,
                updatesByChannelKey: updatesByChannelKey,
                obsidianEnabled: obsidianEnabled
            )
        }

        if let range = styledTranscriptContentRange(in: content) {
            return rewriteStyledTranscriptSection(
                in: &content,
                range: range,
                result: result,
                updatesByChannelKey: updatesByChannelKey,
                obsidianEnabled: obsidianEnabled
            )
        }

        if let range = bareTranscriptContentRange(in: content) {
            return rewriteLegacyTranscriptSection(
                in: &content,
                range: range,
                result: result,
                updatesByChannelKey: updatesByChannelKey,
                obsidianEnabled: obsidianEnabled
            )
        }

        return false
    }

    private static func fullTranscriptContentRange(in content: String) -> Range<String.Index>? {
        guard let headerRange = content.range(of: "## Full Transcript\n\n"),
              let footerRange = content.range(
                of: "\n\n---\n\n*Generated by Transcripted",
                range: headerRange.upperBound..<content.endIndex
              ) else {
            return nil
        }

        return headerRange.upperBound..<footerRange.lowerBound
    }

    private static func styledTranscriptContentRange(in content: String) -> Range<String.Index>? {
        guard let headerRange = content.range(of: "## Transcript\n\n") else {
            return nil
        }

        let footerCandidates = [
            "\n\n---\n\n",
            "\n\n**Participants:** ",
        ]
        let footerStart = footerCandidates
            .compactMap { content.range(of: $0, range: headerRange.upperBound..<content.endIndex)?.lowerBound }
            .min() ?? content.endIndex
        return headerRange.upperBound..<footerStart
    }

    private static func bareTranscriptContentRange(in content: String) -> Range<String.Index>? {
        guard let separatorRange = content.range(of: "\n---\n\n", options: .backwards) else {
            return nil
        }

        let start = separatorRange.upperBound
        guard start < content.endIndex else { return nil }
        return start..<content.endIndex
    }

    private static func rewriteLegacyTranscriptSection(
        in content: inout String,
        range: Range<String.Index>,
        result: TranscriptionResult,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        obsidianEnabled: Bool
    ) -> Bool {
        let lines = String(content[range]).components(separatedBy: "\n")
        let utterances = result.allUtterances
        var rewrittenLines = lines
        var utteranceIndex = 0

        for index in lines.indices {
            // Only `[<MM:SS>] [<Mic|System>/...]` lines are rows. An utterance
            // continuation line that merely starts with brackets is text.
            guard let components = parseTranscriptLine(lines[index]),
                  isTranscriptSource(components.source),
                  isTranscriptLabelPrefix(Substring(components.timestamp)) else { continue }
            guard utteranceIndex < utterances.count else { return false }

            let utterance = utterances[utteranceIndex]
            utteranceIndex += 1

            let expectedTimestamp = formatTranscriptTimestamp(utterance.start)
            let expectedSource = utterance.channel == 0 ? "Mic" : "System"
            guard components.timestamp == expectedTimestamp, components.source == expectedSource else {
                return false
            }

            let channel: UtteranceChannel = utterance.channel == 0 ? .mic : .system
            let speakerKey = channel.speakerKey(diarizerSpeakerId: String(utterance.speakerId))
            guard let update = updatesByChannelKey[speakerKey] else { continue }

            // `parseTranscriptLine` ends the label at the first "] ", so a name
            // that itself contains "] " ("Bob [Sales] Smith") would push its tail
            // into the text. Prefer splitting on the label we know is there.
            let row = splitRawTranscriptLine(
                lines[index],
                timestamp: components.timestamp,
                source: components.source,
                knownLabels: ["[[\(update.oldName)]]", update.oldName]
            ) ?? (label: components.label, text: components.text)

            let label = transcriptLabel(
                for: update.newName,
                currentLabel: row.label,
                obsidianEnabled: obsidianEnabled
            )
            rewrittenLines[index] = "[\(components.timestamp)] [\(components.source)/\(label)] \(row.text)"
        }

        guard utteranceIndex == utterances.count else { return false }
        content.replaceSubrange(range, with: rewrittenLines.joined(separator: "\n"))
        return true
    }

    private struct StyledTranscriptRow {
        let chunkIndex: Int
        let lineIndex: Int
        let timestamp: String
        let source: String
        let label: String
    }

    /// Rewrite the styled body (`**<MM:SS>**  [<Mic|System>/<label>]` blocks).
    ///
    /// The async restyle (`MeetingTranscriptStyler`, app side) drops entries it
    /// cannot render — utterances whose text is only `**`, whose first line is
    /// blank, or that are whitespace-only — and can keep an entry for a
    /// whitespace-only utterance when the label contains `]`. So styled rows are
    /// not a 1:1 copy of `result.allUtterances`. Rows are matched to utterances
    /// by (timestamp, source) in order instead, and a row is only rewritten when
    /// every possible in-order match gives it the same new name. Anything that
    /// could put the wrong name on a row fails closed (returns false) so the
    /// caller falls back to the count-gated scoped replacement.
    private static func rewriteStyledTranscriptSection(
        in content: inout String,
        range: Range<String.Index>,
        result: TranscriptionResult,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        obsidianEnabled: Bool
    ) -> Bool {
        // Keep empty pieces so re-joining reproduces every byte this pass does
        // not deliberately rewrite.
        var chunks = String(content[range]).components(separatedBy: "\n\n")
        var rows: [StyledTranscriptRow] = []

        for chunkIndex in chunks.indices {
            let lines = chunks[chunkIndex].components(separatedBy: "\n")
            let headerIndex = lines.firstIndex {
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }

            guard let headerIndex,
                  let header = parseStyledTranscriptHeader(lines[headerIndex]) else {
                // Not a row (the empty-transcript placeholder, a preserved
                // trailing section, ...): keep it verbatim. If it still reads
                // like a row we could not parse, skipping it would leave a stale
                // label behind, so refuse instead.
                if lines.contains(where: looksLikeTranscriptRowLine) { return false }
                continue
            }

            // One row per block. A second header folded into this block (lost
            // blank-line separator) would otherwise keep its old label.
            let foldedHeader = lines.indices.contains { index in
                index != headerIndex && parseStyledTranscriptHeader(lines[index]) != nil
            }
            guard !foldedHeader else { return false }

            rows.append(StyledTranscriptRow(
                chunkIndex: chunkIndex,
                lineIndex: headerIndex,
                timestamp: header.timestamp,
                source: header.source,
                label: header.label
            ))
        }

        // Normal case first: the styler renders exactly the utterances with
        // visible text. Then allow for a row kept for a whitespace-only one.
        let allUtterances = result.allUtterances
        let visibleUtterances = allUtterances.filter {
            !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard let newNames = alignedStyledRowNames(
            rows,
            utterances: visibleUtterances,
            updatesByChannelKey: updatesByChannelKey
        ) ?? alignedStyledRowNames(
            rows,
            utterances: allUtterances,
            updatesByChannelKey: updatesByChannelKey
        ) else {
            return false
        }

        if rows.count != visibleUtterances.count {
            AppLogger.pipeline.info("Styled transcript rows aligned by timestamp", [
                "rows": "\(rows.count)",
                "visibleUtterances": "\(visibleUtterances.count)"
            ])
        }

        for (row, newName) in zip(rows, newNames) {
            guard let newName else { continue }
            let label = transcriptLabel(
                for: newName,
                currentLabel: row.label,
                obsidianEnabled: obsidianEnabled
            )
            var lines = chunks[row.chunkIndex].components(separatedBy: "\n")
            lines[row.lineIndex] = "**\(row.timestamp)**  [\(row.source)/\(label)]"
            chunks[row.chunkIndex] = lines.joined(separator: "\n")
        }

        content.replaceSubrange(range, with: chunks.joined(separator: "\n\n"))
        return true
    }

    /// Match styled rows to utterances in order by (timestamp, source), allowing
    /// utterances that have no row. Returns, per row, the new name to write
    /// (`nil` = leave the label alone), or nil when some row has no match or
    /// could belong to utterances that would get different names.
    ///
    /// The earliest and latest in-order matches bound every possible match for
    /// each row, so checking every same-key utterance between those bounds is
    /// enough to prove the rewrite cannot mislabel. When every utterance has a
    /// row the bounds coincide and this is the plain one-to-one walk.
    private static func alignedStyledRowNames(
        _ rows: [StyledTranscriptRow],
        utterances: [TranscriptionUtterance],
        updatesByChannelKey: [String: (oldName: String, newName: String)]
    ) -> [String?]? {
        let utteranceKeys = utterances.map { utterance in
            (
                timestamp: formatTranscriptTimestamp(utterance.start),
                source: utterance.channel == 0 ? "Mic" : "System"
            )
        }
        func matches(_ utteranceIndex: Int, _ rowIndex: Int) -> Bool {
            utteranceKeys[utteranceIndex].timestamp == rows[rowIndex].timestamp
                && utteranceKeys[utteranceIndex].source == rows[rowIndex].source
        }

        var earliest: [Int] = []
        earliest.reserveCapacity(rows.count)
        var nextIndex = 0
        for rowIndex in rows.indices {
            while nextIndex < utteranceKeys.count, !matches(nextIndex, rowIndex) {
                nextIndex += 1
            }
            guard nextIndex < utteranceKeys.count else { return nil }
            earliest.append(nextIndex)
            nextIndex += 1
        }

        var latest = [Int](repeating: 0, count: rows.count)
        var previousIndex = utteranceKeys.count - 1
        for rowIndex in rows.indices.reversed() {
            while previousIndex >= 0, !matches(previousIndex, rowIndex) {
                previousIndex -= 1
            }
            guard previousIndex >= 0 else { return nil }
            latest[rowIndex] = previousIndex
            previousIndex -= 1
        }

        var newNames: [String?] = []
        newNames.reserveCapacity(rows.count)
        for rowIndex in rows.indices {
            guard earliest[rowIndex] <= latest[rowIndex] else { return nil }
            var candidateNames = Set<String?>()
            for utteranceIndex in earliest[rowIndex]...latest[rowIndex] where matches(utteranceIndex, rowIndex) {
                let utterance = utterances[utteranceIndex]
                let channel: UtteranceChannel = utterance.channel == 0 ? .mic : .system
                let speakerKey = channel.speakerKey(diarizerSpeakerId: String(utterance.speakerId))
                candidateNames.insert(updatesByChannelKey[speakerKey]?.newName)
            }
            guard candidateNames.count == 1, let newName = candidateNames.first else { return nil }
            newNames.append(newName)
        }
        return newNames
    }

    /// True when `line` carries a `[Mic/...]` / `[System/...]` label right after
    /// a bare timestamp (raw or styled), i.e. it reads like a transcript row.
    private static func looksLikeTranscriptRowLine(_ line: String) -> Bool {
        ["[Mic/", "[System/"].contains { marker in
            guard let markerRange = line.range(of: marker) else { return false }
            return isTranscriptLabelPrefix(line[..<markerRange.lowerBound])
        }
    }

    private static func isTranscriptSource(_ source: String) -> Bool {
        source == "Mic" || source == "System"
    }

    /// Split a raw row `[<ts>] [<source>/<label>] <text>` using a label we
    /// already expect to find there. Returns nil when none of them match.
    private static func splitRawTranscriptLine(
        _ line: String,
        timestamp: String,
        source: String,
        knownLabels: [String]
    ) -> (label: String, text: String)? {
        for label in knownLabels where !label.isEmpty {
            let prefix = "[\(timestamp)] [\(source)/\(label)] "
            if line.hasPrefix(prefix) {
                return (label, String(line.dropFirst(prefix.count)))
            }
        }
        return nil
    }


    private static func parseTranscriptLine(_ line: String) -> (timestamp: String, source: String, label: String, text: String)? {
        guard line.hasPrefix("["),
              let timestampEnd = line.firstIndex(of: "]"),
              line.indices.contains(line.index(after: timestampEnd)),
              line[line.index(after: timestampEnd)...].hasPrefix(" [") else {
            return nil
        }

        let timestamp = String(line[line.index(after: line.startIndex)..<timestampEnd])
        let sourceStart = line.index(timestampEnd, offsetBy: 3)
        guard let labelEnd = line.range(of: "] ", range: sourceStart..<line.endIndex) else {
            return nil
        }

        let sourceLabel = line[sourceStart..<labelEnd.lowerBound]
        guard let separator = sourceLabel.firstIndex(of: "/") else {
            return nil
        }

        let source = String(sourceLabel[..<separator])
        let label = String(sourceLabel[sourceLabel.index(after: separator)...])
        let textStart = labelEnd.upperBound
        let text = String(line[textStart...])
        return (timestamp, source, label, text)
    }

    private static let styledHeaderRegex = try? NSRegularExpression(pattern: #"^([0-9:]+)\s+\[(.+?)\]$"#)

    private static func parseStyledTranscriptHeader(_ line: String) -> (timestamp: String, source: String, label: String)? {
        let normalizedHeader = line
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let regex = styledHeaderRegex else {
            return nil
        }

        let nsHeader = normalizedHeader as NSString
        let range = NSRange(location: 0, length: nsHeader.length)
        guard let match = regex.firstMatch(in: normalizedHeader, range: range),
              match.numberOfRanges >= 3 else {
            return nil
        }

        let timestamp = nsHeader.substring(with: match.range(at: 1))
        let sourceLabel = nsHeader.substring(with: match.range(at: 2))
        guard let separator = sourceLabel.firstIndex(of: "/") else { return nil }

        let source = String(sourceLabel[..<separator])
        let label = String(sourceLabel[sourceLabel.index(after: separator)...])
        return (timestamp, source, label)
    }

    private static func transcriptLabel(
        for name: String,
        currentLabel: String,
        obsidianEnabled: Bool
    ) -> String {
        let usesWikiLink = (currentLabel.hasPrefix("[[") && currentLabel.hasSuffix("]]"))
            || (obsidianEnabled && !name.hasPrefix("Speaker "))
        guard usesWikiLink else { return name }
        return "[[\(name)]]"
    }

    private static func formatTranscriptTimestamp(_ seconds: Double) -> String {
        let startMinutes = Int(seconds) / 60
        let startSeconds = Int(seconds) % 60
        return String(format: "%02d:%02d", startMinutes, startSeconds)
    }
}
