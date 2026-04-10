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

            for update in updates {
                let oldLabel = "Speaker \(update.sortformerSpeakerId)"
                applyNameReplacement(in: &content, oldName: oldLabel, newName: update.newName, updateSpeakerTag: false)
                let dbId: UUID = switch update.action {
                case .merged(let targetId):
                    targetId
                case .named, .corrected, .confirmed:
                    update.persistentSpeakerId
                }
                upsertSpeakerDbId(
                    in: &content,
                    sortformerSpeakerId: update.sortformerSpeakerId,
                    dbId: dbId
                )
            }

            // Consolidate speaker breakdown when multiple diarizer IDs got the same name.
            // PyAnnote can over-segment one person into 2 clusters; after naming, both become
            // e.g. "Timothy", producing duplicate lines in the breakdown.
            content = consolidateSpeakerBreakdown(content)

            // Atomic write back
            do {
                try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
                AppLogger.pipeline.info("Updated speaker names in transcript", ["path": transcriptURL.lastPathComponent, "updates": "\(updates.count)"])

                // Update JSON sidecar
                updateAgentJSON(
                    transcriptURL: transcriptURL,
                    updates: updates,
                    speakerStoreForIndex: speakerStoreForIndex
                )

                return true
            } catch {
                AppLogger.pipeline.error("Failed to write updated transcript", ["error": error.localizedDescription])
                return false
            }
        }
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
    private static func updateAgentJSON(
        transcriptURL: URL,
        updates: [SpeakerNameUpdate],
        speakerStoreForIndex: (any SpeakerStore)?
    ) {
        let stem = transcriptURL.deletingPathExtension().lastPathComponent
        let jsonURL = transcriptURL.deletingLastPathComponent().appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              let transcript = try? JSONDecoder().decode(AgentTranscript.self, from: data) else { return }

        // Rebuild speakers with updated names
        var updatedSpeakers = transcript.speakers
        for update in updates {
            let systemKey = "system_\(update.sortformerSpeakerId)"
            if let idx = updatedSpeakers.firstIndex(where: { $0.id == systemKey }) {
                let old = updatedSpeakers[idx]
                let persistentSpeakerId: String?
                switch update.action {
                case .merged(let targetProfileId):
                    persistentSpeakerId = targetProfileId.uuidString
                case .named, .corrected, .confirmed:
                    persistentSpeakerId = update.persistentSpeakerId.uuidString
                }
                updatedSpeakers[idx] = AgentSpeaker(
                    id: old.id,
                    persistentSpeakerId: persistentSpeakerId,
                    name: update.newName,
                    confidence: old.confidence,
                    wordCount: old.wordCount,
                    speakingSeconds: old.speakingSeconds
                )
            }
        }

        let updated = AgentTranscript(
            version: transcript.version,
            recording: transcript.recording,
            speakers: updatedSpeakers,
            utterances: transcript.utterances
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let newData = try? encoder.encode(updated) {
            try? newData.write(to: jsonURL, options: .atomic)
        }

        // Rebuild index
        let folder = transcriptURL.deletingLastPathComponent()
        rebuildAgentIndex(for: folder, speakerStoreForIndex: speakerStoreForIndex)
    }

    private static func updateAgentJSONNames(transcriptURL: URL, dbId: UUID, newName: String) {
        let stem = transcriptURL.deletingPathExtension().lastPathComponent
        let jsonURL = transcriptURL.deletingLastPathComponent().appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              let data = try? Data(contentsOf: jsonURL),
              let transcript = try? JSONDecoder().decode(AgentTranscript.self, from: data) else { return }

        let updated = AgentTranscript(
            version: transcript.version,
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

        let updated = AgentTranscript(
            version: transcript.version,
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

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let newData = try? encoder.encode(updated) {
            try? newData.write(to: jsonURL, options: .atomic)
        }
    }

    private static func rebuildAgentIndex(for folder: URL, speakerStoreForIndex: (any SpeakerStore)?) {
        try? AgentOutput.writeIndex(
            to: folder,
            speakerStore: speakerStoreForIndex ?? SpeakerDatabase.shared
        )
    }
}
