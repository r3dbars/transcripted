import Foundation

// MARK: - Row-targeted renames (moved from RetroactiveSpeakerUpdater.swift)

extension TranscriptSaver {

    /// Names one queued voice's row in a transcript: the row must still match
    /// (same diarizer id, channel, and profile), gets the new name with a
    /// `user_manual` source (dropping any `name_source:`), and its body labels
    /// follow. Shared with `SpeakerIdentityMutationService`'s reviewed-voice
    /// merge.
    ///
    /// Body labels are `[System/<name>]` / `[Mic/<name>]`, so when another row
    /// on the same channel shows the same old name, the body can't tell the
    /// two voices apart: only the row is renamed and the body is left alone
    /// rather than renaming the other voice too.
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
        let rowsSharingOldName = parseFrontmatterSpeakerRows(in: content.components(separatedBy: "\n")).filter {
            $0.name == oldName && ($0.channel ?? .system) == update.channel
        }

        writeFrontmatterSpeakerMetadata(
            in: &content,
            diarizerSpeakerId: update.diarizerSpeakerId,
            channel: update.channel,
            persistentSpeakerId: update.dbId,
            name: newName,
            source: NameSource.userManual
        )
        if rowsSharingOldName.count > 1 {
            AppLogger.pipeline.warning("Deferred speaker name hit a shared display name; body left as is", [
                "path": update.transcriptURL.lastPathComponent,
                "channel": update.channel.rawValue,
                "rowsSharingName": "\(rowsSharingOldName.count)"
            ])
        } else {
            applyScopedNameReplacement(
                in: &content,
                oldName: oldName,
                newName: newName,
                channel: update.channel
            )
        }
        content = SpeakerBreakdownConsolidator.consolidate(content)
        return true
    }

    /// Rename one person (by db_id) inside a single transcript without bleeding into
    /// other speakers who share the old display name.
    ///
    /// - YAML `name:` lines are rewritten row-targeted, only for rows matching `dbId`,
    ///   and those rows lose any `name_source:` marker: the name is now the
    ///   person's confirmed name, not a call-app hint.
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
        // A renamed row's name no longer came from the call app. Remove from
        // the bottom up so earlier indices stay valid.
        for index in targetRows.compactMap(\.nameSourceLineIndex).sorted(by: >) {
            lines.remove(at: index)
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
}
