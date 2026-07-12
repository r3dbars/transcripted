import Foundation

// MARK: - Retroactive Speaker Updates: Full Transcript Section Rewrite
//
// Extracted from RetroactiveSpeakerUpdater.swift (audit 2026-07-08 wave 2).
// Pure code motion: everything that rewrites speaker labels inside the
// "## Full Transcript" / "## Transcript" markdown section (legacy and
// styled formats), plus the scoped-replacement fallback used when a
// full-section rewrite can't prove it's unambiguous.

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
            guard let components = parseTranscriptLine(lines[index]) else { continue }
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

            let label = transcriptLabel(
                for: update.newName,
                currentLabel: components.label,
                obsidianEnabled: obsidianEnabled
            )
            rewrittenLines[index] = "[\(components.timestamp)] [\(components.source)/\(label)] \(components.text)"
        }

        guard utteranceIndex == utterances.count else { return false }
        content.replaceSubrange(range, with: rewrittenLines.joined(separator: "\n"))
        return true
    }

    private static func rewriteStyledTranscriptSection(
        in content: inout String,
        range: Range<String.Index>,
        result: TranscriptionResult,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        obsidianEnabled: Bool
    ) -> Bool {
        let chunks = String(content[range])
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let utterances = result.allUtterances.filter {
            !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard chunks.count == utterances.count else { return false }

        var rewrittenChunks: [String] = []
        rewrittenChunks.reserveCapacity(chunks.count)

        for (chunk, utterance) in zip(chunks, utterances) {
            let lines = chunk.components(separatedBy: "\n")
            guard let header = lines.first,
                  let components = parseStyledTranscriptHeader(header) else {
                return false
            }

            let expectedTimestamp = formatTranscriptTimestamp(utterance.start)
            let expectedSource = utterance.channel == 0 ? "Mic" : "System"
            guard components.timestamp == expectedTimestamp, components.source == expectedSource else {
                return false
            }

            let utteranceChannel: UtteranceChannel = utterance.channel == 0 ? .mic : .system
            let speakerKey = utteranceChannel.speakerKey(diarizerSpeakerId: String(utterance.speakerId))
            if let update = updatesByChannelKey[speakerKey] {
                let label = transcriptLabel(
                    for: update.newName,
                    currentLabel: components.label,
                    obsidianEnabled: obsidianEnabled
                )
                var rewrittenLines = lines
                rewrittenLines[0] = "**\(components.timestamp)**  [\(components.source)/\(label)]"
                rewrittenChunks.append(rewrittenLines.joined(separator: "\n"))
            } else {
                rewrittenChunks.append(chunk)
            }
        }

        content.replaceSubrange(range, with: rewrittenChunks.joined(separator: "\n\n"))
        return true
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
