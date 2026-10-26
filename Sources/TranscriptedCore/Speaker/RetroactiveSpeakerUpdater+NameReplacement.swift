import Foundation

// MARK: - Retroactive Speaker Updates: Name Replacement and Frontmatter Metadata
//
// Moved out of RetroactiveSpeakerUpdater.swift unchanged: transcript URL
// resolution, scoped name replacement, and frontmatter speaker metadata helpers.

extension TranscriptSaver {

    /// Resolve a transcript URL that may have been renamed by MeetingTranscriptStyler.
    /// Uses the canonical stable-identity resolver shared with recovery flows.
    static func resolveTranscriptURL(_ url: URL, transcriptId: UUID) -> URL? {
        if let frontmatter = try? TranscriptFrontmatter.readValues(from: url),
           TranscriptFrontmatter.captureID(in: frontmatter) == transcriptId {
            return url
        }

        let dir = url.deletingLastPathComponent()
        guard let resolvedURL = existingTranscriptURL(in: dir, transcriptId: transcriptId) else {
            AppLogger.pipeline.error("Failed to resolve transcript by stable id", [
                "expected": url.lastPathComponent,
                "transcriptId": transcriptId.uuidString
            ])
            return nil
        }

        let logicalResolvedURL = dir.appendingPathComponent(resolvedURL.lastPathComponent)
        if logicalResolvedURL.standardizedFileURL != url.standardizedFileURL {
            AppLogger.pipeline.info("Resolved renamed transcript", [
                "from": url.lastPathComponent,
                "to": logicalResolvedURL.lastPathComponent
            ])
        }
        return logicalResolvedURL
    }

    /// Replace all occurrences of a speaker name throughout a transcript's YAML and body.
    /// Handles YAML frontmatter, body labels, wiki links, and speaker breakdown.
    /// Pass `updateSpeakerTag: true` when the old name also has an Obsidian tag to rename.
    static func applyNameReplacement(in content: inout String, oldName: String, newName: String, updateSpeakerTag: Bool) {
        // Security: YAML-escape both names before matching and replacing double-quoted scalars.
        let yamlSafeOldName = escapeYAML(oldName)
        let yamlSafeName = escapeYAML(newName)
        content = content.replacingOccurrences(of: "name: \"\(yamlSafeOldName)\"", with: "name: \"\(yamlSafeName)\"")
        content = content.replacingOccurrences(of: "[System/\(oldName)]", with: "[System/\(newName)]")
        content = content.replacingOccurrences(of: "[Mic/\(oldName)]", with: "[Mic/\(newName)]")
        content = content.replacingOccurrences(of: "[[\(oldName)]]", with: "[[\(newName)]]")
        content = content.replacingOccurrences(of: "**\(oldName):**", with: "**\(newName):**")

        if updateSpeakerTag {
            let oldTag = "speaker/\(oldName.replacingOccurrences(of: " ", with: "-").lowercased())"
            let newTag = "speaker/\(newName.replacingOccurrences(of: " ", with: "-").lowercased())"
            content = content.replacingOccurrences(of: oldTag, with: newTag)
        }
    }

    static func applyScopedNameReplacement(
        in content: inout String,
        oldName: String,
        newName: String,
        channel: UtteranceChannel
    ) {
        let prefix = channel == .mic ? "Mic" : "System"
        replaceTranscriptSpeakerLabels(
            in: &content,
            prefix: prefix,
            oldName: oldName,
            newName: newName
        )
        replaceSpeakerBreakdownName(
            in: &content,
            oldName: oldName,
            newName: newName,
            channel: channel
        )
    }

    // replaceTranscriptSpeakerLabels / countTranscriptSpeakerLabels / isTranscriptLabelPrefix
    // moved to RetroactiveSpeakerUpdater+TranscriptRewrite.swift.
    // replaceSpeakerBreakdownName / countSpeakerBreakdownRows / speakerBreakdownContentRange
    // moved to RetroactiveSpeakerUpdater+BreakdownRewrite.swift. (audit 2026-07-08 wave 2)

    static func makeSpeakerNameChangesByChannelKey(
        updates: [SpeakerNameUpdate],
        content: String
    ) -> [String: (oldName: String, newName: String)] {
        var changes: [String: (oldName: String, newName: String)] = [:]
        for update in updates {
            let key = update.channel.speakerKey(diarizerSpeakerId: update.diarizerSpeakerId)
            changes[key] = (
                oldName: currentSpeakerName(
                    in: content,
                    diarizerSpeakerId: update.diarizerSpeakerId,
                    channel: update.channel
                )
                    ?? "Speaker \(update.diarizerSpeakerId)",
                newName: update.newName
            )
        }
        return changes
    }

    /// Shared engine behind `applyScopedTranscriptLabelReplacements` (transcript
    /// body labels) and `applyScopedBreakdownNameReplacements` (speaker breakdown
    /// rows): both are used as a fallback when a full-section rewrite can't prove
    /// itself unambiguous. Each builds a plan of pending speaker-name swaps gated on
    /// an exact occurrence-count match (so a rename is skipped rather than partially
    /// applied when the document's counts don't line up with what's expected), then
    /// stages the swaps behind placeholder tokens before resolving them to the real
    /// new names, so overlapping old/new names can't collide mid-pass.
    ///
    /// The two callers differ in:
    /// - whether a key with no resolvable channel/diarizer target is a hard failure
    ///   (transcript) or a soft skip (breakdown, which is already scoped to specific
    ///   `channels` and expects unrelated keys to be skipped);
    /// - whether the occurrence count is checked while building the plan (transcript,
    ///   against the expected utterance count) or deferred to a second pass over the
    ///   built plans (breakdown, always requiring exactly one row); and
    /// - how "occurrences" are counted/replaced (transcript labels vs. breakdown rows)
    ///   and what a valid replaced-count looks like (`> 0` vs. `== 1`).
    ///
    /// Deduped from two ~80-line near-identical copies (audit 2026-07-08 wave 2).
    static func applyScopedReplacements(
        in content: inout String,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        result: TranscriptionResult,
        channelFilter: Set<UtteranceChannel>?,
        missingTargetFails: Bool,
        tokenKind: String,
        gateCountAtPlanTime: Bool,
        countOccurrences: (String, String, String, UtteranceChannel) -> Int,
        performReplace: (inout String, String, String, String, UtteranceChannel) -> Int,
        replacedCountIsValid: (Int) -> Bool
    ) -> Bool {
        var replacementPlans: [(prefix: String, oldName: String, newName: String, channel: UtteranceChannel)] = []

        for key in updatesByChannelKey.keys.sorted() {
            guard let update = updatesByChannelKey[key] else { continue }
            guard update.oldName != update.newName else { continue }

            guard let target = channelAndDiarizerID(forSpeakerKey: key) else {
                if missingTargetFails { return false }
                continue
            }
            if let channelFilter, !channelFilter.contains(target.channel) {
                continue
            }

            let prefix = target.channel == .mic ? "Mic" : "System"
            let expectedCount = expectedVisibleUtteranceCount(
                in: result,
                channel: target.channel,
                diarizerSpeakerId: target.diarizerSpeakerId
            )

            if expectedCount == 0 {
                guard countOccurrences(content, prefix, update.oldName, target.channel) == 0 else { return false }
                continue
            }

            if gateCountAtPlanTime {
                guard countOccurrences(content, prefix, update.oldName, target.channel) == expectedCount else {
                    return false
                }
            }

            replacementPlans.append((prefix: prefix, oldName: update.oldName, newName: update.newName, channel: target.channel))
        }

        if !gateCountAtPlanTime {
            for plan in replacementPlans {
                guard countOccurrences(content, plan.prefix, plan.oldName, plan.channel) == 1 else {
                    return false
                }
            }
        }

        var deferredReplacements: [(token: String, newName: String)] = []
        for (index, plan) in replacementPlans.enumerated() {
            let token = scopedReplacementToken(kind: tokenKind, index: index)
            let replaced = performReplace(&content, plan.prefix, plan.oldName, token, plan.channel)
            guard replacedCountIsValid(replaced) else { return false }
            deferredReplacements.append((token: token, newName: plan.newName))
        }
        applyDeferredScopedReplacements(in: &content, replacements: deferredReplacements)
        return true
    }

    private static func scopedReplacementToken(kind: String, index: Int) -> String {
        "__TRANSCRIPTED_SCOPED_\(kind.uppercased())_\(index)_\(UUID().uuidString)__"
    }

    private static func applyDeferredScopedReplacements(
        in content: inout String,
        replacements: [(token: String, newName: String)]
    ) {
        for replacement in replacements {
            content = content.replacingOccurrences(of: replacement.token, with: replacement.newName)
        }
    }

    private static func channelAndDiarizerID(forSpeakerKey key: String) -> (channel: UtteranceChannel, diarizerSpeakerId: Int)? {
        if key.hasPrefix("mic_"), let id = Int(key.dropFirst("mic_".count)) {
            return (.mic, id)
        }
        if key.hasPrefix("system_"), let id = Int(key.dropFirst("system_".count)) {
            return (.system, id)
        }
        return nil
    }

    private static func expectedVisibleUtteranceCount(
        in result: TranscriptionResult,
        channel: UtteranceChannel,
        diarizerSpeakerId: Int
    ) -> Int {
        let utterances = channel == .mic ? result.micUtterances : result.systemUtterances
        return utterances.filter {
            $0.speakerId == diarizerSpeakerId
                && !$0.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    // extractYAMLQuotedString moved to RetroactiveSpeakerUpdater+Scanning.swift.

    static func updateFrontmatterSpeakerMetadata(
        in content: inout String,
        update: SpeakerNameUpdate
    ) {
        writeFrontmatterSpeakerMetadata(
            in: &content,
            diarizerSpeakerId: update.diarizerSpeakerId,
            channel: update.channel,
            persistentSpeakerId: update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId,
            name: update.newName,
            source: NameSource.userManual
        )
    }

    static func writeFrontmatterSpeakerMetadata(
        in content: inout String,
        diarizerSpeakerId: String,
        channel: UtteranceChannel,
        persistentSpeakerId: UUID,
        name: String,
        source: String
    ) {
        guard let frontmatterRange = frontmatterContentRange(in: content) else { return }

        var lines = String(content[frontmatterRange])
            .components(separatedBy: "\n")

        let targetIdLine = #"id: "\#(diarizerSpeakerId)""#
        let resolvedPersistentId = persistentSpeakerId.uuidString
        var lineIndex = 0

        while lineIndex < lines.count {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "),
                  trimmed.contains(targetIdLine) else {
                lineIndex += 1
                continue
            }

            let nextEntryIndex: Int
            if lineIndex + 1 < lines.count {
                nextEntryIndex = lines[(lineIndex + 1)..<lines.count].firstIndex(where: { candidate in
                    candidate.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
                }) ?? lines.count
            } else {
                nextEntryIndex = lines.count
            }

            var dbIdIndex: Int?
            var nameIndex: Int?
            var sourceIndex: Int?

            if lineIndex + 1 < nextEntryIndex {
                for index in (lineIndex + 1)..<nextEntryIndex {
                    let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                    if candidate.hasPrefix("db_id:") {
                        dbIdIndex = index
                    } else if candidate.hasPrefix("name:") {
                        nameIndex = index
                    } else if candidate.hasPrefix("source:") {
                        sourceIndex = index
                    }
                }
            }

            let block = lines[lineIndex..<nextEntryIndex]
            guard speakerBlockMatchesChannel(block, channel: channel) else {
                lineIndex = nextEntryIndex
                continue
            }

            let dbIdLine = #"    db_id: "\#(resolvedPersistentId)""#
            let nameLine = #"    name: "\#(escapeYAML(name))""#
            let sourceLine = "    source: \(source)"
            var nextInsertIndex = lineIndex + 1

            if let dbIdIndex {
                lines[dbIdIndex] = dbIdLine
                nextInsertIndex = dbIdIndex + 1
            } else {
                lines.insert(dbIdLine, at: nextInsertIndex)
                if let existingNameIndex = nameIndex, existingNameIndex >= nextInsertIndex {
                    nameIndex = existingNameIndex + 1
                }
                if let existingSourceIndex = sourceIndex, existingSourceIndex >= nextInsertIndex {
                    sourceIndex = existingSourceIndex + 1
                }
                nextInsertIndex += 1
            }

            if let nameIndex {
                lines[nameIndex] = nameLine
                nextInsertIndex = nameIndex + 1
            } else {
                lines.insert(nameLine, at: nextInsertIndex)
                if let existingSourceIndex = sourceIndex, existingSourceIndex >= nextInsertIndex {
                    sourceIndex = existingSourceIndex + 1
                }
                nextInsertIndex += 1
            }

            if let sourceIndex {
                lines[sourceIndex] = sourceLine
            } else {
                lines.insert(sourceLine, at: nextInsertIndex)
            }

            content.replaceSubrange(frontmatterRange, with: lines.joined(separator: "\n"))
            return
        }
    }

    static func frontmatterContentRange(in content: String) -> Range<String.Index>? {
        guard content.hasPrefix("---\n"),
              let endRange = content.range(
                of: "\n---\n",
                range: content.index(content.startIndex, offsetBy: 4)..<content.endIndex
              ) else {
            return nil
        }

        return content.index(content.startIndex, offsetBy: 4)..<endRange.lowerBound
    }

    static func currentSpeakerName(
        in content: String,
        diarizerSpeakerId: String,
        channel: UtteranceChannel
    ) -> String? {
        guard let frontmatterRange = frontmatterContentRange(in: content) else { return nil }

        let lines = String(content[frontmatterRange]).components(separatedBy: "\n")
        let targetIdLine = #"id: "\#(diarizerSpeakerId)""#
        var lineIndex = 0

        while lineIndex < lines.count {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "), trimmed.contains(targetIdLine) else {
                lineIndex += 1
                continue
            }

            let nextEntryIndex = lines[(lineIndex + 1)..<lines.count].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
            }) ?? lines.count

            let block = lines[lineIndex..<nextEntryIndex]
            guard speakerBlockMatchesChannel(block, channel: channel) else {
                lineIndex = nextEntryIndex
                continue
            }

            for index in (lineIndex + 1)..<nextEntryIndex {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                guard candidate.hasPrefix("name:") else { continue }
                // Names are written through `escapeYAML`. Unescape them, or a name
                // with `"` or `\` comes back with stray backslashes: the scoped
                // fallback then searches for a label that isn't in the body, and
                // the breakdown rewrite prints the mangled name for speakers that
                // were not part of this update.
                if let quotedName = extractYAMLQuotedString(from: candidate, prefix: "name: ") {
                    return quotedName
                }
                return candidate
                    .dropFirst("name:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }

            return nil
        }

        return nil
    }

    static func currentSpeakerName(
        in content: String,
        diarizerSpeakerId: String,
        channel: UtteranceChannel,
        matchingDbId dbId: UUID
    ) -> String? {
        guard let frontmatterRange = frontmatterContentRange(in: content) else { return nil }

        let lines = String(content[frontmatterRange]).components(separatedBy: "\n")
        let targetIdLine = #"id: "\#(diarizerSpeakerId)""#
        let targetDbId = dbId.uuidString
        var lineIndex = 0

        while lineIndex < lines.count {
            let trimmed = lines[lineIndex].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- "), trimmed.contains(targetIdLine) else {
                lineIndex += 1
                continue
            }

            let nextEntryIndex = lines[(lineIndex + 1)..<lines.count].firstIndex(where: {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("- ")
            }) ?? lines.count

            let block = lines[lineIndex..<nextEntryIndex]
            guard speakerBlockMatchesChannel(block, channel: channel),
                  block.contains(where: { line in
                      let trimmed = line.trimmingCharacters(in: .whitespaces)
                      return trimmed == #"db_id: "\#(targetDbId)""# || trimmed == "db_id: \(targetDbId)"
                  }) else {
                lineIndex = nextEntryIndex
                continue
            }

            for index in (lineIndex + 1)..<nextEntryIndex {
                let candidate = lines[index].trimmingCharacters(in: .whitespaces)
                guard candidate.hasPrefix("name:") else { continue }
                return extractYAMLQuotedString(from: candidate, prefix: "name: ")
            }

            return nil
        }

        return nil
    }

    static func speakerBlockMatchesChannel(
        _ block: ArraySlice<String>,
        channel: UtteranceChannel
    ) -> Bool {
        let expectedLine = "channel: \(channel.rawValue)"
        let normalizedBlock = block.map { $0.trimmingCharacters(in: .whitespaces) }
        if normalizedBlock.contains(expectedLine) {
            return true
        }

        // Older transcripts predate explicit channel metadata. Treat a missing channel
        // line as the legacy system-audio case so historical rename flows still work.
        if channel == .system {
            return !normalizedBlock.contains(where: { $0.hasPrefix("channel:") })
        }

        return false
    }

    // rewriteFullTranscriptSection and its legacy/styled transcript-section helpers
    // moved to RetroactiveSpeakerUpdater+TranscriptRewrite.swift. rewriteRemoteSpeakerBreakdown,
    // rewriteLocalSpeakerBreakdownIfPresent, and rewriteSpeakerBreakdown moved to
    // RetroactiveSpeakerUpdater+BreakdownRewrite.swift. (audit 2026-07-08 wave 2)

    static func isObsidianFormatted(_ content: String) -> Bool {
        content.contains("\ncssclasses:\n  - transcripted")
            || content.contains("\naliases:\n  - \"Meeting ")
    }

}
