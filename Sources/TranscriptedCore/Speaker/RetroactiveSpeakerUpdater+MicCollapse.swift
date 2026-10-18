import Foundation

// MARK: - Retroactive Speaker Updates: Mic Collapse and Database Links
//
// Moved out of RetroactiveSpeakerUpdater.swift unchanged: collapsing mic speakers
// back to "You" and discarding speaker-database links from saved transcripts.

extension TranscriptSaver {

    private static let micLabelRegex = try? NSRegularExpression(pattern: #"\[Mic/[^\]]*\]"#)
    private static let localSpeakerBreakdownRegex = try? NSRegularExpression(
        pattern: #"(?s)\n#### Local Speaker Breakdown\n.*?\n\n"#
    )
    private static let speakersDetectedLineRegex = try? NSRegularExpression(
        pattern: #"\n- \*\*Speakers Detected:\*\* \d+\n"#
    )

    /// Collapse mic speakers back to "You" after the user clicked "Keep as You" in the
    /// naming sheet. Rewrites the saved transcript to:
    ///   - Replace every `[Mic/Speaker N]` (or named) label with `[Mic/You]` in the body
    ///   - Remove the "Local Speaker Breakdown" section if present
    ///   - Change the mic section header back to "Microphone (You)"
    ///   - Strip the per-mic-speaker entries from the YAML frontmatter
    ///
    /// Does not touch system speakers or Obsidian wiki links for mic speakers (the
    /// label pattern `[Mic/...]` is the only place mic speakers appear by name in the
    /// body today; Obsidian wiki links only wrap system-speaker names in the Full
    /// Transcript section at render time).
    @discardableResult
    static func collapseMicSpeakersToYou(
        transcriptURL: URL,
        collapsedUpdates: [SpeakerNameUpdate]
    ) -> Bool {
        guard !collapsedUpdates.isEmpty else { return true }

        return serializeTranscriptFileUpdate {
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for mic collapse", ["path": transcriptURL.path])
                return false
            }

            // 1) Rewrite body mic labels. Replace `[Mic/<anything>]` with `[Mic/You]`.
            if let regex = micLabelRegex {
                let range = NSRange(content.startIndex..., in: content)
                content = regex.stringByReplacingMatches(
                    in: content, options: [], range: range, withTemplate: "[Mic/You]"
                )
            }

            // 2) Mic section header: "Microphone (People in the Room)" -> "Microphone (You)"
            content = content.replacingOccurrences(
                of: "### Microphone (People in the Room)",
                with: "### Microphone (You)"
            )

            // 3) Remove the "Local Speaker Breakdown" subsection entirely.
            if let regex = localSpeakerBreakdownRegex {
                let range = NSRange(content.startIndex..., in: content)
                content = regex.stringByReplacingMatches(
                    in: content, options: [], range: range, withTemplate: "\n"
                )
            }

            // 4) Strip mic speakers from the YAML frontmatter `speakers:` block.
            content = stripYAMLSpeakerEntries(in: content, channel: "mic")

            // 5) "Speakers Detected: N" line inside the mic stats block — drop it.
            //    Only remove inside the mic section so the remote stats line is untouched.
            if let regex = speakersDetectedLineRegex,
               let micHeaderRange = content.range(of: "### Microphone (You)") {
                let micSectionEnd = content.range(of: "\n\n### ", range: micHeaderRange.upperBound..<content.endIndex)?.lowerBound ?? content.endIndex
                let micSectionRange = NSRange(micHeaderRange.upperBound..<micSectionEnd, in: content)
                content = regex.stringByReplacingMatches(
                    in: content, options: [], range: micSectionRange, withTemplate: "\n"
                )
            }

            do {
                try TranscriptFileRewrite.write(content, to: transcriptURL)
                restrictTranscriptToOwnerOnly(transcriptURL)
            } catch {
                AppLogger.pipeline.error("Failed to write collapsed transcript", ["error": error.localizedDescription])
                return false
            }

            AppLogger.pipeline.info("Collapsed mic speakers to 'You'", [
                "path": transcriptURL.lastPathComponent,
                "collapsed": "\(collapsedUpdates.count)"
            ])
            return true
        }
    }

    /// Remove database identity links for speakers the user explicitly discarded during
    /// review. The transcript stays readable with its current generic/suggested labels,
    /// but it no longer points at a profile that was deleted or restored.
    @discardableResult
    static func discardSpeakerDatabaseLinks(
        transcriptURL: URL,
        discardedUpdates: [SpeakerNameUpdate]
    ) -> Bool {
        guard !discardedUpdates.isEmpty else { return true }

        return serializeTranscriptFileUpdate {
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for speaker discard", ["path": transcriptURL.path])
                return false
            }

            for update in discardedUpdates {
                removeSpeakerDatabaseLinkFromFrontmatter(in: &content, update: update)
            }

            do {
                try TranscriptFileRewrite.write(content, to: transcriptURL)
                restrictTranscriptToOwnerOnly(transcriptURL)
            } catch {
                AppLogger.pipeline.error("Failed to write discarded speaker metadata", ["error": error.localizedDescription])
                return false
            }

            AppLogger.pipeline.info("Removed discarded speaker database links", [
                "path": transcriptURL.lastPathComponent,
                "discarded": "\(discardedUpdates.count)"
            ])
            return true
        }
    }

    /// Remove speaker YAML entries whose `channel:` line matches `channel`.
    /// Speaker entries have the structure:
    ///   - id: "X"
    ///     channel: mic|system
    ///     db_id: "UUID"     (optional)
    ///     name: "Foo"
    ///     confidence: xxx
    ///     source: xxx
    /// We scan line-by-line and drop contiguous blocks that start with `  - id:` and
    /// contain a matching `channel:` line before the next `  - id:` or block end.
    private static func stripYAMLSpeakerEntries(in content: String, channel: String) -> String {
        var lines = content.components(separatedBy: "\n")
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("  - id:") {
                // Collect the block — lines that follow indented with 4 spaces until
                // the next `  - id:` / end-of-speakers-block marker.
                var blockEnd = i + 1
                while blockEnd < lines.count {
                    let next = lines[blockEnd]
                    if next.hasPrefix("  - id:") { break }
                    if !next.hasPrefix("    ") { break }
                    blockEnd += 1
                }
                let block = lines[i..<blockEnd]
                let hasMatchingChannel = block.contains(where: { $0.trimmingCharacters(in: .whitespaces) == "channel: \(channel)" })
                if hasMatchingChannel {
                    lines.removeSubrange(i..<blockEnd)
                    continue  // don't advance i; next entry is now at i
                }
                i = blockEnd
            } else {
                i += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func removeSpeakerDatabaseLinkFromFrontmatter(
        in content: inout String,
        update: SpeakerNameUpdate
    ) {
        guard let frontmatterRange = frontmatterContentRange(in: content) else { return }

        var lines = String(content[frontmatterRange])
            .components(separatedBy: "\n")

        let targetIdLine = #"id: "\#(update.diarizerSpeakerId)""#
        var lineIndex = 0

        while lineIndex < lines.count {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "),
                  trimmed.contains(targetIdLine) else {
                lineIndex += 1
                continue
            }

            var nextEntryIndex: Int
            if lineIndex + 1 < lines.count {
                nextEntryIndex = lines[(lineIndex + 1)..<lines.count].firstIndex(where: { candidate in
                    candidate.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
                }) ?? lines.count
            } else {
                nextEntryIndex = lines.count
            }

            var dbIdIndex: Int?
            var confidenceIndex: Int?
            var sourceIndex: Int?

            if lineIndex + 1 < nextEntryIndex {
                for index in (lineIndex + 1)..<nextEntryIndex {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("db_id:") {
                        dbIdIndex = index
                    } else if candidate.hasPrefix("confidence:") {
                        confidenceIndex = index
                    } else if candidate.hasPrefix("source:") {
                        sourceIndex = index
                    }
                }
            }

            let block = lines[lineIndex..<nextEntryIndex]
            guard speakerBlockMatchesChannel(block, channel: update.channel) else {
                lineIndex = nextEntryIndex
                continue
            }

            if let dbIdIndex {
                lines.remove(at: dbIdIndex)
                nextEntryIndex -= 1
                if let index = confidenceIndex, index > dbIdIndex {
                    confidenceIndex = index - 1
                }
                if let index = sourceIndex, index > dbIdIndex {
                    sourceIndex = index - 1
                }
            }

            if let confidenceIndex {
                lines[confidenceIndex] = "    confidence: unknown"
            }

            if let sourceIndex {
                lines[sourceIndex] = "    source: unknown"
            } else {
                lines.insert("    source: unknown", at: min(nextEntryIndex, lines.count))
            }

            content.replaceSubrange(frontmatterRange, with: lines.joined(separator: "\n"))
            return
        }
    }

}
