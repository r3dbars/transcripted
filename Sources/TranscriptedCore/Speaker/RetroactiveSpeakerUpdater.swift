import Foundation

// MARK: - Retroactive Speaker Updates

extension TranscriptSaver {

    /// When a speaker is renamed in Settings, update ALL transcripts that reference them.
    /// Finds transcripts by searching YAML for the speaker's db_id, extracts the old name,
    /// and replaces it in both YAML frontmatter and transcript body.
    /// Thread-safe: serialized via fileUpdateQueue to prevent concurrent file corruption.
    public static func retroactivelyUpdateSpeaker(dbId: UUID, newName: String) {
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

            // Rebuild agent index
            try? AgentOutput.writeIndex(to: dir, speakerStore: SpeakerDatabase.shared)
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
        speakerStore: (any SpeakerStore)? = nil
    ) -> Bool {
        guard !updates.isEmpty else { return true }

        return fileUpdateQueue.sync {
            // The transcript may have been renamed by MeetingTranscriptStyler between save and naming completion.
            let resolvedURL = resolveTranscriptURL(transcriptURL, updates: updates)

            guard var content = try? String(contentsOf: resolvedURL, encoding: .utf8) else {
                AppLogger.pipeline.error("Failed to read transcript for name update", ["path": resolvedURL.path])
                return false
            }

            for update in updates {
                let oldLabel = "Speaker \(update.sortformerSpeakerId)"
                applyNameReplacement(in: &content, oldName: oldLabel, newName: update.newName, updateSpeakerTag: false)
            }

            // Consolidate speaker breakdown when multiple diarizer IDs got the same name.
            // PyAnnote can over-segment one person into 2 clusters; after naming, both become
            // e.g. "Timothy", producing duplicate lines in the breakdown.
            content = consolidateSpeakerBreakdown(content)

            // Atomic write back
            do {
                try content.write(to: resolvedURL, atomically: true, encoding: .utf8)
                AppLogger.pipeline.info("Updated speaker names in transcript", ["path": resolvedURL.lastPathComponent, "updates": "\(updates.count)"])

                // Update JSON sidecar
                updateAgentJSON(
                    transcriptURL: resolvedURL,
                    updates: updates,
                    speakerStore: speakerStore
                )

                return true
            } catch {
                AppLogger.pipeline.error("Failed to write updated transcript", ["error": error.localizedDescription])
                return false
            }
        }
    }

    /// Resolve a transcript URL that may have been renamed by MeetingTranscriptStyler.
    /// Falls back to scanning the parent directory for a .md file containing a matching speaker db_id.
    static func resolveTranscriptURL(_ url: URL, updates: [SpeakerNameUpdate]) -> URL {
        if FileManager.default.fileExists(atPath: url.path) { return url }

        AppLogger.pipeline.info("Transcript not at expected path, scanning for renamed file", ["expected": url.lastPathComponent])

        let dir = url.deletingLastPathComponent()
        guard let firstId = updates.first?.persistentSpeakerId.uuidString,
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter({ $0.pathExtension == "md" }) else {
            return url
        }

        // Read only the YAML frontmatter (first 2 KB) of each file to find the match
        for file in files {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            let header = handle.readData(ofLength: 2048)
            try? handle.close()
            guard let text = String(data: header, encoding: .utf8),
                  text.contains(firstId) else { continue }
            AppLogger.pipeline.info("Resolved renamed transcript", ["from": url.lastPathComponent, "to": file.lastPathComponent])
            return file
        }

        return url
    }

    /// Replace all occurrences of a speaker name throughout a transcript's YAML and body.
    /// Handles YAML frontmatter, body labels, wiki links, and speaker breakdown.
    /// Pass `updateSpeakerTag: true` when the old name also has an Obsidian tag to rename.
    private static func applyNameReplacement(in content: inout String, oldName: String, newName: String, updateSpeakerTag: Bool) {
        // Security: YAML-escape the new name before interpolating into double-quoted scalars
        let yamlSafeName = escapeYAML(newName)
        content = content.replacingOccurrences(of: "name: \"\(oldName)\"", with: "name: \"\(yamlSafeName)\"")
        content = content.replacingOccurrences(of: "[System/\(oldName)]", with: "[System/\(newName)]")
        content = content.replacingOccurrences(of: "[[\(oldName)]]", with: "[[\(newName)]]")
        content = content.replacingOccurrences(of: "**\(oldName):**", with: "**\(newName):**")

        if updateSpeakerTag {
            let oldTag = "speaker/\(oldName.replacingOccurrences(of: " ", with: "-").lowercased())"
            let newTag = "speaker/\(newName.replacingOccurrences(of: " ", with: "-").lowercased())"
            content = content.replacingOccurrences(of: oldTag, with: newTag)
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
    private static func updateAgentJSON(
        transcriptURL: URL,
        updates: [SpeakerNameUpdate],
        speakerStore: (any SpeakerStore)?
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
        try? AgentOutput.writeIndex(
            to: folder,
            speakerStore: speakerStore ?? SpeakerDatabase.shared
        )
    }
}
