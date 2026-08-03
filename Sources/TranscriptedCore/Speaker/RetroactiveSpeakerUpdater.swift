import Foundation

// MARK: - Retroactive Speaker Updates

extension TranscriptSaver {

    /// When a speaker is renamed in Settings, update ALL transcripts that reference them.
    /// Finds transcripts by searching YAML for the speaker's db_id, extracts the old name,
    /// and replaces it in both YAML frontmatter and transcript body.
    /// Thread-safe: serialized via fileUpdateQueue to prevent concurrent file corruption.
    /// Satisfies the `TranscriptStorage` protocol — uses `defaultSaveDirectory`.
    public static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String) {
        serializeTranscriptFileUpdate {
            _retroactivelyUpdateSpeakerImpl(dbId: dbId, newName: newName, directory: defaultSaveDirectory)
        }
    }

    /// Internal overload for tests — scans a specific directory instead of `defaultSaveDirectory`.
    static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String, in directory: URL) {
        serializeTranscriptFileUpdate {
            _retroactivelyUpdateSpeakerImpl(dbId: dbId, newName: newName, directory: directory)
        }
    }

    /// Name one deferred review row in its saved transcript.
    ///
    /// Deferred rows can reuse labels across channels, e.g. both `Mic/Speaker 1`
    /// and `System/Speaker 1` in the same meeting. This path scopes the rewrite
    /// to the queued row's transcript, channel, diarizer id, and database id so
    /// naming one row cannot rename its channel-local neighbor.
    @discardableResult
    public static func updateDeferredSpeakerName(
        transcriptURL: URL,
        dbId: UUID,
        diarizerSpeakerId: String,
        channel: UtteranceChannel,
        newName: String
    ) -> Bool {
        serializeTranscriptFileUpdate {
            _updateDeferredSpeakerNameImpl(
                transcriptURL: transcriptURL,
                dbId: dbId,
                diarizerSpeakerId: diarizerSpeakerId,
                channel: channel,
                newName: newName
            )
        }
    }

    /// After Settings merges two people, rewrite old source profile references to the
    /// kept profile id so future renames of the kept person still reach older transcripts.
    public static func retroactivelyMergeSpeaker(sourceDbId: UUID, targetDbId: UUID, targetName: String) {
        serializeTranscriptFileUpdate {
            _retroactivelyMergeSpeakerImpl(
                sourceDbId: sourceDbId,
                targetDbId: targetDbId,
                targetName: targetName,
                directory: defaultSaveDirectory
            )
        }
    }

    /// Internal overload for tests — scans a specific directory instead of `defaultSaveDirectory`.
    static func retroactivelyMergeSpeaker(sourceDbId: UUID, targetDbId: UUID, targetName: String, in directory: URL) {
        serializeTranscriptFileUpdate {
            _retroactivelyMergeSpeakerImpl(
                sourceDbId: sourceDbId,
                targetDbId: targetDbId,
                targetName: targetName,
                directory: directory
            )
        }
    }

    private static func _retroactivelyUpdateSpeakerImpl(
        dbId: UUID,
        newName: String,
        directory: URL
    ) {
        let dbIdString = dbId.uuidString
        let dbIdNeedle = "db_id: \"\(dbIdString)\""
        var updatedCount = 0

        for fileURL in transcriptMarkdownFiles(under: directory) {
            guard scanFrontmatter(at: fileURL, for: dbIdNeedle) != .notMatched else { continue }
            guard var content = try? String(contentsOf: fileURL, encoding: .utf8),
                  content.contains(dbIdNeedle) else { continue }

            guard applyRetroactiveRename(
                in: &content,
                dbId: dbId,
                newName: newName,
                fileName: fileURL.lastPathComponent
            ) else { continue }

            // Write back atomically
            do {
                guard FileManager.default.fileExists(atPath: fileURL.path) else {
                    AppLogger.pipeline.warning("Skipped retroactive speaker update because transcript moved before write", [
                        "file": fileURL.lastPathComponent
                    ])
                    continue
                }
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
                restrictTranscriptToOwnerOnly(fileURL)
                updatedCount += 1
            } catch {
                AppLogger.pipeline.warning("Failed to update transcript retroactively", ["file": fileURL.lastPathComponent, "error": error.localizedDescription])
            }
        }

        if updatedCount > 0 {
            AppLogger.pipeline.info("Retroactively updated speaker in transcripts",
                ["dbId": dbIdString, "name": newName, "files": "\(updatedCount)"])
        }
    }

    private static func _updateDeferredSpeakerNameImpl(
        transcriptURL: URL,
        dbId: UUID,
        diarizerSpeakerId: String,
        channel: UtteranceChannel,
        newName: String
    ) -> Bool {
        guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            AppLogger.pipeline.error("Failed to read deferred speaker transcript", ["path": transcriptURL.path])
            return false
        }

        guard let oldName = currentSpeakerName(
            in: content,
            diarizerSpeakerId: diarizerSpeakerId,
            channel: channel,
            matchingDbId: dbId
        ) else {
            AppLogger.pipeline.warning("Deferred speaker metadata no longer matches queued row", [
                "path": transcriptURL.lastPathComponent,
                "dbId": dbId.uuidString,
                "diarizerSpeakerId": diarizerSpeakerId,
                "channel": channel.rawValue
            ])
            return false
        }

        writeFrontmatterSpeakerMetadata(
            in: &content,
            diarizerSpeakerId: diarizerSpeakerId,
            channel: channel,
            persistentSpeakerId: dbId,
            name: newName,
            source: NameSource.userManual
        )
        applyScopedNameReplacement(
            in: &content,
            oldName: oldName,
            newName: newName,
            channel: channel
        )
        content = SpeakerBreakdownConsolidator.consolidate(content)

        do {
            try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
            restrictTranscriptToOwnerOnly(transcriptURL)
            return true
        } catch {
            AppLogger.pipeline.warning("Failed to update deferred speaker transcript", [
                "file": transcriptURL.lastPathComponent,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    private static func _retroactivelyMergeSpeakerImpl(
        sourceDbId: UUID,
        targetDbId: UUID,
        targetName: String,
        directory: URL
    ) {
        let sourceIdString = sourceDbId.uuidString
        let targetIdString = targetDbId.uuidString
        let sourceIdNeedle = "db_id: \"\(sourceIdString)\""
        var updatedCount = 0

        for fileURL in transcriptMarkdownFiles(under: directory) {
            guard scanFrontmatter(at: fileURL, for: sourceIdNeedle) != .notMatched else { continue }
            guard var content = try? String(contentsOf: fileURL, encoding: .utf8),
                  content.contains(sourceIdNeedle) else { continue }

            applyRetroactiveRename(
                in: &content,
                dbId: sourceDbId,
                newName: targetName,
                fileName: fileURL.lastPathComponent
            )
            content = content.replacingOccurrences(
                of: "db_id: \"\(sourceIdString)\"",
                with: "db_id: \"\(targetIdString)\""
            )

            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
                restrictTranscriptToOwnerOnly(fileURL)
                updatedCount += 1
            } catch {
                AppLogger.pipeline.warning("Failed to update merged speaker transcript", [
                    "file": fileURL.lastPathComponent,
                    "error": error.localizedDescription
                ])
            }
        }

        if updatedCount > 0 {
            AppLogger.pipeline.info("Retroactively merged speaker in transcripts", [
                "sourceDbId": sourceIdString,
                "targetDbId": targetIdString,
                "files": "\(updatedCount)"
            ])
        }
    }

    // MARK: - Settings Rename/Merge Helpers
    //
    // File scanning (transcriptMarkdownFiles, scanFrontmatter), frontmatter row
    // parsing (FrontmatterSpeakerRow, parseFrontmatterSpeakerRows), and YAML value
    // extraction (extractYAMLQuotedString, extractTranscriptId) live in
    // RetroactiveSpeakerUpdater+Scanning.swift (audit 2026-07-08 wave 2).

    /// Rename one person (by db_id) inside a single transcript without bleeding into
    /// other speakers who share the old display name.
    ///
    /// - YAML `name:` lines are rewritten row-targeted, only for rows matching `dbId`.
    /// - When the old name is unique to this db_id in the file, the historical full
    ///   replacement (labels, wiki links, breakdown, speaker tag) is unambiguous and
    ///   applies as before.
    /// - When another speaker row shares the old name, body labels are rewritten only
    ///   on channels free of the same-name conflict; wiki links and tags are left
    ///   untouched and the skip is logged. Fails closed rather than corrupting.
    ///
    /// Returns true when the content was modified.
    @discardableResult
    private static func applyRetroactiveRename(
        in content: inout String,
        dbId: UUID,
        newName: String,
        fileName: String
    ) -> Bool {
        var lines = content.components(separatedBy: "\n")
        let rows = parseFrontmatterSpeakerRows(in: lines)
        let targetRows = rows.filter { $0.dbId == dbId && $0.name != nil && $0.name != newName }
        guard !targetRows.isEmpty else { return false }

        var changed = false

        // 1) Row-targeted YAML rename for the matching speaker rows only.
        for row in targetRows {
            guard let index = row.nameLineIndex else { continue }
            let indent = lines[index].prefix(while: { $0 == " " })
            lines[index] = "\(indent)name: \"\(escapeYAML(newName))\""
            changed = true
        }
        content = lines.joined(separator: "\n")

        // 2) Body labels, guarded against shared-name bleed.
        let targetRowsByName = Dictionary(grouping: targetRows, by: { $0.name ?? "" })
        for (oldName, rowsForName) in targetRowsByName {
            let conflictChannels = Set(
                rows.filter { $0.dbId != dbId && $0.name == oldName }.compactMap { $0.channel }
            )
            let hasAnyConflict = rows.contains { $0.dbId != dbId && $0.name == oldName }

            if !hasAnyConflict {
                applyNameReplacement(in: &content, oldName: oldName, newName: newName, updateSpeakerTag: true)
                changed = true
                continue
            }

            let rowChannels = Set(rowsForName.compactMap { $0.channel })
            var skippedChannels: [String] = []
            var renamedChannels: [String] = []

            if rowChannels.isEmpty {
                // Channel-less legacy rows with a same-name conflict: nothing in the
                // body can be attributed safely.
                skippedChannels.append("unknown")
            } else {
                for channel in rowChannels {
                    if conflictChannels.contains(channel) {
                        skippedChannels.append(channel.rawValue)
                        continue
                    }
                    applyScopedNameReplacement(
                        in: &content,
                        oldName: oldName,
                        newName: newName,
                        channel: channel
                    )
                    renamedChannels.append(channel.rawValue)
                    changed = true
                }
            }

            AppLogger.pipeline.warning("Speaker rename hit a shared display name; scoped body rewrite", [
                "file": fileName,
                "renamedChannels": renamedChannels.joined(separator: ","),
                "skippedChannels": skippedChannels.joined(separator: ",")
            ])
        }

        return changed
    }

    // MARK: - Speaker Name Updating (Post-Naming Flow)

    /// Preserve a deferred speaker review without applying a name.
    /// This keeps transcript labels generic, but refreshes frontmatter db_id/source
    /// so Settings > People can safely name the right local profile later.
    @discardableResult
    public static func markSpeakerReviewDeferred(
        transcriptURL: URL,
        entries: [SpeakerNamingEntry],
        redirectedSpeakerIdsByKey: [String: UUID]
    ) -> Bool {
        guard !entries.isEmpty else { return true }

        return serializeTranscriptFileUpdate {
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for deferred speaker review", ["path": transcriptURL.path])
                return false
            }

            for entry in entries {
                let key = entry.channel.speakerKey(diarizerSpeakerId: entry.diarizerSpeakerId)
                let speakerId = redirectedSpeakerIdsByKey[key] ?? entry.id
                writeFrontmatterSpeakerMetadata(
                    in: &content,
                    diarizerSpeakerId: entry.diarizerSpeakerId,
                    channel: entry.channel,
                    persistentSpeakerId: speakerId,
                    name: "Speaker \(entry.diarizerSpeakerId)",
                    source: "db_pending"
                )
            }

            do {
                try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
                restrictTranscriptToOwnerOnly(transcriptURL)
            } catch {
                AppLogger.pipeline.error("Failed to write deferred speaker review metadata", ["error": error.localizedDescription])
                return false
            }

            AppLogger.pipeline.info("Deferred speaker review metadata saved", [
                "path": transcriptURL.lastPathComponent,
                "speakers": "\(entries.count)"
            ])
            return true
        }
    }

    /// Simplified overload for transcripts that started with generic speaker labels and have no
    /// TranscriptionResult available. Updates frontmatter db_id/name and replaces generic speaker
    /// labels in the body.
    /// Thread-safe: serialized via fileUpdateQueue.
    @discardableResult
    public static func updateSpeakerNames(
        transcriptURL: URL,
        updates: [SpeakerNameUpdate],
        speakerStoreForIndex: any SpeakerStore
    ) -> Bool {
        guard !updates.isEmpty else { return true }

        return serializeTranscriptFileUpdate {
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for name update (generic)", ["path": transcriptURL.path])
                return false
            }

            // Update frontmatter db_id / name / source for each speaker.
            for update in updates {
                updateFrontmatterSpeakerMetadata(in: &content, update: update)
            }

            // Replace generic labels (e.g. "Speaker 0") throughout the body.
            for update in updates {
                let genericLabel = "Speaker \(update.diarizerSpeakerId)"
                applyNameReplacement(in: &content, oldName: genericLabel, newName: update.newName, updateSpeakerTag: false)
            }

            do {
                try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
                restrictTranscriptToOwnerOnly(transcriptURL)
            } catch {
                AppLogger.pipeline.error("Failed to write updated transcript (generic)", ["error": error.localizedDescription])
                return false
            }

            AppLogger.pipeline.info("Updated generic speaker names in transcript", [
                "path": transcriptURL.lastPathComponent,
                "updates": "\(updates.count)"
            ])
            return true
        }
    }

    /// Update speaker names in an already-saved transcript file.
    /// Replaces "Speaker X" labels in both YAML frontmatter and transcript body.
    /// Thread-safe: serialized via fileUpdateQueue to prevent concurrent file corruption
    /// with retroactivelyUpdateSpeaker (called from Settings).
    ///
    /// - Parameters:
    ///   - transcriptURL: Path to the saved markdown transcript
    ///   - updates: Speaker name updates from the naming flow
    /// - Returns: true if the file was updated successfully
    @discardableResult
    public static func updateSpeakerNames(
        transcriptURL: URL,
        updates: [SpeakerNameUpdate],
        transcriptionResult: TranscriptionResult,
        speakerStore _: (any SpeakerStore)? = nil
    ) -> Bool {
        guard !updates.isEmpty else { return true }

        return serializeTranscriptFileUpdate {
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for name update", ["path": transcriptURL.path])
                return false
            }

            let obsidianEnabled = isObsidianFormatted(content)
            let updatesByChannelKey = makeSpeakerNameChangesByChannelKey(
                updates: updates,
                content: content
            )

            for update in updates {
                updateFrontmatterSpeakerMetadata(in: &content, update: update)
            }

            if !rewriteFullTranscriptSection(
                in: &content,
                result: transcriptionResult,
                updatesByChannelKey: updatesByChannelKey,
                obsidianEnabled: obsidianEnabled
            ) {
                AppLogger.pipeline.warning("Falling back to scoped transcript label updates", [
                    "path": transcriptURL.lastPathComponent
                ])
                guard applyScopedTranscriptLabelReplacements(
                    in: &content,
                    updatesByChannelKey: updatesByChannelKey,
                    result: transcriptionResult
                ) else {
                    AppLogger.pipeline.error("Scoped transcript label fallback was ambiguous", [
                        "path": transcriptURL.lastPathComponent
                    ])
                    return false
                }
            }

            if !rewriteRemoteSpeakerBreakdown(
                in: &content,
                result: transcriptionResult,
                updatesByChannelKey: updatesByChannelKey
            ) {
                AppLogger.pipeline.warning("Falling back to scoped remote speaker breakdown updates", [
                    "path": transcriptURL.lastPathComponent
                ])
                guard applyScopedBreakdownNameReplacements(
                    in: &content,
                    updatesByChannelKey: updatesByChannelKey,
                    channels: [.system],
                    result: transcriptionResult
                ) else {
                    AppLogger.pipeline.error("Scoped remote speaker breakdown fallback was ambiguous", [
                        "path": transcriptURL.lastPathComponent
                    ])
                    return false
                }
            }

            if !rewriteLocalSpeakerBreakdownIfPresent(
                in: &content,
                result: transcriptionResult,
                updatesByChannelKey: updatesByChannelKey
            ) {
                AppLogger.pipeline.warning("Falling back to scoped local speaker breakdown updates", [
                    "path": transcriptURL.lastPathComponent
                ])
                guard applyScopedBreakdownNameReplacements(
                    in: &content,
                    updatesByChannelKey: updatesByChannelKey,
                    channels: [.mic],
                    result: transcriptionResult
                ) else {
                    AppLogger.pipeline.error("Scoped local speaker breakdown fallback was ambiguous", [
                        "path": transcriptURL.lastPathComponent
                    ])
                    return false
                }
            }

            // Consolidate speaker breakdown when multiple diarizer IDs got the same name.
            // PyAnnote can over-segment one person into 2 clusters; after naming, both become
            // e.g. "Timothy", producing duplicate lines in the breakdown.
            content = SpeakerBreakdownConsolidator.consolidate(content)

            // Atomic write back
            do {
                try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
                restrictTranscriptToOwnerOnly(transcriptURL)
            } catch {
                AppLogger.pipeline.error("Failed to write updated transcript", ["error": error.localizedDescription])
                return false
            }

            AppLogger.pipeline.info("Updated speaker names in transcript", [
                "path": transcriptURL.lastPathComponent,
                "updates": "\(updates.count)"
            ])

            return true
        }
    }

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
    public static func collapseMicSpeakersToYou(
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
                try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
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
                try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
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

    private static func restrictTranscriptToOwnerOnly(_ transcriptURL: URL) {
        FileManager.default.restrictToOwnerOnly(atPath: transcriptURL.path)
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

    /// Resolve a transcript URL that may have been renamed by MeetingTranscriptStyler.
    /// Uses the stable transcript_id written at initial save time.
    static func resolveTranscriptURL(_ url: URL, transcriptId: UUID) -> URL? {
        if FileManager.default.fileExists(atPath: url.path),
           extractTranscriptId(from: url) == transcriptId {
            return url
        }

        AppLogger.pipeline.info("Transcript not at expected path, scanning for stable transcript id", [
            "expected": url.lastPathComponent,
            "transcriptId": transcriptId.uuidString
        ])

        let dir = url.deletingLastPathComponent()
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "md" }) else {
            return nil
        }

        for file in files {
            guard extractTranscriptId(from: file) == transcriptId else { continue }
            AppLogger.pipeline.info("Resolved renamed transcript", ["from": url.lastPathComponent, "to": file.lastPathComponent])
            return dir.appendingPathComponent(file.lastPathComponent)
        }

        AppLogger.pipeline.error("Failed to resolve transcript by stable id", [
            "expected": url.lastPathComponent,
            "transcriptId": transcriptId.uuidString
        ])
        return nil
    }

    /// Replace all occurrences of a speaker name throughout a transcript's YAML and body.
    /// Handles YAML frontmatter, body labels, wiki links, and speaker breakdown.
    /// Pass `updateSpeakerTag: true` when the old name also has an Obsidian tag to rename.
    private static func applyNameReplacement(in content: inout String, oldName: String, newName: String, updateSpeakerTag: Bool) {
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

    private static func applyScopedNameReplacement(
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

    private static func makeSpeakerNameChangesByChannelKey(
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

    // extractYAMLQuotedString / extractTranscriptId(from:) / extractTranscriptId(fromFrontmatter:)
    // moved to RetroactiveSpeakerUpdater+Scanning.swift. (audit 2026-07-08 wave 2)

    private static func updateFrontmatterSpeakerMetadata(
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

    private static func writeFrontmatterSpeakerMetadata(
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

    private static func frontmatterContentRange(in content: String) -> Range<String.Index>? {
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
                return candidate
                    .dropFirst("name:".count)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }

            return nil
        }

        return nil
    }

    private static func currentSpeakerName(
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

    private static func speakerBlockMatchesChannel(
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

    private static func isObsidianFormatted(_ content: String) -> Bool {
        content.contains("\ncssclasses:\n  - transcripted")
            || content.contains("\naliases:\n  - \"Meeting ")
    }

}
