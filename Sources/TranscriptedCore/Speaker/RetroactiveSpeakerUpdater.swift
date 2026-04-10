import Foundation

// MARK: - Retroactive Speaker Updates

extension TranscriptSaver {

    /// When a speaker is renamed in Settings, update ALL transcripts that reference them.
    /// Finds transcripts by searching YAML for the speaker's db_id, extracts the old name,
    /// and replaces it in both YAML frontmatter and transcript body.
    /// Thread-safe: serialized via fileUpdateQueue to prevent concurrent file corruption.
    public static func retroactivelyUpdateSpeaker(
        dbId: UUID,
        newName: String,
        directory: URL = defaultSaveDirectory,
        speakerStoreForIndex: (any SpeakerStore)? = nil
    ) {
        fileUpdateQueue.sync {
            _retroactivelyUpdateSpeakerImpl(
                dbId: dbId,
                newName: newName,
                directory: directory,
                speakerStoreForIndex: speakerStoreForIndex
            )
        }
    }

    private static func _retroactivelyUpdateSpeakerImpl(
        dbId: UUID,
        newName: String,
        directory: URL,
        speakerStoreForIndex: (any SpeakerStore)?
    ) {
        let dir = directory
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "md" }) else { return }

        let dbIdString = dbId.uuidString
        var updatedCount = 0

        for fileURL in files {
            guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let markdownReferencesSpeaker = content.contains("db_id: \"\(dbIdString)\"")
            let jsonReferencesSpeaker = agentJSONContains(transcriptURL: fileURL, dbId: dbId)
            guard markdownReferencesSpeaker || jsonReferencesSpeaker else { continue }

            let oldNames = speakerNames(in: content, matching: dbId).filter { $0 != newName }

            do {
                if markdownReferencesSpeaker {
                    for oldName in oldNames {
                        applyNameReplacement(in: &content, oldName: oldName, newName: newName, updateSpeakerTag: true)
                    }
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                }

                updateAgentJSONNames(transcriptURL: fileURL, dbId: dbId, newName: newName)
                updatedCount += 1
            } catch {
                AppLogger.pipeline.warning("Failed to update transcript retroactively", ["file": fileURL.lastPathComponent, "error": error.localizedDescription])
            }
        }

        if updatedCount > 0 {
            AppLogger.pipeline.info("Retroactively updated speaker in transcripts",
                ["dbId": dbIdString, "name": newName, "files": "\(updatedCount)"])

            rebuildAgentIndex(for: dir, speakerStoreForIndex: speakerStoreForIndex)
        }
    }

    /// When two profiles are merged in settings, update historical transcript metadata so
    /// old artifacts point at the surviving persistent speaker ID.
    public static func retroactivelyMergeSpeaker(
        sourceDbId: UUID,
        into targetDbId: UUID,
        newName: String,
        directory: URL = defaultSaveDirectory,
        speakerStoreForIndex: (any SpeakerStore)? = nil
    ) {
        fileUpdateQueue.sync {
            _retroactivelyMergeSpeakerImpl(
                sourceDbId: sourceDbId,
                targetDbId: targetDbId,
                newName: newName,
                directory: directory,
                speakerStoreForIndex: speakerStoreForIndex
            )
        }
    }

    private static func _retroactivelyMergeSpeakerImpl(
        sourceDbId: UUID,
        targetDbId: UUID,
        newName: String,
        directory: URL,
        speakerStoreForIndex: (any SpeakerStore)?
    ) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "md" }) else { return }

        let sourceIdString = sourceDbId.uuidString
        var updatedCount = 0

        for fileURL in files {
            guard var content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }
            let markdownReferencesSpeaker = content.contains("db_id: \"\(sourceIdString)\"")
            let jsonReferencesSpeaker = agentJSONContains(transcriptURL: fileURL, dbId: sourceDbId)
            guard markdownReferencesSpeaker || jsonReferencesSpeaker else { continue }

            let oldNames = speakerNames(in: content, matching: sourceDbId)

            do {
                if markdownReferencesSpeaker {
                    replaceDbId(in: &content, oldId: sourceDbId, newId: targetDbId)
                    for oldName in oldNames {
                        applyNameReplacement(in: &content, oldName: oldName, newName: newName, updateSpeakerTag: true)
                    }
                    content = SpeakerBreakdownConsolidator.consolidate(content)
                    try content.write(to: fileURL, atomically: true, encoding: .utf8)
                }
                updateAgentJSONMerge(transcriptURL: fileURL, sourceDbId: sourceDbId, targetDbId: targetDbId, newName: newName)
                updatedCount += 1
            } catch {
                AppLogger.pipeline.warning("Failed to merge speaker identity retroactively", ["file": fileURL.lastPathComponent, "error": error.localizedDescription])
            }
        }

        if updatedCount > 0 {
            AppLogger.pipeline.info("Retroactively merged speaker in transcripts", [
                "sourceDbId": sourceDbId.uuidString,
                "targetDbId": targetDbId.uuidString,
                "name": newName,
                "files": "\(updatedCount)"
            ])
            rebuildAgentIndex(for: directory, speakerStoreForIndex: speakerStoreForIndex)
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
        speakerStoreForIndex: (any SpeakerStore)? = nil
    ) -> Bool {
        guard !updates.isEmpty else { return true }

        return fileUpdateQueue.sync {
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for name update", ["path": transcriptURL.path])
                return false
            }

            guard let jsonUpdate = prepareUpdatedAgentJSON(
                transcriptURL: transcriptURL,
                updates: updates
            ) else {
                AppLogger.pipeline.error("Failed to prepare JSON sidecar for name update", [
                    "path": transcriptURL.lastPathComponent
                ])
                return false
            }

            let obsidianEnabled = isObsidianFormatted(content)

            for update in updates {
                updateFrontmatterSpeakerMetadata(in: &content, update: update)
            }

            let updatesBySystemKey = Dictionary(
                uniqueKeysWithValues: updates.map { ("system_\($0.sortformerSpeakerId)", $0) }
            )
            guard rewriteFullTranscriptSection(
                in: &content,
                transcript: jsonUpdate.updatedTranscript,
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
                transcript: jsonUpdate.updatedTranscript
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

            do {
                try jsonUpdate.updatedData.write(to: jsonUpdate.jsonURL, options: .atomic)
            } catch {
                AppLogger.pipeline.error("Failed to write updated JSON sidecar", [
                    "path": jsonUpdate.jsonURL.lastPathComponent,
                    "error": error.localizedDescription
                ])

                if let originalContent = String(data: jsonUpdate.originalMarkdownData, encoding: .utf8) {
                    try? originalContent.write(to: transcriptURL, atomically: true, encoding: .utf8)
                }
                return false
            }

            AppLogger.pipeline.info("Updated speaker names in transcript", [
                "path": transcriptURL.lastPathComponent,
                "updates": "\(updates.count)"
            ])

            let folder = transcriptURL.deletingLastPathComponent()
            do {
                try AgentOutput.writeIndex(
                    to: folder,
                    speakerStore: speakerStoreForIndex ?? SpeakerDatabase.shared
                )
            } catch {
                AppLogger.pipeline.warning("Failed to rebuild transcript index after speaker naming", [
                    "folder": folder.lastPathComponent,
                    "error": error.localizedDescription
                ])
            }

            return true
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

    /// Extract a time string like "11:15:12" from a filename like "Call 2026-04-10 11-15-12".
    private static func extractTimeFromFilename(_ stem: String) -> String? {
        // Match pattern: digits-digits-digits at the end (e.g., "11-15-12")
        guard let regex = try? NSRegularExpression(pattern: #"(\d{1,2})-(\d{2})-(\d{2})$"#),
              let match = regex.firstMatch(in: stem, range: NSRange(location: 0, length: (stem as NSString).length)),
              match.numberOfRanges >= 4 else { return nil }
        let ns = stem as NSString
        let h = ns.substring(with: match.range(at: 1))
        let m = ns.substring(with: match.range(at: 2))
        let s = ns.substring(with: match.range(at: 3))
        return "\(h):\(m):\(s)"
    }

    /// Replace all occurrences of a speaker name throughout a transcript's YAML and body.
    /// Handles YAML frontmatter, body labels, wiki links, and speaker breakdown.
    /// Pass `updateSpeakerTag: true` when the old name also has an Obsidian tag to rename.
    private static func applyNameReplacement(in content: inout String, oldName: String, newName: String, updateSpeakerTag: Bool) {
        // Security: YAML-escape the new name before interpolating into double-quoted scalars
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

    private static func replaceDbId(in content: inout String, oldId: UUID, newId: UUID) {
        content = content.replacingOccurrences(
            of: "db_id: \"\(oldId.uuidString)\"",
            with: "db_id: \"\(newId.uuidString)\""
        )
    }

    private static func speakerNames(in content: String, matching dbId: UUID) -> [String] {
        let lines = content.components(separatedBy: "\n")
        var oldNames: [String] = []
        for (index, line) in lines.enumerated() where line.contains("db_id: \"\(dbId.uuidString)\"") {
            guard index + 1 < lines.count else { continue }
            guard let oldName = parseQuotedYAMLName(lines[index + 1]) else { continue }
            if !oldName.isEmpty, !oldNames.contains(oldName) {
                oldNames.append(oldName)
            }
        }
        return oldNames
    }

    private static func parseQuotedYAMLName(_ line: String) -> String? {
        guard let range = line.range(of: "name: \"") else { return nil }

        var result = ""
        var isEscaped = false

        for character in line[range.upperBound...] {
            if isEscaped {
                switch character {
                case "\\":
                    result.append("\\")
                case "\"":
                    result.append("\"")
                case "n":
                    result.append("\n")
                case "r":
                    result.append("\r")
                case "t":
                    result.append("\t")
                default:
                    result.append("\\")
                    result.append(character)
                }
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
        }

        return nil
    }

    private static func upsertSpeakerDbId(
        in content: inout String,
        sortformerSpeakerId: String,
        dbId: UUID
    ) {
        let marker = "- id: \"\(sortformerSpeakerId)\""
        var lines = content.components(separatedBy: "\n")
        guard let speakerLineIndex = lines.firstIndex(where: { $0.contains(marker) }) else { return }

        let dbLine = "    db_id: \"\(dbId.uuidString)\""
        if speakerLineIndex + 1 < lines.count,
           lines[speakerLineIndex + 1].trimmingCharacters(in: .whitespaces).hasPrefix("db_id:") {
            lines[speakerLineIndex + 1] = dbLine
        } else {
            lines.insert(dbLine, at: speakerLineIndex + 1)
        }

        content = lines.joined(separator: "\n")
    }

    /// Merge duplicate speaker lines in the "Remote Speaker Breakdown" section.
    /// When two diarizer IDs get the same name, their stats should be combined
    /// into a single line (summing utterances, words, and speaking time).
    private static func consolidateSpeakerBreakdown(_ content: String) -> String {
        // Find the breakdown section
        guard let breakdownStart = content.range(of: "#### Remote Speaker Breakdown\n\n"),
              let breakdownEnd = content.range(of: "\n---\n", range: breakdownStart.upperBound..<content.endIndex) else {
            return content
        }

        let breakdownRange = breakdownStart.upperBound..<breakdownEnd.lowerBound
        let breakdownText = String(content[breakdownRange])
        let lines = breakdownText.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Parse each line: "- **Name:** N utterances, ~M words, MM:SS"
        struct SpeakerStats {
            var utterances: Int = 0
            var words: Int = 0
            var speakingSeconds: Double = 0
        }

        let pattern = #"- \*\*(.+?):\*\* (\d+) utterances?, ~(\d+) words?, (\d+):(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return content }

        var statsByName: [String: SpeakerStats] = [:]
        var nameOrder: [String] = []

        for line in lines {
            let nsLine = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: nsLine.length)) else { continue }

            let name = nsLine.substring(with: match.range(at: 1))
            let utterances = Int(nsLine.substring(with: match.range(at: 2))) ?? 0
            let words = Int(nsLine.substring(with: match.range(at: 3))) ?? 0
            let minutes = Double(nsLine.substring(with: match.range(at: 4))) ?? 0
            let seconds = Double(nsLine.substring(with: match.range(at: 5))) ?? 0

            if statsByName[name] == nil {
                nameOrder.append(name)
                statsByName[name] = SpeakerStats()
            }
            statsByName[name]!.utterances += utterances
            statsByName[name]!.words += words
            statsByName[name]!.speakingSeconds += minutes * 60 + seconds
        }

        // If no duplicates were found, return unchanged
        if statsByName.count == lines.count { return content }

        // Rebuild the breakdown
        var newBreakdown = ""
        for name in nameOrder {
            guard let stats = statsByName[name] else { continue }
            let mins = Int(stats.speakingSeconds) / 60
            let secs = Int(stats.speakingSeconds) % 60
            let timeStr = String(format: "%02d:%02d", mins, secs)
            newBreakdown += "- **\(name):** \(stats.utterances) utterances, ~\(stats.words) words, \(timeStr)\n"
        }

        var result = content
        result.replaceSubrange(breakdownRange, with: newBreakdown)

        // Update YAML frontmatter: system_speakers should reflect consolidated count
        let oldSystemSpeakers = lines.count
        let newSystemSpeakers = statsByName.count
        result = result.replacingOccurrences(
            of: "system_speakers: \(oldSystemSpeakers)",
            with: "system_speakers: \(newSystemSpeakers)"
        )

        // Update analytics section: "Speakers Detected" for remote participants
        result = result.replacingOccurrences(
            of: "- **Speakers Detected:** \(oldSystemSpeakers)\n\n#### Remote Speaker Breakdown",
            with: "- **Speakers Detected:** \(newSystemSpeakers)\n\n#### Remote Speaker Breakdown"
        )

        // Update footer speaker count.
        // The footer uses total = mic_speakers + system_speakers.
        // We can't know mic_speakers from here, so fix the total by the same delta.
        let delta = oldSystemSpeakers - newSystemSpeakers
        let footerPattern = #"\| (\d+) speakers\*"#
        if let footerRegex = try? NSRegularExpression(pattern: footerPattern),
           let footerMatch = footerRegex.firstMatch(in: result, range: NSRange(location: 0, length: (result as NSString).length)),
           let oldTotal = Int((result as NSString).substring(with: footerMatch.range(at: 1))) {
            let newTotal = oldTotal - delta
            let oldFooterFragment = "| \(oldTotal) speakers*"
            let newFooterFragment = "| \(newTotal) speakers*"
            result = result.replacingOccurrences(of: oldFooterFragment, with: newFooterFragment)
        }

        AppLogger.pipeline.info("Consolidated duplicate speaker names in breakdown", [
            "before": "\(lines.count)",
            "after": "\(statsByName.count)"
        ])

        return result
    }
    /// Update the JSON sidecar when speaker names change.
    private static func prepareUpdatedAgentJSON(
        transcriptURL: URL,
        updates: [SpeakerNameUpdate]
    ) -> (jsonURL: URL, originalMarkdownData: Data, originalJSONData: Data, updatedData: Data, updatedTranscript: AgentTranscript)? {
        let stem = transcriptURL.deletingPathExtension().lastPathComponent
        let jsonURL = transcriptURL.deletingLastPathComponent().appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: jsonURL.path) else {
            AppLogger.pipeline.error("JSON sidecar missing during speaker update", [
                "path": jsonURL.lastPathComponent
            ])
            return nil
        }

        guard let originalMarkdownData = try? Data(contentsOf: transcriptURL) else {
            AppLogger.pipeline.error("Failed to re-read transcript before speaker update", [
                "path": transcriptURL.lastPathComponent
            ])
            return nil
        }

        guard let originalJSONData = try? Data(contentsOf: jsonURL) else {
            AppLogger.pipeline.error("Failed to read JSON sidecar during speaker update", [
                "path": jsonURL.lastPathComponent
            ])
            return nil
        }

        guard let transcript = try? JSONDecoder().decode(AgentTranscript.self, from: originalJSONData) else {
            AppLogger.pipeline.error("Failed to decode JSON sidecar during speaker update", [
                "path": jsonURL.lastPathComponent
            ])
            return nil
        }

        if let markdownTranscriptId = extractTranscriptId(from: transcriptURL) {
            guard let sidecarTranscriptIdString = transcript.transcriptId,
                  let sidecarTranscriptId = UUID(uuidString: sidecarTranscriptIdString),
                  sidecarTranscriptId == markdownTranscriptId else {
                AppLogger.pipeline.error("Transcript markdown and JSON sidecar ids do not match", [
                    "markdown": markdownTranscriptId.uuidString,
                    "sidecar": transcript.transcriptId ?? "nil",
                    "path": jsonURL.lastPathComponent
                ])
                return nil
            }
        }

        guard !updates.isEmpty else {
            return nil
        }

        // Rebuild speakers with updated names
        var updatedSpeakers = transcript.speakers
        var updatedSpeakerIds = Set<String>()
        for update in updates {
            let systemKey = "system_\(update.sortformerSpeakerId)"
            if let idx = updatedSpeakers.firstIndex(where: { $0.id == systemKey }) {
                let old = updatedSpeakers[idx]
                updatedSpeakers[idx] = AgentSpeaker(
                    id: old.id,
                    persistentSpeakerId: (update.resolvedPersistentSpeakerId ?? update.persistentSpeakerId).uuidString,
                    name: update.newName,
                    confidence: old.confidence,
                    wordCount: old.wordCount,
                    speakingSeconds: old.speakingSeconds
                )
                updatedSpeakerIds.insert(systemKey)
            }
        }

        let expectedSpeakerIds = Set(updates.map { "system_\($0.sortformerSpeakerId)" })
        guard updatedSpeakerIds == expectedSpeakerIds else {
            AppLogger.pipeline.error("JSON sidecar missing expected speaker ids during update", [
                "path": jsonURL.lastPathComponent,
                "expected": "\(expectedSpeakerIds.sorted())",
                "updated": "\(updatedSpeakerIds.sorted())"
            ])
            return nil
        }

        var updated = AgentTranscript(
            version: transcript.version,
            transcriptId: transcript.transcriptId,
            recording: transcript.recording,
            speakers: updatedSpeakers,
            utterances: transcript.utterances
        )

        for update in updates {
            guard case .merged(let targetProfileId) = update.action else { continue }
            updated = deduplicateAgentSpeaker(
                in: updated,
                persistentSpeakerId: targetProfileId.uuidString,
                preferredName: update.newName
            )
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let newData = try? encoder.encode(updated) else {
            return nil
        }

        return (jsonURL, originalMarkdownData, originalJSONData, newData, updated)
    }

    private static func updateAgentJSONNames(transcriptURL: URL, dbId: UUID, newName: String) {
        let stem = transcriptURL.deletingPathExtension().lastPathComponent
        let jsonURL = transcriptURL.deletingLastPathComponent().appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              let transcript = try? JSONDecoder().decode(AgentTranscript.self, from: data) else { return }

        let updated = AgentTranscript(
            version: transcript.version,
            transcriptId: transcript.transcriptId,
            recording: transcript.recording,
            speakers: transcript.speakers.map { speaker in
                guard speaker.persistentSpeakerId == dbId.uuidString else { return speaker }
                return AgentSpeaker(
                    id: speaker.id,
                    persistentSpeakerId: speaker.persistentSpeakerId,
                    name: newName,
                    confidence: speaker.confidence,
                    wordCount: speaker.wordCount,
                    speakingSeconds: speaker.speakingSeconds
                )
            },
            utterances: transcript.utterances
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let newData = try? encoder.encode(updated) {
            try? newData.write(to: jsonURL, options: .atomic)
        }
    }

    private static func agentJSONContains(transcriptURL: URL, dbId: UUID) -> Bool {
        let stem = transcriptURL.deletingPathExtension().lastPathComponent
        let jsonURL = transcriptURL.deletingLastPathComponent().appendingPathComponent("\(stem).json")
        guard let data = try? Data(contentsOf: jsonURL),
              let content = String(data: data, encoding: .utf8) else { return false }
        return content.contains(dbId.uuidString)
    }

    private static func updateAgentJSONMerge(
        transcriptURL: URL,
        sourceDbId: UUID,
        targetDbId: UUID,
        newName: String
    ) {
        let stem = transcriptURL.deletingPathExtension().lastPathComponent
        let jsonURL = transcriptURL.deletingLastPathComponent().appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              let transcript = try? JSONDecoder().decode(AgentTranscript.self, from: data) else { return }

        let rewritten = AgentTranscript(
            version: transcript.version,
            transcriptId: transcript.transcriptId,
            recording: transcript.recording,
            speakers: transcript.speakers.map { speaker in
                guard speaker.persistentSpeakerId == sourceDbId.uuidString else { return speaker }
                return AgentSpeaker(
                    id: speaker.id,
                    persistentSpeakerId: targetDbId.uuidString,
                    name: newName,
                    confidence: speaker.confidence,
                    wordCount: speaker.wordCount,
                    speakingSeconds: speaker.speakingSeconds
                )
            },
            utterances: transcript.utterances
        )
        let updated = deduplicateAgentSpeaker(
            in: rewritten,
            persistentSpeakerId: targetDbId.uuidString,
            preferredName: newName
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let newData = try? encoder.encode(updated) {
            try? newData.write(to: jsonURL, options: .atomic)
        }
    }

    private static func deduplicateAgentSpeaker(
        in transcript: AgentTranscript,
        persistentSpeakerId: String,
        preferredName: String
    ) -> AgentTranscript {
        var canonicalSpeakerId: String?
        var speakerIdMap: [String: String] = [:]
        var deduplicatedSpeakers: [AgentSpeaker] = []

        for speaker in transcript.speakers {
            guard speaker.persistentSpeakerId == persistentSpeakerId else {
                deduplicatedSpeakers.append(speaker)
                continue
            }

            if let canonicalSpeakerId,
               let index = deduplicatedSpeakers.firstIndex(where: { $0.id == canonicalSpeakerId }) {
                speakerIdMap[speaker.id] = canonicalSpeakerId
                deduplicatedSpeakers[index] = AgentSpeaker(
                    id: canonicalSpeakerId,
                    persistentSpeakerId: persistentSpeakerId,
                    name: preferredName,
                    confidence: mergedConfidence(
                        deduplicatedSpeakers[index].confidence,
                        speaker.confidence
                    ),
                    wordCount: deduplicatedSpeakers[index].wordCount + speaker.wordCount,
                    speakingSeconds: deduplicatedSpeakers[index].speakingSeconds + speaker.speakingSeconds
                )
                continue
            }

            canonicalSpeakerId = speaker.id
            speakerIdMap[speaker.id] = speaker.id
            deduplicatedSpeakers.append(
                AgentSpeaker(
                    id: speaker.id,
                    persistentSpeakerId: persistentSpeakerId,
                    name: preferredName,
                    confidence: speaker.confidence,
                    wordCount: speaker.wordCount,
                    speakingSeconds: speaker.speakingSeconds
                )
            )
        }

        let updatedUtterances = transcript.utterances.map { utterance in
            guard let canonicalSpeakerId = speakerIdMap[utterance.speakerId] else {
                return utterance
            }
            return AgentUtterance(
                start: utterance.start,
                end: utterance.end,
                speakerId: canonicalSpeakerId,
                text: utterance.text
            )
        }

        return AgentTranscript(
            version: transcript.version,
            transcriptId: transcript.transcriptId,
            recording: transcript.recording,
            speakers: deduplicatedSpeakers,
            utterances: updatedUtterances
        )
    }

    private static func mergedConfidence(_ lhs: String?, _ rhs: String?) -> String? {
        switch (lhs, rhs) {
        case ("high", _), (_, "high"):
            return "high"
        case ("medium", _), (_, "medium"):
            return "medium"
        default:
            return lhs ?? rhs
        }
    }

    private static func rebuildAgentIndex(for folder: URL, speakerStoreForIndex: (any SpeakerStore)?) {
        try? AgentOutput.writeIndex(
            to: folder,
            speakerStore: speakerStoreForIndex ?? SpeakerDatabase.shared
        )
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

    private static func rewriteFullTranscriptSection(
        in content: inout String,
        transcript: AgentTranscript,
        updatesBySystemKey: [String: SpeakerNameUpdate],
        obsidianEnabled: Bool
    ) -> Bool {
        let range = fullTranscriptContentRange(in: content) ?? legacyTranscriptContentRange(in: content)
        guard let range else {
            return false
        }

        let lines = String(content[range]).components(separatedBy: "\n")
        var rewrittenLines = lines
        var utteranceIndex = 0

        for index in lines.indices {
            guard let components = parseTranscriptLine(lines[index]) else { continue }
            guard utteranceIndex < transcript.utterances.count else {
                return false
            }

            let utterance = transcript.utterances[utteranceIndex]
            utteranceIndex += 1

            let expectedTimestamp = formatTranscriptTimestamp(utterance.start)
            let expectedSource = utterance.speakerId.hasPrefix("mic_") ? "Mic" : "System"
            guard components.timestamp == expectedTimestamp,
                  components.source == expectedSource else {
                AppLogger.pipeline.error("Transcript line no longer matches JSON sidecar", [
                    "line": "\(utteranceIndex)",
                    "expectedTimestamp": expectedTimestamp,
                    "actualTimestamp": components.timestamp,
                    "expectedSource": expectedSource,
                    "actualSource": components.source
                ])
                return false
            }

            guard let update = updatesBySystemKey[utterance.speakerId] else { continue }

            let label = transcriptLabel(
                for: update.newName,
                currentLabel: components.label,
                obsidianEnabled: obsidianEnabled
            )
            rewrittenLines[index] = "[\(components.timestamp)] [\(components.source)/\(label)] \(components.text)"
        }

        guard utteranceIndex == transcript.utterances.count else {
            AppLogger.pipeline.error("Transcript body contained fewer utterances than JSON sidecar", [
                "bodyCount": "\(utteranceIndex)",
                "jsonCount": "\(transcript.utterances.count)"
            ])
            return false
        }

        content.replaceSubrange(range, with: rewrittenLines.joined(separator: "\n"))
        return true
    }

    private static func rewriteRemoteSpeakerBreakdown(
        in content: inout String,
        transcript: AgentTranscript
    ) -> Bool {
        guard let replacementRange = remoteSpeakerBreakdownContentRange(in: content) else {
            return false
        }

        let utteranceCounts = Dictionary(
            grouping: transcript.utterances.filter { $0.speakerId.hasPrefix("system_") },
            by: \.speakerId
        ).mapValues(\.count)

        let lines = transcript.speakers
            .filter { $0.id.hasPrefix("system_") }
            .sorted { $0.id < $1.id }
            .map { speaker in
                let speakingTime = DateFormattingHelper.formatDuration(speaker.speakingSeconds)
                let utteranceCount = utteranceCounts[speaker.id] ?? 0
                return "- **\(speaker.name):** \(utteranceCount) utterances, ~\(speaker.wordCount) words, \(speakingTime)"
            }

        content.replaceSubrange(replacementRange, with: lines.joined(separator: "\n"))
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

    private static func legacyTranscriptContentRange(in content: String) -> Range<String.Index>? {
        if let frontmatterEndRange = content.range(
            of: "\n---\n",
            range: content.index(content.startIndex, offsetBy: min(4, content.count))..<content.endIndex
        ) {
            return frontmatterEndRange.upperBound..<content.endIndex
        }

        guard !content.isEmpty else { return nil }
        return content.startIndex..<content.endIndex
    }

    private static func remoteSpeakerBreakdownContentRange(in content: String) -> Range<String.Index>? {
        guard let headerRange = content.range(of: "#### Remote Speaker Breakdown\n\n") else {
            return nil
        }

        if let structuredFooterRange = content.range(
            of: "\n\n---\n\n## Full Transcript",
            range: headerRange.upperBound..<content.endIndex
        ) {
            return headerRange.upperBound..<structuredFooterRange.lowerBound
        }

        if let legacyFooterRange = content.range(
            of: "\n\n---\n",
            range: headerRange.upperBound..<content.endIndex
        ) {
            return headerRange.upperBound..<legacyFooterRange.lowerBound
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
