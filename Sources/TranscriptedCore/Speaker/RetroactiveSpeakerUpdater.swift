import Foundation

// MARK: - Retroactive Speaker Updates

extension TranscriptSaver {

    enum DeferredSpeakerNameUpdateError: Error, LocalizedError, Equatable {
        case transcriptRestoreFailed(fileCount: Int)

        var errorDescription: String? {
            switch self {
            case .transcriptRestoreFailed(let count):
                return "Could not restore \(count) transcript(s) after the speaker update failed."
            }
        }
    }

    public struct DeferredSpeakerNameUpdate: Sendable {
        public let transcriptURL: URL
        public let dbId: UUID
        public let diarizerSpeakerId: String
        public let channel: UtteranceChannel

        public init(
            transcriptURL: URL,
            dbId: UUID,
            diarizerSpeakerId: String,
            channel: UtteranceChannel
        ) {
            self.transcriptURL = transcriptURL
            self.dbId = dbId
            self.diarizerSpeakerId = diarizerSpeakerId
            self.channel = channel
        }
    }

    /// When a speaker is renamed in Settings, update ALL transcripts that reference them.
    /// Finds transcripts by searching YAML for the speaker's db_id, extracts the old name,
    /// and replaces it in both YAML frontmatter and transcript body.
    /// Thread-safe: serialized via fileUpdateQueue to prevent concurrent file corruption.
    /// Convenience overload that writes into `defaultSaveDirectory`.
    static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String) {
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

    /// Update every saved occurrence of one queued voice as one file batch.
    /// All replacement reservations and metadata matches are checked before
    /// the first write, so a blocked meeting cannot leave sibling meetings
    /// partially renamed while the speaker database remains unchanged.
    @discardableResult
    public static func updateDeferredSpeakerNames(
        _ updates: [DeferredSpeakerNameUpdate],
        newName: String
    ) throws -> Bool {
        try updateDeferredSpeakerNames(
            updates,
            newName: newName,
            persistIdentity: {}
        )
    }

    /// Update saved transcripts and persist the matching identity mutation as
    /// one logical transaction. If identity persistence throws after the files
    /// are written, every transcript is restored before the error is surfaced.
    @discardableResult
    public static func updateDeferredSpeakerNames(
        _ updates: [DeferredSpeakerNameUpdate],
        newName: String,
        persistIdentity: () throws -> Void
    ) throws -> Bool {
        guard !updates.isEmpty else { return true }

        return try serializeTranscriptFileUpdate {
            let transcriptURLs = updates.map(\.transcriptURL)
            guard !isReplacingAnyTranscript(at: transcriptURLs) else {
                AppLogger.pipeline.warning(
                    "Deferred speaker batch blocked during replacement retranscription",
                    ["files": "\(Set(transcriptURLs.map(\.lastPathComponent)).count)"]
                )
                return false
            }

            struct StagedUpdate {
                let url: URL
                let original: String
                var updated: String
            }

            var orderedPaths: [String] = []
            var stagedByPath: [String: StagedUpdate] = [:]
            for update in updates {
                let path = update.transcriptURL.standardizedFileURL.path
                var staged: StagedUpdate
                if let existing = stagedByPath[path] {
                    staged = existing
                } else {
                    guard let content = try? String(contentsOf: update.transcriptURL, encoding: .utf8) else {
                        AppLogger.pipeline.error(
                            "Failed to read deferred speaker transcript",
                            ["path": update.transcriptURL.path]
                        )
                        return false
                    }
                    staged = StagedUpdate(
                        url: update.transcriptURL,
                        original: content,
                        updated: content
                    )
                    orderedPaths.append(path)
                }

                guard applyDeferredSpeakerName(
                    in: &staged.updated,
                    update: update,
                    newName: newName
                ) else {
                    return false
                }
                stagedByPath[path] = staged
            }

            var written: [(url: URL, original: String)] = []
            for path in orderedPaths {
                guard let staged = stagedByPath[path],
                      FileManager.default.fileExists(atPath: staged.url.path) else {
                    try restoreDeferredSpeakerUpdatesOrThrow(written)
                    return false
                }
                do {
                    try TranscriptFileRewrite.write(staged.updated, to: staged.url)
                    restrictTranscriptToOwnerOnly(staged.url)
                    written.append((url: staged.url, original: staged.original))
                } catch {
                    AppLogger.pipeline.warning("Failed to update deferred speaker transcript", [
                        "file": staged.url.lastPathComponent,
                        "error": error.localizedDescription
                    ])
                    try restoreDeferredSpeakerUpdatesOrThrow(written)
                    return false
                }
            }

            do {
                try persistIdentity()
            } catch {
                AppLogger.pipeline.warning("Deferred speaker identity persistence failed; restoring transcripts", [
                    "files": "\(written.count)",
                    "error": error.localizedDescription
                ])
                try restoreDeferredSpeakerUpdatesOrThrow(written)
                throw error
            }
            return true
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

        let matchingFiles = transcriptMarkdownFiles(under: directory).filter {
            scanFrontmatter(at: $0, for: dbIdNeedle) != .notMatched
        }
        guard !isReplacingAnyTranscript(at: matchingFiles) else {
            AppLogger.pipeline.warning(
                "Retroactive speaker update blocked during replacement retranscription",
                ["dbId": dbIdString]
            )
            return
        }

        for fileURL in matchingFiles {
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
                try TranscriptFileRewrite.write(content, to: fileURL)
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

    /// Restore every file already written by a deferred batch. A failure is
    /// retried once and then surfaced, so callers cannot mistake a partial
    /// on-disk update for an ordinary clean rejection.
    static func restoreDeferredSpeakerUpdatesOrThrow(
        _ updates: [(url: URL, original: String)]
    ) throws {
        var stillFailing = updates.reversed().filter { !attemptDeferredSpeakerRestore($0) }
        guard !stillFailing.isEmpty else { return }

        stillFailing = stillFailing.filter { !attemptDeferredSpeakerRestore($0) }
        guard stillFailing.isEmpty else {
            AppLogger.pipeline.error("Deferred speaker rollback failed after retry", [
                "fileCount": "\(stillFailing.count)"
            ])
            throw DeferredSpeakerNameUpdateError.transcriptRestoreFailed(
                fileCount: stillFailing.count
            )
        }
    }

    private static func attemptDeferredSpeakerRestore(
        _ update: (url: URL, original: String)
    ) -> Bool {
        do {
            try TranscriptFileRewrite.write(update.original, to: update.url)
            restrictTranscriptToOwnerOnly(update.url)
            return true
        } catch {
            AppLogger.pipeline.error("Failed to roll back deferred speaker transcript", [
                "file": update.url.lastPathComponent,
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

        let matchingFiles = transcriptMarkdownFiles(under: directory).filter {
            scanFrontmatter(at: $0, for: sourceIdNeedle) != .notMatched
        }
        guard !isReplacingAnyTranscript(at: matchingFiles) else {
            AppLogger.pipeline.warning(
                "Retroactive speaker merge blocked during replacement retranscription",
                ["sourceDbId": sourceIdString]
            )
            return
        }

        for fileURL in matchingFiles {
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
                try TranscriptFileRewrite.write(content, to: fileURL)
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
    // extraction (extractYAMLQuotedString) live in
    // RetroactiveSpeakerUpdater+Scanning.swift (audit 2026-07-08 wave 2).

    // applyDeferredSpeakerName / applyRetroactiveRename moved to
    // RetroactiveSpeakerUpdater+RowRename.swift.

    // MARK: - Speaker Name Updating (Post-Naming Flow)

    /// Preserve a deferred speaker review without applying a name.
    /// This keeps transcript labels as saved, but refreshes frontmatter db_id/source
    /// so Settings > People can safely name the right local profile later. A row
    /// shown under its call-app name (`callAppSuggestedName`) keeps that name and
    /// `name_source: call_app`; every other row goes back to "Speaker N".
    @discardableResult
    static func markSpeakerReviewDeferred(
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
                    name: entry.callAppSuggestedName ?? "Speaker \(entry.diarizerSpeakerId)",
                    source: "db_pending",
                    nameSource: entry.callAppSuggestedName == nil ? nil : SpeakerMapping.ShownNameSource.callApp.rawValue
                )
            }

            do {
                try TranscriptFileRewrite.write(content, to: transcriptURL)
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
    static func updateSpeakerNames(
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
                try TranscriptFileRewrite.write(content, to: transcriptURL)
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

    /// Remove database identity links for every frontmatter row matching `dbId`, regardless
    /// of channel. Used by `SpeakerIdentityMutationService`'s library-wide discard intent,
    /// which — unlike `discardSpeakerDatabaseLinks` above (scoped to a diarizer id + channel
    /// from one just-finalized transcript, used by the naming-flow discard action) — only
    /// knows the persistent speaker id and must find every row across saved transcripts that
    /// still points at it.
    @discardableResult
    static func discardSpeakerDatabaseLink(in content: inout String, dbId: UUID) -> Bool {
        guard let frontmatterRange = frontmatterContentRange(in: content) else { return false }

        var lines = String(content[frontmatterRange]).components(separatedBy: "\n")
        let targetDbIdLine = #"db_id: "\#(dbId.uuidString)""#
        var changed = false
        var index = 0

        while index < lines.count {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- ") else {
                index += 1
                continue
            }

            var nextEntryIndex = index + 1
            while nextEntryIndex < lines.count,
                  !lines[nextEntryIndex].trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                nextEntryIndex += 1
            }

            var dbIdIndex: Int?
            var confidenceIndex: Int?
            var sourceIndex: Int?
            for lineIndex in (index + 1)..<nextEntryIndex {
                let candidate = lines[lineIndex].trimmingCharacters(in: .whitespaces)
                if candidate == targetDbIdLine {
                    dbIdIndex = lineIndex
                } else if candidate.hasPrefix("confidence:") {
                    confidenceIndex = lineIndex
                } else if candidate.hasPrefix("source:") {
                    sourceIndex = lineIndex
                }
            }

            guard let removeIndex = dbIdIndex else {
                index = nextEntryIndex
                continue
            }

            lines.remove(at: removeIndex)
            nextEntryIndex -= 1
            if let idx = confidenceIndex, idx > removeIndex { confidenceIndex = idx - 1 }
            if let idx = sourceIndex, idx > removeIndex { sourceIndex = idx - 1 }

            if let confidenceIndex {
                lines[confidenceIndex] = "    confidence: unknown"
            }
            if let sourceIndex {
                lines[sourceIndex] = "    source: unknown"
            } else {
                lines.insert("    source: unknown", at: min(nextEntryIndex, lines.count))
                nextEntryIndex += 1
            }

            changed = true
            index = nextEntryIndex
        }

        guard changed else { return false }
        content.replaceSubrange(frontmatterRange, with: lines.joined(separator: "\n"))
        return true
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

    // extractYAMLQuotedString moved to RetroactiveSpeakerUpdater+Scanning.swift.

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

    // rewriteFullTranscriptSection and its legacy/styled transcript-section helpers
    // moved to RetroactiveSpeakerUpdater+TranscriptRewrite.swift. rewriteRemoteSpeakerBreakdown,
    // rewriteLocalSpeakerBreakdownIfPresent, and rewriteSpeakerBreakdown moved to
    // RetroactiveSpeakerUpdater+BreakdownRewrite.swift. (audit 2026-07-08 wave 2)

    private static func isObsidianFormatted(_ content: String) -> Bool {
        content.contains("\ncssclasses:\n  - transcripted")
            || content.contains("\naliases:\n  - \"Meeting ")
    }

}
