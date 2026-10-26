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

    /// Names one queued voice's row in a transcript: the row must still match
    /// (same diarizer id, channel, and profile), gets the new name with a
    /// `user_manual` source, and its body labels follow. Shared with
    /// `SpeakerIdentityMutationService`'s reviewed-voice merge.
    static func applyDeferredSpeakerName(
        in content: inout String,
        update: DeferredSpeakerNameUpdate,
        newName: String
    ) -> Bool {
        guard let oldName = currentSpeakerName(
            in: content,
            diarizerSpeakerId: update.diarizerSpeakerId,
            channel: update.channel,
            matchingDbId: update.dbId
        ) else {
            AppLogger.pipeline.warning("Deferred speaker metadata no longer matches queued row", [
                "path": update.transcriptURL.lastPathComponent,
                "dbId": update.dbId.uuidString,
                "diarizerSpeakerId": update.diarizerSpeakerId,
                "channel": update.channel.rawValue
            ])
            return false
        }

        writeFrontmatterSpeakerMetadata(
            in: &content,
            diarizerSpeakerId: update.diarizerSpeakerId,
            channel: update.channel,
            persistentSpeakerId: update.dbId,
            name: newName,
            source: NameSource.userManual
        )
        applyScopedNameReplacement(
            in: &content,
            oldName: oldName,
            newName: newName,
            channel: update.channel
        )
        content = SpeakerBreakdownConsolidator.consolidate(content)
        return true
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
    ///
    /// Internal (not `private`) so `SpeakerIdentityMutationService` — the canonical
    /// entry point for rename/merge/discard — can reuse this as the one shared
    /// library-scan rename engine instead of reimplementing it.
    @discardableResult
    static func applyRetroactiveRename(
        in content: inout String,
        dbId: UUID,
        newName: String,
        fileName: String
    ) -> Bool {
        var lines = content.components(separatedBy: "\n")
        let rows = parseFrontmatterSpeakerRows(in: lines)
        let targetRows = rows.filter { $0.dbId == dbId && $0.name != nil && $0.name != hedgedName(newName, replacing: $0.name) }
        guard !targetRows.isEmpty else { return false }

        var changed = false

        // 1) Row-targeted YAML rename for the matching speaker rows only.
        for row in targetRows {
            guard let index = row.nameLineIndex else { continue }
            let indent = lines[index].prefix(while: { $0 == " " })
            lines[index] = "\(indent)name: \"\(escapeYAML(hedgedName(newName, replacing: row.name)))\""
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
                applyNameReplacement(in: &content, oldName: oldName, newName: hedgedName(newName, replacing: oldName), updateSpeakerTag: true)
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
                        newName: hedgedName(newName, replacing: oldName),
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
                    name: "Speaker \(entry.diarizerSpeakerId)",
                    source: "db_pending"
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

    static func restrictTranscriptToOwnerOnly(_ transcriptURL: URL) {
        FileManager.default.restrictToOwnerOnly(atPath: transcriptURL.path)
    }

}
