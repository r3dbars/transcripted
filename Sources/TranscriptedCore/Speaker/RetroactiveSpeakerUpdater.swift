import Foundation

// MARK: - Retroactive Speaker Updates

extension TranscriptSaver {

    /// When a speaker is renamed in Settings, update ALL transcripts that reference them.
    /// Finds transcripts by searching YAML for the speaker's db_id, extracts the old name,
    /// and replaces it in both YAML frontmatter and transcript body.
    /// Thread-safe: serialized via fileUpdateQueue to prevent concurrent file corruption.
    /// Satisfies the `TranscriptStorage` protocol — uses `defaultSaveDirectory`.
    public static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String) {
        fileUpdateQueue.sync {
            _retroactivelyUpdateSpeakerImpl(dbId: dbId, newName: newName, directory: defaultSaveDirectory)
        }
    }

    /// Internal overload for tests — scans a specific directory instead of `defaultSaveDirectory`.
    static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String, in directory: URL) {
        fileUpdateQueue.sync {
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
        fileUpdateQueue.sync {
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
        fileUpdateQueue.sync {
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
        fileUpdateQueue.sync {
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
        var updatedCount = 0

        for fileURL in transcriptMarkdownFiles(under: directory) {
            guard var content = try? String(contentsOf: fileURL, encoding: .utf8),
                  content.contains("db_id: \"\(dbIdString)\"") else { continue }

            guard applyRetroactiveRename(
                in: &content,
                dbId: dbId,
                newName: newName,
                fileName: fileURL.lastPathComponent
            ) else { continue }

            // Write back atomically
            do {
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
        var updatedCount = 0

        for fileURL in transcriptMarkdownFiles(under: directory) {
            guard var content = try? String(contentsOf: fileURL, encoding: .utf8),
                  content.contains("db_id: \"\(sourceIdString)\"") else { continue }

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

    /// Markdown transcripts under the capture directory, including user-created
    /// subfolders. Depth-bounded so audio bundles and deep trees stay cheap;
    /// the db_id frontmatter check still gates every write.
    private static func transcriptMarkdownFiles(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > 4 {
                enumerator.skipDescendants()
                continue
            }
            if url.pathExtension == "md" {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    private struct FrontmatterSpeakerRow {
        var nameLineIndex: Int?
        var channel: UtteranceChannel?
        var dbId: UUID?
        var name: String?
    }

    /// Parse the `speakers:` rows out of YAML frontmatter. Tolerates rows without
    /// a channel field (older dictation-era transcripts).
    private static func parseFrontmatterSpeakerRows(in lines: [String]) -> [FrontmatterSpeakerRow] {
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return [] }

        var rows: [FrontmatterSpeakerRow] = []
        var current: FrontmatterSpeakerRow?
        var inSpeakers = false
        var speakersIndent = 0

        for index in 1..<lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { break }

            if !inSpeakers {
                if trimmed == "speakers:" {
                    inSpeakers = true
                    speakersIndent = line.prefix(while: { $0 == " " }).count
                }
                continue
            }

            let indent = line.prefix(while: { $0 == " " }).count
            if !trimmed.isEmpty, indent <= speakersIndent, !trimmed.hasPrefix("-") {
                break
            }

            if trimmed.hasPrefix("- ") {
                if let row = current { rows.append(row) }
                current = FrontmatterSpeakerRow()
            }
            guard current != nil else { continue }

            if let value = extractYAMLQuotedString(from: line, prefix: "db_id: ") {
                current?.dbId = UUID(uuidString: value)
            } else if let value = extractYAMLQuotedString(from: line, prefix: "name: ") {
                current?.name = value
                current?.nameLineIndex = index
            } else if trimmed.hasPrefix("channel: ") {
                let raw = String(trimmed.dropFirst("channel: ".count)).trimmingCharacters(in: .whitespaces)
                current?.channel = UtteranceChannel(rawValue: raw)
            }
        }
        if let row = current { rows.append(row) }
        return rows
    }

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

        return fileUpdateQueue.sync {
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

        return fileUpdateQueue.sync {
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

        return fileUpdateQueue.sync {
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

        return fileUpdateQueue.sync {
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

        return fileUpdateQueue.sync {
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

    @discardableResult
    private static func replaceTranscriptSpeakerLabels(
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

    @discardableResult
    private static func replaceSpeakerBreakdownName(
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

        let footerCandidates = [
            "\n\n#### ",
            "\n\n### ",
            "\n\n## ",
            "\n\n---\n\n",
            "\n#### ",
            "\n### ",
            "\n## ",
            "\n---\n",
        ]
        let footerStart = footerCandidates
            .compactMap { content.range(of: $0, range: headerRange.upperBound..<content.endIndex)?.lowerBound }
            .min() ?? content.endIndex
        return headerRange.upperBound..<footerStart
    }

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

    private static func applyScopedTranscriptLabelReplacements(
        in content: inout String,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        result: TranscriptionResult
    ) -> Bool {
        var replacementPlans: [(prefix: String, oldName: String, newName: String)] = []
        for key in updatesByChannelKey.keys.sorted() {
            guard let update = updatesByChannelKey[key] else { continue }
            guard update.oldName != update.newName else { continue }
            guard let target = channelAndDiarizerID(forSpeakerKey: key) else { return false }
            let prefix = target.channel == .mic ? "Mic" : "System"
            let expectedCount = expectedVisibleUtteranceCount(
                in: result,
                channel: target.channel,
                diarizerSpeakerId: target.diarizerSpeakerId
            )
            let labelCount = countTranscriptSpeakerLabels(
                in: content,
                prefix: prefix,
                oldName: update.oldName
            )
            if expectedCount == 0 {
                guard labelCount == 0 else { return false }
                continue
            }
            guard labelCount == expectedCount else {
                return false
            }
            replacementPlans.append((prefix: prefix, oldName: update.oldName, newName: update.newName))
        }

        guard !hasCascadingScopedNameReplacement(in: replacementPlans) else {
            return false
        }

        for plan in replacementPlans {
            let replaced = replaceTranscriptSpeakerLabels(
                in: &content,
                prefix: plan.prefix,
                oldName: plan.oldName,
                newName: plan.newName
            )
            guard replaced > 0 else { return false }
        }
        return true
    }

    private static func hasCascadingScopedNameReplacement(
        in plans: [(prefix: String, oldName: String, newName: String)]
    ) -> Bool {
        for plan in plans {
            guard plan.oldName != plan.newName else { continue }
            if plans.contains(where: {
                $0.prefix == plan.prefix
                    && $0.oldName != $0.newName
                    && $0.oldName == plan.newName
            }) {
                return true
            }
        }
        return false
    }

    private static func applyScopedBreakdownNameReplacements(
        in content: inout String,
        updatesByChannelKey: [String: (oldName: String, newName: String)],
        channels: Set<UtteranceChannel>,
        result: TranscriptionResult
    ) -> Bool {
        var replacementPlans: [(prefix: String, oldName: String, newName: String, channel: UtteranceChannel)] = []
        for key in updatesByChannelKey.keys.sorted() {
            guard let update = updatesByChannelKey[key],
                  let target = channelAndDiarizerID(forSpeakerKey: key),
                  channels.contains(target.channel) else {
                continue
            }
            let prefix = target.channel == .mic ? "Mic" : "System"
            guard update.oldName != update.newName else { continue }
            let expectedCount = expectedVisibleUtteranceCount(
                in: result,
                channel: target.channel,
                diarizerSpeakerId: target.diarizerSpeakerId
            )
            if expectedCount == 0 {
                guard countSpeakerBreakdownRows(
                    in: content,
                    oldName: update.oldName,
                    channel: target.channel
                ) == 0 else {
                    return false
                }
                continue
            }
            replacementPlans.append((prefix: prefix, oldName: update.oldName, newName: update.newName, channel: target.channel))
        }

        guard !hasCascadingScopedNameReplacement(in: replacementPlans.map {
            (prefix: $0.prefix, oldName: $0.oldName, newName: $0.newName)
        }) else {
            return false
        }

        for plan in replacementPlans {
            guard countSpeakerBreakdownRows(
                in: content,
                oldName: plan.oldName,
                channel: plan.channel
            ) == 1 else {
                return false
            }
        }

        for plan in replacementPlans {
            let replaced = replaceSpeakerBreakdownName(
                in: &content,
                oldName: plan.oldName,
                newName: plan.newName,
                channel: plan.channel
            )
            guard replaced == 1 else { return false }
        }
        return true
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

    /// Parse a YAML double-quoted string value after a known key prefix.
    /// Handles backslash escape sequences (`\"`, `\\`, etc.) and returns the unescaped value.
    /// Returns nil if the prefix is not found or the closing quote is missing.
    private static func extractYAMLQuotedString(from line: String, prefix: String) -> String? {
        let fullPrefix = prefix + "\""
        guard let prefixRange = line.range(of: fullPrefix) else { return nil }
        var index = prefixRange.upperBound
        var result = ""
        while index < line.endIndex {
            let c = line[index]
            index = line.index(after: index)
            if c == "\\" && index < line.endIndex {
                let next = line[index]
                index = line.index(after: index)
                switch next {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n":  result.append("\n")
                case "t":  result.append("\t")
                default:
                    result.append("\\")
                    result.append(next)
                }
            } else if c == "\"" {
                return result
            } else {
                result.append(c)
            }
        }
        return nil
    }

    static func extractTranscriptId(from url: URL) -> UUID? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        let header = handle.readData(ofLength: 2048)
        try? handle.close()
        guard let text = String(data: header, encoding: .utf8) else { return nil }
        return extractTranscriptId(fromFrontmatter: text)
    }

    private static func extractTranscriptId(fromFrontmatter text: String) -> UUID? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("transcript_id:") else { continue }
            let value = trimmed
                .dropFirst("transcript_id:".count)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return UUID(uuidString: value)
        }
        return nil
    }

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

    private static func currentSpeakerName(
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

    private static func rewriteFullTranscriptSection(
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

    private static func rewriteRemoteSpeakerBreakdown(
        in content: inout String,
        result: TranscriptionResult,
        updatesByChannelKey: [String: (oldName: String, newName: String)]
    ) -> Bool {
        guard !result.systemUtterances.isEmpty else { return true }
        guard content.contains("#### Remote Speaker Breakdown\n\n") else { return true }

        return rewriteSpeakerBreakdown(
            in: &content,
            header: "#### Remote Speaker Breakdown\n\n",
            utterances: result.systemUtterances,
            channel: .system,
            updatesByChannelKey: updatesByChannelKey
        )
    }

    private static func rewriteLocalSpeakerBreakdownIfPresent(
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

        let footerCandidates = [
            "\n\n#### ",
            "\n\n### ",
            "\n\n## ",
            "\n\n---\n\n",
            "\n#### ",
            "\n### ",
            "\n## ",
            "\n---\n",
        ]
        guard let footerRange = footerCandidates.compactMap({
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

    private static func isObsidianFormatted(_ content: String) -> Bool {
        content.contains("\ncssclasses:\n  - transcripted")
            || content.contains("\naliases:\n  - \"Meeting ")
    }

}

enum SpeakerBreakdownConsolidator {
    private static let breakdownHeader = "#### Remote Speaker Breakdown\n\n"
    private static let breakdownFooters = [
        "\n\n#### ",
        "\n\n### ",
        "\n\n## ",
        "\n\n---\n\n",
        "\n#### ",
        "\n### ",
        "\n## ",
        "\n---\n",
    ]
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

        let footerStart = breakdownFooters.compactMap({
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
