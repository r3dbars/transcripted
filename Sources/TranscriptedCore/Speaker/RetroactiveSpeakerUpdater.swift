import Foundation

// MARK: - Retroactive Speaker Updates

extension TranscriptSaver {

    /// When a speaker is renamed in Settings, update ALL transcripts that reference them.
    /// Finds transcripts by searching YAML for the speaker's db_id, extracts the old name,
    /// and replaces it in both YAML frontmatter and transcript body.
    /// Thread-safe: serialized via fileUpdateQueue to prevent concurrent file corruption.
    public static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String) {
        fileUpdateQueue.sync {
            _retroactivelyUpdateSpeakerImpl(dbId: dbId, newName: newName, directory: nil)
        }
    }

    /// Internal overload for tests — scans a specific directory instead of `defaultSaveDirectory`.
    static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String, in directory: URL) {
        fileUpdateQueue.sync {
            _retroactivelyUpdateSpeakerImpl(dbId: dbId, newName: newName, directory: directory)
        }
    }

    private static func _retroactivelyUpdateSpeakerImpl(dbId: UUID, newName: String, directory: URL?) {
        let dir = directory ?? defaultSaveDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "md" }) else { return }

        let dbIdString = dbId.uuidString
        var updatedCount = 0

        for fileURL in files {
            guard var content = try? String(contentsOf: fileURL, encoding: .utf8),
                  content.contains("db_id: \"\(dbIdString)\"") else { continue }

            // Find the old speaker name from YAML: the line after db_id contains name: "OldName"
            let lines = content.components(separatedBy: "\n")
            var oldNames: [String] = []
            for (i, line) in lines.enumerated() {
                if line.contains("db_id: \"\(dbIdString)\"") {
                    // Next line should be name: "..."
                    if i + 1 < lines.count {
                        let nameLine = lines[i + 1]
                        if let oldName = unescapeYAMLStringValue(afterPrefix: "name: ", in: nameLine),
                           oldName != newName && !oldNames.contains(oldName) {
                            oldNames.append(oldName)
                        }
                    }
                }
            }

            guard !oldNames.isEmpty else { continue }

            for oldName in oldNames {
                applyNameReplacement(in: &content, oldName: oldName, newName: newName, updateSpeakerTag: true)
            }

            // Write back atomically
            do {
                try content.write(to: fileURL, atomically: true, encoding: .utf8)
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

    // MARK: - Retroactive Title Update

    // MARK: - Speaker Name Updating (Post-Naming Flow)

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
        speakerStore: (any SpeakerStore)? = nil
    ) -> Bool {
        guard !updates.isEmpty else { return true }

        return fileUpdateQueue.sync {
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for name update", ["path": transcriptURL.path])
                return false
            }

            let obsidianEnabled = isObsidianFormatted(content)
            _ = speakerStore
            let updatesBySystemKey = Dictionary(uniqueKeysWithValues: updates.map {
                (
                    "system_\($0.sortformerSpeakerId)",
                    (
                        oldName: currentSpeakerName(in: content, sortformerSpeakerId: $0.sortformerSpeakerId)
                            ?? "Speaker \($0.sortformerSpeakerId)",
                        newName: $0.newName
                    )
                )
            })

            for update in updates {
                updateFrontmatterSpeakerMetadata(in: &content, update: update)
            }

            guard rewriteFullTranscriptSection(
                in: &content,
                result: transcriptionResult,
                updatesBySystemKey: updatesBySystemKey,
                obsidianEnabled: obsidianEnabled
            ) else {
                AppLogger.pipeline.error("Failed to rewrite transcript body for speaker updates", [
                    "path": transcriptURL.lastPathComponent
                ])
                return false
            }

            guard rewriteRemoteSpeakerBreakdown(
                in: &content,
                result: transcriptionResult,
                updatesBySystemKey: updatesBySystemKey
            ) else {
                AppLogger.pipeline.error("Failed to rewrite speaker breakdown for speaker updates", [
                    "path": transcriptURL.lastPathComponent
                ])
                return false
            }

            // Consolidate speaker breakdown when multiple diarizer IDs got the same name.
            // PyAnnote can over-segment one person into 2 clusters; after naming, both become
            // e.g. "Timothy", producing duplicate lines in the breakdown.
            content = SpeakerBreakdownConsolidator.consolidate(content)

            // Atomic write back
            do {
                try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
            } catch {
                AppLogger.pipeline.error("Failed to write updated transcript", ["error": error.localizedDescription])
                return false
            }

            // Mirror name and persistent ID updates into the JSON sidecar so agents
            // see the finalized speaker data without re-parsing the markdown.
            let jsonURL = transcriptURL.deletingPathExtension().appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: jsonURL.path) {
                updateAgentSidecar(at: jsonURL, updates: updates)
            }

            AppLogger.pipeline.info("Updated speaker names in transcript", [
                "path": transcriptURL.lastPathComponent,
                "updates": "\(updates.count)"
            ])

            return true
        }
    }

    private static func updateAgentSidecar(at jsonURL: URL, updates: [SpeakerNameUpdate]) {
        guard let data = try? Data(contentsOf: jsonURL),
              let transcript = try? JSONDecoder().decode(AgentTranscript.self, from: data) else { return }

        var updatedSpeakers = transcript.speakers
        var changed = false

        for i in updatedSpeakers.indices {
            let speakerId = updatedSpeakers[i].id
            guard speakerId.hasPrefix("system_") else { continue }
            let sortformerKey = String(speakerId.dropFirst("system_".count))
            guard let update = updates.first(where: { $0.sortformerSpeakerId == sortformerKey }) else { continue }

            let resolvedId = (update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId).uuidString
            updatedSpeakers[i] = AgentSpeaker(
                id: updatedSpeakers[i].id,
                persistentSpeakerId: resolvedId,
                name: update.newName,
                confidence: updatedSpeakers[i].confidence,
                wordCount: updatedSpeakers[i].wordCount,
                speakingSeconds: updatedSpeakers[i].speakingSeconds
            )
            changed = true
        }

        guard changed else { return }

        let updated = AgentTranscript(
            version: transcript.version,
            transcriptId: transcript.transcriptId,
            recording: transcript.recording,
            speakers: updatedSpeakers,
            utterances: transcript.utterances
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(updated).write(to: jsonURL, options: .atomic)
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
        // Security: YAML-escape both old and new names when matching/replacing YAML scalars.
        let yamlSafeOldName = escapeYAML(oldName)
        let yamlSafeName = escapeYAML(newName)
        content = content.replacingOccurrences(of: "name: \"\(yamlSafeOldName)\"", with: "name: \"\(yamlSafeName)\"")
        content = content.replacingOccurrences(of: "[System/\(oldName)]", with: "[System/\(newName)]")
        content = content.replacingOccurrences(of: "[[\(oldName)]]", with: "[[\(newName)]]")
        content = content.replacingOccurrences(of: "**\(oldName):**", with: "**\(newName):**")

        if updateSpeakerTag {
            let oldTag = "speaker/\(oldName.replacingOccurrences(of: " ", with: "-").lowercased())"
            let newTag = "speaker/\(newName.replacingOccurrences(of: " ", with: "-").lowercased())"
            content = content.replacingOccurrences(of: oldTag, with: newTag)
        }
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
        guard let frontmatterRange = frontmatterContentRange(in: content) else { return }

        var lines = String(content[frontmatterRange])
            .components(separatedBy: "\n")

        let targetIdLine = #"id: "\#(update.sortformerSpeakerId)""#
        let resolvedPersistentId = (update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId).uuidString
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

            let dbIdLine = #"    db_id: "\#(resolvedPersistentId)""#
            let nameLine = #"    name: "\#(escapeYAML(update.newName))""#
            let sourceLine = "    source: \(NameSource.userManual)"
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

    private static func currentSpeakerName(in content: String, sortformerSpeakerId: String) -> String? {
        guard let frontmatterRange = frontmatterContentRange(in: content) else { return nil }

        let lines = String(content[frontmatterRange]).components(separatedBy: "\n")
        let targetIdLine = #"id: "\#(sortformerSpeakerId)""#
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

    private static func rewriteFullTranscriptSection(
        in content: inout String,
        result: TranscriptionResult,
        updatesBySystemKey: [String: (oldName: String, newName: String)],
        obsidianEnabled: Bool
    ) -> Bool {
        if let range = fullTranscriptContentRange(in: content) {
            return rewriteLegacyTranscriptSection(
                in: &content,
                range: range,
                result: result,
                updatesBySystemKey: updatesBySystemKey,
                obsidianEnabled: obsidianEnabled
            )
        }

        if let range = styledTranscriptContentRange(in: content) {
            return rewriteStyledTranscriptSection(
                in: &content,
                range: range,
                result: result,
                updatesBySystemKey: updatesBySystemKey,
                obsidianEnabled: obsidianEnabled
            )
        }

        return false
    }

    private static func rewriteRemoteSpeakerBreakdown(
        in content: inout String,
        result: TranscriptionResult,
        updatesBySystemKey: [String: (oldName: String, newName: String)]
    ) -> Bool {
        guard let headerRange = content.range(of: "#### Remote Speaker Breakdown\n\n") else {
            return false
        }

        let footerCandidates = [
            "\n\n---\n\n## Full Transcript",
            "\n\n## Transcript",
        ]
        guard let footerRange = footerCandidates.compactMap({
            content.range(of: $0, range: headerRange.upperBound..<content.endIndex)
        }).min(by: { $0.lowerBound < $1.lowerBound }) else {
            return false
        }

        let speakerGroups = Dictionary(grouping: result.systemUtterances, by: { $0.speakerId })
        let lines = speakerGroups.keys.sorted().map { speakerId in
            let utterances = speakerGroups[speakerId] ?? []
            let speakerKey = "system_\(speakerId)"
            let speakerName = updatesBySystemKey[speakerKey]?.newName
                ?? updatesBySystemKey[speakerKey]?.oldName
                ?? currentSpeakerName(in: content, sortformerSpeakerId: String(speakerId))
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

    private static func rewriteLegacyTranscriptSection(
        in content: inout String,
        range: Range<String.Index>,
        result: TranscriptionResult,
        updatesBySystemKey: [String: (oldName: String, newName: String)],
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

            let speakerKey = "\(utterance.channel == 0 ? "mic" : "system")_\(utterance.speakerId)"
            guard let update = updatesBySystemKey[speakerKey] else { continue }

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
        updatesBySystemKey: [String: (oldName: String, newName: String)],
        obsidianEnabled: Bool
    ) -> Bool {
        let chunks = String(content[range])
            .components(separatedBy: "\n\n")
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let utterances = result.allUtterances
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

            let speakerKey = "\(utterance.channel == 0 ? "mic" : "system")_\(utterance.speakerId)"
            if let update = updatesBySystemKey[speakerKey] {
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

    /// Extract and unescape a double-quoted YAML scalar value that starts after `prefix`.
    /// Handles `\"`, `\\`, `\n`, `\r`, `\t` escape sequences.
    /// Returns nil if the prefix isn't found or the value isn't double-quoted.
    private static func unescapeYAMLStringValue(afterPrefix prefix: String, in line: String) -> String? {
        guard let prefixRange = line.range(of: prefix) else { return nil }
        let afterPrefix = line[prefixRange.upperBound...]
        guard afterPrefix.hasPrefix("\"") else { return nil }

        var result = ""
        var index = afterPrefix.index(after: afterPrefix.startIndex)  // skip opening "
        while index < afterPrefix.endIndex {
            let c = afterPrefix[index]
            if c == "\\" {
                let nextIndex = afterPrefix.index(after: index)
                guard nextIndex < afterPrefix.endIndex else { break }
                switch afterPrefix[nextIndex] {
                case "\"": result.append("\"")
                case "\\": result.append("\\")
                case "n":  result.append("\n")
                case "r":  result.append("\r")
                case "t":  result.append("\t")
                default:
                    result.append(c)
                    result.append(afterPrefix[nextIndex])
                }
                index = afterPrefix.index(nextIndex, offsetBy: 1)
            } else if c == "\"" {
                break  // closing quote
            } else {
                result.append(c)
                index = afterPrefix.index(after: index)
            }
        }
        return result
    }
}

enum SpeakerBreakdownConsolidator {
    private static let breakdownHeader = "#### Remote Speaker Breakdown\n\n"
    private static let breakdownFooter = "\n---\n"
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
        guard let breakdownStart = content.range(of: breakdownHeader),
              let breakdownEnd = content.range(of: breakdownFooter, range: breakdownStart.upperBound..<content.endIndex) else {
            return content
        }

        let breakdownRange = breakdownStart.upperBound..<breakdownEnd.lowerBound
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
