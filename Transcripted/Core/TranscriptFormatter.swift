import Foundation

// MARK: - Transcript Formatting

extension TranscriptSaver {

    /// Format source label for timeline display
    /// Escape special characters for safe YAML string interpolation
    static func escapeYAML(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func formatSourceLabel(_ source: String) -> String {
        // Map "System Audio" to shorter "SysAudio"
        return source == "System Audio" ? "SysAudio" : source
    }

    /// Format transcript as markdown with metadata header
    static func formatMarkdown(text: String, duration: TimeInterval, date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateString = dateFormatter.string(from: date)

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let durationString = String(format: "%d:%02d", minutes, seconds)

        let wordCount = text.split(separator: " ").count

        return """
        # Call Recording - \(dateString)

        **Duration:** \(durationString)
        **Words:** \(wordCount)
        **Date:** \(DateFormattingHelper.formatDisplay(date))

        ---

        \(text.isEmpty ? "*No transcript available*" : text)

        ---

        *Recorded with Transcripted*
        """
    }

    /// Format local transcript as markdown with YAML frontmatter
    @available(macOS 14.0, *)
    static func formatTranscriptMarkdown(
        result: TranscriptionResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        speakerSources: [String: String] = [:],
        speakerDbIds: [String: UUID] = [:],
        date: Date,
        meetingTitle: String? = nil,
        healthInfo: RecordingHealthInfo? = nil
    ) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateString = dateFormatter.string(from: date)

        let minutes = Int(result.duration) / 60
        let seconds = Int(result.duration) % 60
        let durationString = String(format: "%d:%02d", minutes, seconds)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let timeString = timeFormatter.string(from: date)

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        let isoDate = isoFormatter.string(from: date)

        // Aggregate metadata
        let totalWordCount = result.micWordCount + result.systemWordCount
        let totalUtterances = result.micUtteranceCount + result.systemUtteranceCount

        // Build YAML frontmatter
        var yaml = """
        ---
        date: \(isoDate)
        time: \(timeString)
        duration: "\(durationString)"
        processing_time: "\(String(format: "%.1f", result.processingTime))s"
        transcription_engine: parakeet_local
        diarization_engine: pyannote_offline
        sources: [mic, system_audio]
        mic_utterances: \(result.micUtteranceCount)
        system_utterances: \(result.systemUtteranceCount)
        mic_speakers: \(result.micSpeakerCount)
        system_speakers: \(result.systemSpeakerCount)
        total_word_count: \(totalWordCount)
        """

        // Add meeting title if available (from Qwen inference)
        if let title = meetingTitle, !title.isEmpty {
            yaml += "\ntitle: \"\(Self.escapeYAML(title))\""
        }

        // Add recording health metadata (Phase 3: Post-hoc transparency)
        if let health = healthInfo {
            yaml += "\ncapture_quality: \(health.captureQuality.rawValue)"
            yaml += "\naudio_gaps: \(health.audioGaps)"
            yaml += "\ndevice_switches: \(health.deviceSwitches)"

            if !health.gapDescriptions.isEmpty {
                yaml += "\ngap_events:"
                for gap in health.gapDescriptions {
                    yaml += "\n  - \"\(Self.escapeYAML(gap))\""
                }
            }
        }

        // Add speaker identification metadata
        let sortedSpeakerKeys = speakerMappings.keys.sorted()
        if !sortedSpeakerKeys.isEmpty {
            yaml += "\nspeakers:"
            for key in sortedSpeakerKeys {
                guard let mapping = speakerMappings[key] else { continue }
                let name = mapping.identifiedName ?? "Unknown"
                let confidence = mapping.confidence?.rawValue ?? "unknown"
                let source = speakerSources[mapping.speakerId] ?? "unknown"
                yaml += "\n  - id: \"\(Self.escapeYAML(mapping.speakerId))\""
                if let dbId = speakerDbIds[mapping.speakerId] {
                    yaml += "\n    db_id: \"\(dbId.uuidString)\""
                }
                yaml += "\n    name: \"\(Self.escapeYAML(name))\""
                yaml += "\n    confidence: \(confidence)"
                yaml += "\n    source: \(source)"
            }
        }

        // Obsidian-compatible metadata (tags, aliases, cssclasses)
        let obsidianEnabled = UserDefaults.standard.bool(forKey: "enableObsidianFormat")
        if obsidianEnabled {
            yaml += "\ntags:"
            yaml += "\n  - transcripted"
            yaml += "\n  - meeting"
            // Add speaker tags for named participants
            for key in sortedSpeakerKeys {
                guard let mapping = speakerMappings[key],
                      let name = mapping.identifiedName,
                      !name.isEmpty else { continue }
                let sanitized = name.replacingOccurrences(of: " ", with: "-").lowercased()
                yaml += "\n  - speaker/\(sanitized)"
            }
            yaml += "\naliases:"
            yaml += "\n  - \"Meeting \(isoDate) \(timeString)\""
            yaml += "\ncssclasses:"
            yaml += "\n  - transcripted"
        }

        yaml += "\n---\n"

        // Build document
        var doc = yaml
        doc += "\n# Meeting Recording - \(dateString)\n\n"
        doc += "**Duration:** \(durationString) | **Words:** \(totalWordCount) | **Utterances:** \(totalUtterances)\n\n"
        doc += "---\n\n"

        // SECTION 1: Summary placeholder
        doc += "## Summary\n\n"
        doc += "*Paste into your favorite AI tool for summary generation*\n\n"

        // SECTION 2: Channel & Speaker Analytics
        doc += "---\n\n"
        doc += "## Channel & Speaker Analytics\n\n"

        // Mic channel stats
        let micTimeSeconds = result.micUtterances.reduce(0.0) { $0 + ($1.end - $1.start) }
        let micTimeStr = DateFormattingHelper.formatDuration(micTimeSeconds)
        doc += "### Microphone (You)\n"
        doc += "- **Utterances:** \(result.micUtteranceCount)\n"
        doc += "- **Words:** ~\(result.micWordCount)\n"
        doc += "- **Speaking Time:** \(micTimeStr)\n"
        if result.micSpeakerCount > 1 {
            doc += "- **Speakers Detected:** \(result.micSpeakerCount)\n"
        }
        doc += "\n"

        // System channel stats with speaker breakdown
        let sysTimeSeconds = result.systemUtterances.reduce(0.0) { $0 + ($1.end - $1.start) }
        let sysTimeStr = DateFormattingHelper.formatDuration(sysTimeSeconds)
        doc += "### Meeting Audio (Remote Participants)\n"
        doc += "- **Utterances:** \(result.systemUtteranceCount)\n"
        doc += "- **Words:** ~\(result.systemWordCount)\n"
        doc += "- **Speaking Time:** \(sysTimeStr)\n"
        doc += "- **Speakers Detected:** \(result.systemSpeakerCount)\n\n"

        // Speaker breakdown within system audio
        if result.systemSpeakerCount > 0 {
            doc += "#### Remote Speaker Breakdown\n\n"
            let speakerGroups = Dictionary(grouping: result.systemUtterances, by: { $0.speakerId })
            for speaker in speakerGroups.keys.sorted() {
                let utterances = speakerGroups[speaker] ?? []
                let wordCount = utterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
                let speakingTime = utterances.reduce(0.0) { $0 + ($1.end - $1.start) }
                let speakingTimeStr = DateFormattingHelper.formatDuration(speakingTime)

                let speakerKey = "system_\(speaker)"
                let speakerName = speakerMappings[speakerKey]?.displayName ?? "Speaker \(speaker)"

                doc += "- **\(speakerName):** \(utterances.count) utterances, ~\(wordCount) words, \(speakingTimeStr)\n"
            }
            doc += "\n"
        }

        // SECTION 3: Full Transcript
        doc += "---\n\n"
        doc += "## Full Transcript\n\n"

        // Merge all utterances sorted by timestamp
        for utterance in result.allUtterances {
            let startMinutes = Int(utterance.start) / 60
            let startSeconds = Int(utterance.start) % 60
            let timestampStr = String(format: "%02d:%02d", startMinutes, startSeconds)

            let source = utterance.channel == 0 ? "Mic" : "System"

            let speakerLabel: String
            if utterance.channel == 0 {
                let speakerKey = "mic_\(utterance.speakerId)"
                speakerLabel = speakerMappings[speakerKey]?.displayName ?? "You"
            } else {
                let speakerKey = "system_\(utterance.speakerId)"
                speakerLabel = speakerMappings[speakerKey]?.displayName ?? "Speaker \(utterance.speakerId)"
            }

            // Obsidian: wrap named speakers in [[wiki links]]
            let displayLabel: String
            if obsidianEnabled && speakerLabel != "You" && !speakerLabel.hasPrefix("Speaker ") {
                displayLabel = "[[\(speakerLabel)]]"
            } else {
                displayLabel = speakerLabel
            }

            doc += "[\(timestampStr)] [\(source)/\(displayLabel)] \(utterance.transcript)\n\n"
        }

        // Obsidian: participants section with wiki links
        if obsidianEnabled {
            let namedSpeakers = speakerMappings.values
                .compactMap { $0.identifiedName }
                .filter { !$0.isEmpty }
            if !namedSpeakers.isEmpty {
                doc += "---\n\n"
                doc += "**Participants:** "
                doc += namedSpeakers.sorted().map { "[[\($0)]]" }.joined(separator: ", ")
                doc += "\n\n"
            }
        }

        // Footer
        doc += "---\n\n"
        let totalSpeakers = result.micSpeakerCount + result.systemSpeakerCount
        doc += "*Generated by Transcripted with Parakeet + PyAnnote (local) | Duration: \(durationString) | \(totalWordCount) words | \(totalSpeakers) speakers*\n"

        return doc
    }
}
