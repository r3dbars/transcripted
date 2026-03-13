import Foundation
import AppKit
import UserNotifications

/// Recording health information for transcript metadata (Phase 3)
/// Captures quality metrics to be embedded in transcript YAML frontmatter
struct RecordingHealthInfo {
    /// Capture quality rating based on buffer success rate
    enum CaptureQuality: String {
        case excellent = "excellent"  // >= 98%
        case good = "good"            // 90-97%
        case fair = "fair"            // 80-89%
        case degraded = "degraded"    // < 80%

        static func from(successRate: Double) -> CaptureQuality {
            switch successRate {
            case 0.98...: return .excellent
            case 0.90..<0.98: return .good
            case 0.80..<0.90: return .fair
            default: return .degraded
            }
        }
    }

    let captureQuality: CaptureQuality
    let audioGaps: Int
    let deviceSwitches: Int
    let gapDescriptions: [String]

    /// Create health info from Audio instance
    @available(macOS 26.0, *)
    static func from(audio: Audio, systemCapture: SystemAudioCapture?) -> RecordingHealthInfo {
        let successRate = systemCapture?.bufferSuccessRate ?? 1.0
        return RecordingHealthInfo(
            captureQuality: CaptureQuality.from(successRate: successRate),
            audioGaps: audio.recordingGaps.count,
            deviceSwitches: audio.deviceSwitchCount,
            gapDescriptions: audio.recordingGaps.map { $0.description }
        )
    }

    /// Default "no issues" health info
    static var perfect: RecordingHealthInfo {
        RecordingHealthInfo(
            captureQuality: .excellent,
            audioGaps: 0,
            deviceSwitches: 0,
            gapDescriptions: []
        )
    }
}

/// Handles automatic saving of transcripts to the filesystem
class TranscriptSaver {

    /// Default save location: ~/Documents/Transcripted/
    /// Reads custom location from UserDefaults if set
    static var defaultSaveDirectory: URL {
        // Check for custom save location first
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }

        // Fall back to default location
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Transcripted")
    }

    /// Save transcript to file with automatic timestamped naming
    /// - Parameters:
    ///   - text: The transcript text to save
    ///   - duration: Recording duration in seconds
    ///   - directory: Optional custom directory (defaults to ~/Documents/Transcripted/)
    /// - Returns: URL of saved file, or nil if save failed
    @discardableResult
    static func save(text: String, duration: TimeInterval, directory: URL? = nil) -> URL? {
        // Use default directory if not specified
        let saveDir = directory ?? defaultSaveDirectory

        // Create directory if it doesn't exist
        do {
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.pipeline.error("Failed to create save directory", ["error": error.localizedDescription])
            return nil
        }

        // Generate filename with timestamp, avoiding collisions
        let timestamp = DateFormattingHelper.formatFilename(Date())
        var fileURL = saveDir.appendingPathComponent("Call_\(timestamp).md")
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = saveDir.appendingPathComponent("Call_\(timestamp)_\(counter).md")
            counter += 1
        }

        // Create markdown content with metadata
        let markdown = formatMarkdown(text: text, duration: duration, date: Date())

        // Write to file
        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            AppLogger.pipeline.info("Transcript saved", ["path": fileURL.path])

            // Show system notification
            showSaveNotification(fileURL: fileURL)

            return fileURL
        } catch {
            AppLogger.pipeline.error("Failed to save transcript", ["error": error.localizedDescription])
            return nil
        }
    }


    /// Format source label for timeline display
    /// Escape special characters for safe YAML string interpolation
    private static func escapeYAML(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func formatSourceLabel(_ source: String) -> String {
        // Map "System Audio" to shorter "SysAudio"
        return source == "System Audio" ? "SysAudio" : source
    }

    /// Format transcript as markdown with metadata header
    private static func formatMarkdown(text: String, duration: TimeInterval, date: Date) -> String {
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

    // MARK: - Local Transcript Saving (Parakeet + Sortformer)

    /// Save transcript from local Parakeet + Sortformer pipeline
    /// - Parameters:
    ///   - result: TranscriptionResult from local pipeline
    ///   - speakerMappings: Optional mapping of speaker IDs to identified names
    ///   - directory: Optional custom directory
    ///   - meetingTitle: Optional meeting title extracted from AI
    ///   - healthInfo: Optional recording health metrics for transparency
    /// - Returns: URL of saved file, or nil if save failed
    @available(macOS 14.0, *)
    @discardableResult
    static func saveTranscript(
        _ result: TranscriptionResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        speakerSources: [String: String] = [:],
        speakerDbIds: [String: UUID] = [:],
        directory: URL? = nil,
        meetingTitle: String? = nil,
        healthInfo: RecordingHealthInfo? = nil
    ) -> URL? {
        let saveDir = directory ?? defaultSaveDirectory

        do {
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.pipeline.error("Failed to create save directory", ["error": error.localizedDescription])
            return nil
        }

        let timestamp = DateFormattingHelper.formatFilename(Date())
        var fileURL = saveDir.appendingPathComponent("Call_\(timestamp).md")
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = saveDir.appendingPathComponent("Call_\(timestamp)_\(counter).md")
            counter += 1
        }

        let markdown = formatTranscriptMarkdown(result: result, speakerMappings: speakerMappings, speakerSources: speakerSources, speakerDbIds: speakerDbIds, date: Date(), healthInfo: healthInfo)

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            AppLogger.pipeline.info("Transcript saved", ["path": fileURL.path])
            showSaveNotification(fileURL: fileURL)

            // Record to stats database
            Task { @MainActor in
                let metadata = StatsService.createMetadata(
                    from: result,
                    transcriptPath: fileURL.path,
                    title: meetingTitle
                )
                await StatsService.shared.recordSession(metadata)
            }

            return fileURL
        } catch {
            AppLogger.pipeline.error("Failed to save transcript", ["error": error.localizedDescription])
            return nil
        }
    }

    /// Format local transcript as markdown with YAML frontmatter
    @available(macOS 14.0, *)
    private static func formatTranscriptMarkdown(
        result: TranscriptionResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        speakerSources: [String: String] = [:],
        speakerDbIds: [String: UUID] = [:],
        date: Date,
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
        diarization_engine: sortformer_local
        sources: [mic, system_audio]
        mic_utterances: \(result.micUtteranceCount)
        system_utterances: \(result.systemUtteranceCount)
        mic_speakers: \(result.micSpeakerCount)
        system_speakers: \(result.systemSpeakerCount)
        total_word_count: \(totalWordCount)
        """

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
        doc += "*Generated by Transcripted with Parakeet + Sortformer (local) | Duration: \(durationString) | \(totalWordCount) words | \(totalSpeakers) speakers*\n"

        return doc
    }

    // MARK: - Retroactive Speaker Updates

    /// Serial queue for file updates — prevents concurrent reads/writes from corrupting transcripts
    private static let fileUpdateQueue = DispatchQueue(label: "com.transcripted.fileupdate", qos: .utility)

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

        // Atomic write back
        do {
            try content.write(to: transcriptURL, atomically: true, encoding: .utf8)
            AppLogger.pipeline.info("Updated speaker names in transcript", ["path": transcriptURL.lastPathComponent, "updates": "\(updates.count)"])

            return true
        } catch {
            AppLogger.pipeline.error("Failed to write updated transcript", ["error": error.localizedDescription])
            return false
        }
    }

    /// Notification category identifier for "Show in Finder" action
    fileprivate static let notificationCategoryId = "TRANSCRIPT_SAVED"
    fileprivate static let showInFinderActionId = "SHOW_IN_FINDER"

    /// Set up notification categories (call once at app startup)
    static func registerNotificationCategories() {
        let showAction = UNNotificationAction(
            identifier: showInFinderActionId,
            title: "Show in Finder",
            options: .foreground
        )
        let category = UNNotificationCategory(
            identifier: notificationCategoryId,
            actions: [showAction],
            intentIdentifiers: []
        )
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }

    /// Show macOS notification that transcript was saved
    private static func showSaveNotification(fileURL: URL) {
        let center = UNUserNotificationCenter.current()

        // Set delegate so we receive action callbacks
        if notificationDelegate == nil {
            let delegate = SaveNotificationDelegate()
            notificationDelegate = delegate
            center.delegate = delegate
        }

        // Store the file URL for the "Show in Finder" action
        notificationDelegate?.latestFileURL = fileURL

        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }

            let content = UNMutableNotificationContent()
            content.title = "Transcript Saved"
            content.body = fileURL.lastPathComponent
            content.categoryIdentifier = notificationCategoryId

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil // deliver immediately
            )

            center.add(request) { error in
                if let error = error {
                    AppLogger.pipeline.error("Failed to deliver notification", ["error": error.localizedDescription])
                }
            }
        }
    }

    private static var notificationDelegate: SaveNotificationDelegate?
}

/// Delegate to handle UNUserNotification actions (e.g., "Show in Finder")
private class SaveNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    var latestFileURL: URL?

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == TranscriptSaver.showInFinderActionId,
           let url = latestFileURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        completionHandler()
    }

    // Show notifications even when app is in foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner])
    }
}
