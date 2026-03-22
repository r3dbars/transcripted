import Foundation

// MARK: - Retroactive Speaker Updates

extension TranscriptSaver {

    /// When a speaker is renamed in Settings, update ALL transcripts that reference them.
    /// Finds transcripts by searching YAML for the speaker's db_id, extracts the old name,
    /// and replaces it in both YAML frontmatter and transcript body.
    /// Thread-safe: serialized via fileUpdateQueue to prevent concurrent file corruption.
    static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String) {
        fileUpdateQueue.sync {
            _retroactivelyUpdateSpeakerImpl(dbId: dbId, newName: newName)
        }
    }

    private static func _retroactivelyUpdateSpeakerImpl(dbId: UUID, newName: String) {
        let dir = defaultSaveDirectory
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
                        if let range = nameLine.range(of: "name: \""),
                           let endRange = nameLine[range.upperBound...].range(of: "\"") {
                            let oldName = String(nameLine[range.upperBound..<endRange.lowerBound])
                            if oldName != newName && !oldNames.contains(oldName) {
                                oldNames.append(oldName)
                            }
                        }
                    }
                }
            }

            guard !oldNames.isEmpty else { continue }

            for oldName in oldNames {
                // YAML frontmatter: name: "OldName" → name: "NewName"
                content = content.replacingOccurrences(
                    of: "name: \"\(oldName)\"",
                    with: "name: \"\(newName)\""
                )

                // Transcript body: [System/OldName] → [System/NewName]
                content = content.replacingOccurrences(
                    of: "[System/\(oldName)]",
                    with: "[System/\(newName)]"
                )

                // Obsidian wiki links: [[OldName]] → [[NewName]]
                content = content.replacingOccurrences(
                    of: "[[\(oldName)]]",
                    with: "[[\(newName)]]"
                )

                // Obsidian speaker tags: speaker/old-name → speaker/new-name
                let oldTag = "speaker/\(oldName.replacingOccurrences(of: " ", with: "-").lowercased())"
                let newTag = "speaker/\(newName.replacingOccurrences(of: " ", with: "-").lowercased())"
                content = content.replacingOccurrences(of: oldTag, with: newTag)

                // Speaker breakdown: **OldName:** → **NewName:**
                content = content.replacingOccurrences(
                    of: "**\(oldName):**",
                    with: "**\(newName):**"
                )
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

            // Rebuild agent index
            try? AgentOutput.writeIndex(to: dir, speakerDB: SpeakerDatabase.shared)
        }
    }

    // MARK: - Retroactive Title Update

    /// Insert or update the title field in a transcript's YAML frontmatter.
    /// Called after Qwen inference completes (which runs after initial save).
    /// Thread-safe: serialized via fileUpdateQueue.
    @discardableResult
    static func retroactivelyUpdateTitle(transcriptURL: URL, title: String) -> Bool {
        fileUpdateQueue.sync {
            guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for title update", ["path": transcriptURL.path])
                return false
            }

            // Only update YAML frontmatter
            guard content.hasPrefix("---"),
                  let endRange = content.range(
                      of: "\n---\n",
                      range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex
                  ) else {
                return false
            }

            let yamlRange = content.startIndex..<endRange.upperBound
            var yaml = String(content[yamlRange])

            if yaml.contains("\ntitle:") {
                // Replace existing title
                let lines = yaml.components(separatedBy: "\n")
                let updatedLines = lines.map { line -> String in
                    if line.trimmingCharacters(in: .whitespaces).hasPrefix("title:") {
                        return "title: \"\(escapeYAML(title))\""
                    }
                    return line
                }
                yaml = updatedLines.joined(separator: "\n")
            } else {
                // Insert title after total_word_count (or before closing ---)
                yaml = yaml.replacingOccurrences(
                    of: "\n---\n",
                    with: "\ntitle: \"\(escapeYAML(title))\"\n---\n"
                )
            }

            content.replaceSubrange(yamlRange, with: yaml)

            do {
                try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
                AppLogger.pipeline.info("Retroactively updated meeting title", ["file": transcriptURL.lastPathComponent, "title": title])
                return true
            } catch {
                AppLogger.pipeline.warning("Failed to update title retroactively", ["error": error.localizedDescription])
                return false
            }
        }
    }

    // MARK: - Speaker Name Updating (Post-Naming Flow)

    /// Update speaker names in an already-saved transcript file.
    /// Replaces "Speaker X" labels in both YAML frontmatter and transcript body.
    ///
    /// - Parameters:
    ///   - transcriptURL: Path to the saved markdown transcript
    ///   - updates: Speaker name updates from the naming flow
    /// - Returns: true if the file was updated successfully
    @discardableResult
    static func updateSpeakerNames(transcriptURL: URL, updates: [SpeakerNameUpdate]) -> Bool {
        guard !updates.isEmpty else { return true }

        guard var content = try? String(contentsOf: transcriptURL, encoding: .utf8) else {
            AppLogger.pipeline.error("Failed to read transcript for name update", ["path": transcriptURL.path])
            return false
        }

        for update in updates {
            let speakerId = update.sortformerSpeakerId
            let oldLabel = "Speaker \(speakerId)"
            let newName = update.newName

            // YAML frontmatter: name: "Speaker X" → name: "NewName"
            content = content.replacingOccurrences(
                of: "name: \"\(oldLabel)\"",
                with: "name: \"\(newName)\""
            )

            // Transcript body: [System/Speaker X] → [System/NewName]
            content = content.replacingOccurrences(
                of: "[System/\(oldLabel)]",
                with: "[System/\(newName)]"
            )

            // Obsidian wiki links: [[Speaker X]] → [[NewName]]
            content = content.replacingOccurrences(
                of: "[[\(oldLabel)]]",
                with: "[[\(newName)]]"
            )

            // Speaker breakdown: **Speaker X:** → **NewName:**
            content = content.replacingOccurrences(
                of: "**\(oldLabel):**",
                with: "**\(newName):**"
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
            updateAgentJSON(transcriptURL: transcriptURL, updates: updates)

            return true
        } catch {
            AppLogger.pipeline.error("Failed to write updated transcript", ["error": error.localizedDescription])
            return false
        }
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
    private static func updateAgentJSON(transcriptURL: URL, updates: [SpeakerNameUpdate]) {
        let stem = transcriptURL.deletingPathExtension().lastPathComponent
        let jsonURL = transcriptURL.deletingLastPathComponent().appendingPathComponent("\(stem).json")
        guard FileManager.default.fileExists(atPath: jsonURL.path),
              var data = try? Data(contentsOf: jsonURL),
              var transcript = try? JSONDecoder().decode(AgentTranscript.self, from: data) else { return }

        // Rebuild speakers with updated names
        var updatedSpeakers = transcript.speakers
        for update in updates {
            let systemKey = "system_\(update.sortformerSpeakerId)"
            if let idx = updatedSpeakers.firstIndex(where: { $0.id == systemKey }) {
                let old = updatedSpeakers[idx]
                updatedSpeakers[idx] = AgentSpeaker(
                    id: old.id,
                    persistentSpeakerId: old.persistentSpeakerId,
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
        try? AgentOutput.writeIndex(to: folder, speakerDB: SpeakerDatabase.shared)
    }
}
