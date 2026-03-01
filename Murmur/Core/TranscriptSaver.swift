import Foundation
import AppKit

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

        // Generate filename with timestamp
        let timestamp = DateFormattingHelper.formatFilename(Date())
        let filename = "Call_\(timestamp).md"
        let fileURL = saveDir.appendingPathComponent(filename)

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
        let filename = "Call_\(timestamp).md"
        let fileURL = saveDir.appendingPathComponent(filename)

        let markdown = formatTranscriptMarkdown(result: result, speakerMappings: speakerMappings, speakerSources: speakerSources, date: Date(), healthInfo: healthInfo)

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
                    yaml += "\n  - \"\(gap)\""
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
                let confidence = mapping.confidence ?? "unknown"
                let source = speakerSources[mapping.speakerId] ?? "unknown"
                yaml += "\n  - id: \"\(mapping.speakerId)\""
                yaml += "\n    name: \"\(name)\""
                yaml += "\n    confidence: \(confidence)"
                yaml += "\n    source: \(source)"
            }
        }

        yaml += "\n---\n"

        // Build document
        var doc = yaml
        doc += "\n# Meeting Recording - \(dateString)\n\n"
        doc += "**Duration:** \(durationString) | **Words:** \(totalWordCount) | **Utterances:** \(totalUtterances)\n\n"
        doc += "---\n\n"

        // SECTION 1: Summary placeholder
        doc += "## Summary\n\n"
        doc += "*Summary generation available with Gemini integration*\n\n"

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

            doc += "[\(timestampStr)] [\(source)/\(speakerLabel)] \(utterance.transcript)\n\n"
        }

        // Footer
        doc += "---\n\n"
        let totalSpeakers = result.micSpeakerCount + result.systemSpeakerCount
        doc += "*Generated by Transcripted with Parakeet + Sortformer (local) | Duration: \(durationString) | \(totalWordCount) words | \(totalSpeakers) speakers*\n"

        return doc
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

    /// Show macOS notification that transcript was saved
    private static func showSaveNotification(fileURL: URL) {
        let notification = NSUserNotification()
        notification.title = "Transcript Saved"
        notification.informativeText = fileURL.lastPathComponent
        notification.soundName = nil // Silent notification

        // Add action to open in Finder
        notification.hasActionButton = true
        notification.actionButtonTitle = "Show in Finder"

        // Deliver notification
        NSUserNotificationCenter.default.deliver(notification)

        // Set up delegate to handle "Show in Finder" action
        let delegate = NotificationDelegate(fileURL: fileURL)
        NSUserNotificationCenter.default.delegate = delegate

        // Keep delegate alive (store in static property)
        notificationDelegates.append(delegate)
    }

    // Keep notification delegates alive
    private static var notificationDelegates: [NotificationDelegate] = []
}

/// Delegate to handle notification actions (e.g., "Show in Finder")
private class NotificationDelegate: NSObject, NSUserNotificationCenterDelegate {
    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        if notification.activationType == .actionButtonClicked {
            // Open in Finder and select the file
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    // Always show notifications even if app is in foreground
    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        return true
    }
}
