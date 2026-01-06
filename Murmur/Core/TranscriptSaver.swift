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
            print("❌ Failed to create save directory: \(error.localizedDescription)")
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
            print("✓ Transcript saved to: \(fileURL.path)")

            // Show system notification
            showSaveNotification(fileURL: fileURL)

            return fileURL
        } catch {
            print("❌ Failed to save transcript: \(error.localizedDescription)")
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

    // MARK: - Deepgram Multichannel Transcript Saving

    /// Save Deepgram multichannel transcript (stereo: mic=left/ch0, system=right/ch1)
    /// Key advantage: Deepgram supports BOTH multichannel AND speaker diarization!
    /// - Parameters:
    ///   - result: Deepgram multichannel transcription result wrapper
    ///   - speakerMappings: Optional mapping of speaker IDs to identified names
    ///   - directory: Optional custom directory
    ///   - meetingTitle: Optional meeting title extracted from AI
    ///   - healthInfo: Optional recording health metrics for transparency
    /// - Returns: URL of saved file, or nil if save failed
    @available(macOS 14.0, *)
    @discardableResult
    static func saveDeepgramMultichannelTranscript(
        _ result: DeepgramMultichannelTranscriptionResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        directory: URL? = nil,
        meetingTitle: String? = nil,
        healthInfo: RecordingHealthInfo? = nil
    ) -> URL? {
        let saveDir = directory ?? defaultSaveDirectory

        do {
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create save directory: \(error.localizedDescription)")
            return nil
        }

        let timestamp = DateFormattingHelper.formatFilename(Date())
        let filename = "Call_\(timestamp).md"
        let fileURL = saveDir.appendingPathComponent(filename)

        let markdown = formatDeepgramMultichannelMarkdown(result: result, speakerMappings: speakerMappings, date: Date(), healthInfo: healthInfo)

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✓ Deepgram multichannel transcript saved to: \(fileURL.path)")
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
            print("❌ Failed to save Deepgram multichannel transcript: \(error.localizedDescription)")
            return nil
        }
    }

    /// Format Deepgram multichannel transcript as markdown
    @available(macOS 14.0, *)
    private static func formatDeepgramMultichannelMarkdown(
        result: DeepgramMultichannelTranscriptionResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        date: Date,
        healthInfo: RecordingHealthInfo? = nil
    ) -> String {
        let dgResult = result.result
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
        let totalWordCount = dgResult.metadata.micWordCount + dgResult.metadata.systemWordCount
        let totalUtterances = dgResult.metadata.micUtteranceCount + dgResult.metadata.systemUtteranceCount

        // Build YAML frontmatter
        var yaml = """
        ---
        date: \(isoDate)
        time: \(timeString)
        duration: "\(durationString)"
        processing_time: "\(String(format: "%.1f", result.processingTime))s"
        transcription_engine: deepgram_multichannel
        sources: [mic, system_audio]
        mic_utterances: \(dgResult.metadata.micUtteranceCount)
        system_utterances: \(dgResult.metadata.systemUtteranceCount)
        mic_speakers: \(dgResult.metadata.micSpeakerCount)
        system_speakers: \(dgResult.metadata.systemSpeakerCount)
        total_word_count: \(totalWordCount)
        """

        // Add recording health metadata (Phase 3: Post-hoc transparency)
        if let health = healthInfo {
            yaml += "\ncapture_quality: \(health.captureQuality.rawValue)"
            yaml += "\naudio_gaps: \(health.audioGaps)"
            yaml += "\ndevice_switches: \(health.deviceSwitches)"

            // Add gap details if any occurred
            if !health.gapDescriptions.isEmpty {
                yaml += "\ngap_events:"
                for gap in health.gapDescriptions {
                    yaml += "\n  - \"\(gap)\""
                }
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
        let micTimeSeconds = dgResult.micUtterances.reduce(0.0) { $0 + ($1.end - $1.start) }
        let micTimeStr = DateFormattingHelper.formatDuration(micTimeSeconds)
        doc += "### Microphone (You)\n"
        doc += "- **Utterances:** \(dgResult.metadata.micUtteranceCount)\n"
        doc += "- **Words:** ~\(dgResult.metadata.micWordCount)\n"
        doc += "- **Speaking Time:** \(micTimeStr)\n"
        if dgResult.metadata.micSpeakerCount > 1 {
            doc += "- **Speakers Detected:** \(dgResult.metadata.micSpeakerCount)\n"
        }
        doc += "\n"

        // System channel stats with speaker breakdown
        let sysTimeSeconds = dgResult.systemUtterances.reduce(0.0) { $0 + ($1.end - $1.start) }
        let sysTimeStr = DateFormattingHelper.formatDuration(sysTimeSeconds)
        doc += "### Meeting Audio (Remote Participants)\n"
        doc += "- **Utterances:** \(dgResult.metadata.systemUtteranceCount)\n"
        doc += "- **Words:** ~\(dgResult.metadata.systemWordCount)\n"
        doc += "- **Speaking Time:** \(sysTimeStr)\n"
        doc += "- **Speakers Detected:** \(dgResult.metadata.systemSpeakerCount)\n\n"

        // Speaker breakdown within system audio (the key advantage of Deepgram!)
        if dgResult.metadata.systemSpeakerCount > 0 {
            doc += "#### Remote Speaker Breakdown\n\n"
            let speakerGroups = Dictionary(grouping: dgResult.systemUtterances, by: { $0.speaker })
            for speaker in speakerGroups.keys.sorted() {
                let utterances = speakerGroups[speaker] ?? []
                let wordCount = utterances.reduce(0) { $0 + $1.transcript.split(separator: " ").count }
                let speakingTime = utterances.reduce(0.0) { $0 + ($1.end - $1.start) }
                let speakingTimeStr = DateFormattingHelper.formatDuration(speakingTime)

                // Use speaker mapping if available
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
        for utterance in dgResult.allUtterances {
            // Deepgram uses seconds, convert to MM:SS
            let startMinutes = Int(utterance.start) / 60
            let startSeconds = Int(utterance.start) % 60
            let timestampStr = String(format: "%02d:%02d", startMinutes, startSeconds)

            // Determine source from channel
            let source = utterance.channel == 0 ? "Mic" : "System"

            // Determine speaker name
            let speakerLabel: String
            if utterance.channel == 0 {
                // Mic channel - typically just "You"
                let speakerKey = "mic_\(utterance.speaker)"
                speakerLabel = speakerMappings[speakerKey]?.displayName ?? "You"
            } else {
                // System channel - use diarized speaker IDs
                let speakerKey = "system_\(utterance.speaker)"
                speakerLabel = speakerMappings[speakerKey]?.displayName ?? "Speaker \(utterance.speaker)"
            }

            let confidence = String(format: "%.0f%%", utterance.confidence * 100)

            doc += "[\(timestampStr)] [\(source)/\(speakerLabel)] (\(confidence)) \(utterance.transcript)\n\n"
        }

        // SECTION 4: Word-level Details (collapsible)
        let allWords = dgResult.micWords + dgResult.systemWords
        if !allWords.isEmpty {
            doc += "---\n\n"
            doc += "<details>\n<summary>Word-level Details (\(allWords.count) words)</summary>\n\n"
            doc += "| Time | Word | Confidence | Channel | Speaker |\n"
            doc += "|------|------|------------|---------|--------|\n"

            // Sort all words by start time
            let sortedWords = allWords.sorted { $0.start < $1.start }

            for word in sortedWords.prefix(150) {
                let time = String(format: "%.2f", word.start)
                let conf = String(format: "%.0f%%", word.confidence * 100)
                // Determine channel based on which array the word came from
                let isMicWord = dgResult.micWords.contains { $0.start == word.start && $0.word == word.word }
                let channel = isMicWord ? "Mic" : "System"
                let speaker = word.speaker.map { String($0) } ?? "-"
                doc += "| \(time)s | \(word.word) | \(conf) | \(channel) | \(speaker) |\n"
            }

            if allWords.count > 150 {
                doc += "\n*... and \(allWords.count - 150) more words*\n"
            }

            doc += "\n</details>\n\n"
        }

        // Footer
        doc += "---\n\n"
        let totalSpeakers = dgResult.metadata.micSpeakerCount + dgResult.metadata.systemSpeakerCount
        doc += "*Generated by Transcripted with Deepgram Multichannel • Duration: \(durationString) • \(totalWordCount) words • \(totalSpeakers) speakers*\n"

        return doc
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
