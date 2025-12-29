import Foundation
import AppKit

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
        let timestamp = formatTimestamp(Date())
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


    /// Format timestamp for filename (YYYY-MM-DD_HH-mm-ss)
    private static func formatTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    /// Format TimeInterval as MM:SS
    private static func formatTimeInterval(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
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
        **Date:** \(formatTimestamp(date))

        ---

        \(text.isEmpty ? "*No transcript available*" : text)

        ---

        *Recorded with Transcripted*
        """
    }

    // MARK: - AssemblyAI Transcript Saving

    /// Save rich AssemblyAI transcript with all metadata
    /// - Parameters:
    ///   - result: Full AssemblyAI transcription result with all metadata
    ///   - source: Source label for the audio (e.g., "Test", "Mic", "Recording")
    ///   - directory: Optional custom directory
    /// - Returns: URL of saved file, or nil if save failed
    @available(macOS 14.0, *)
    @discardableResult
    static func saveAssemblyAITranscript(_ result: AssemblyAITranscriptionResult, source: String = "Recording", directory: URL? = nil) -> URL? {
        let saveDir = directory ?? defaultSaveDirectory

        do {
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create save directory: \(error.localizedDescription)")
            return nil
        }

        let timestamp = formatTimestamp(Date())
        let filename = "Call_\(timestamp)_AssemblyAI.md"
        let fileURL = saveDir.appendingPathComponent(filename)

        let markdown = formatAssemblyAIMarkdown(result: result, source: source, date: Date())

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✓ AssemblyAI transcript saved to: \(fileURL.path)")
            showSaveNotification(fileURL: fileURL)
            return fileURL
        } catch {
            print("❌ Failed to save AssemblyAI transcript: \(error.localizedDescription)")
            return nil
        }
    }

    /// Format rich AssemblyAI transcript as markdown
    @available(macOS 14.0, *)
    private static func formatAssemblyAIMarkdown(result: AssemblyAITranscriptionResult, source: String, date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateString = dateFormatter.string(from: date)

        let duration = result.metadata.duration ?? 0
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let durationString = String(format: "%d:%02d", minutes, seconds)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let timeString = timeFormatter.string(from: date)

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        let isoDate = isoFormatter.string(from: date)

        // Determine overall sentiment from sentiment results
        var overallSentiment = "neutral"
        if !result.sentimentResults.isEmpty {
            let sentimentCounts = Dictionary(grouping: result.sentimentResults, by: { $0.sentiment })
            let positiveCount = sentimentCounts["POSITIVE"]?.count ?? 0
            let negativeCount = sentimentCounts["NEGATIVE"]?.count ?? 0
            if positiveCount > negativeCount {
                overallSentiment = "positive"
            } else if negativeCount > positiveCount {
                overallSentiment = "negative"
            }
        }

        // Build YAML frontmatter with all metadata
        var yaml = """
        ---
        date: \(isoDate)
        time: \(timeString)
        duration: "\(durationString)"
        transcription_engine: assemblyai
        word_count: \(result.metadata.wordCount)
        utterance_count: \(result.metadata.utteranceCount)
        speaker_count: \(result.metadata.speakerCount)
        confidence: \(String(format: "%.0f", (result.metadata.confidence ?? 0) * 100))%
        """

        if !result.sentimentResults.isEmpty {
            yaml += "\noverall_sentiment: \(overallSentiment)"
        }

        yaml += "\n---\n"

        // Build document
        var doc = yaml
        doc += "\n# Call Recording - \(dateString)\n\n"
        doc += "**Source:** \(source) • **Duration:** \(durationString) • **Words:** \(result.metadata.wordCount)\n\n"

        // Summary section
        doc += "## Summary\n\n"
        if let summary = result.summary, !summary.isEmpty {
            doc += "\(summary)\n\n"
        } else {
            doc += "*No summary generated*\n\n"
        }

        // Chapters section (unique to AssemblyAI)
        if !result.chapters.isEmpty {
            doc += "## Chapters\n\n"
            for (index, chapter) in result.chapters.enumerated() {
                let startTime = String(format: "%02d:%02d", chapter.start / 60000, (chapter.start / 1000) % 60)
                doc += "### \(index + 1). \(chapter.headline) [\(startTime)]\n\n"
                doc += "\(chapter.summary)\n\n"
            }
        }

        // Entities section
        if !result.entities.isEmpty {
            doc += "## Entities Detected\n\n"
            let groupedEntities = Dictionary(grouping: result.entities, by: { $0.entityType })
            for (entityType, entities) in groupedEntities.sorted(by: { $0.key < $1.key }) {
                let uniqueValues = Set(entities.map { $0.text })
                let displayType = entityType.replacingOccurrences(of: "_", with: " ").capitalized
                doc += "- **\(displayType):** \(uniqueValues.joined(separator: ", "))\n"
            }
            doc += "\n"
        }

        // Sentiment breakdown
        if !result.sentimentResults.isEmpty {
            doc += "## Sentiment Analysis\n\n"
            doc += "**Overall:** \(overallSentiment.capitalized)\n\n"

            // Count sentiment distribution
            let sentimentCounts = Dictionary(grouping: result.sentimentResults, by: { $0.sentiment })
            let total = result.sentimentResults.count
            doc += "| Sentiment | Count | Percentage |\n"
            doc += "|-----------|-------|------------|\n"
            for sentiment in ["POSITIVE", "NEUTRAL", "NEGATIVE"] {
                let count = sentimentCounts[sentiment]?.count ?? 0
                let pct = total > 0 ? Double(count) / Double(total) * 100 : 0
                doc += "| \(sentiment.capitalized) | \(count) | \(String(format: "%.1f", pct))% |\n"
            }
            doc += "\n"
        }

        // Speaker breakdown
        doc += "## Speakers\n\n"
        let speakerUtterances = Dictionary(grouping: result.utterances, by: { $0.speaker })
        for speaker in speakerUtterances.keys.sorted() {
            let utterances = speakerUtterances[speaker] ?? []
            let wordCount = utterances.reduce(0) { $0 + ($1.text.split(separator: " ").count) }
            let totalTime = utterances.reduce(0) { $0 + ($1.end - $1.start) } / 1000  // Convert ms to seconds
            doc += "- **Speaker \(speaker):** \(utterances.count) utterances, ~\(wordCount) words, \(totalTime)s speaking time\n"
        }
        doc += "\n"

        // Full transcript timeline
        doc += "---\n\n"
        doc += "## Transcript\n\n"

        for utterance in result.utterances {
            let startMinutes = utterance.start / 60000
            let startSeconds = (utterance.start / 1000) % 60
            let timestamp = String(format: "%02d:%02d", startMinutes, startSeconds)
            let confidence = String(format: "%.0f", utterance.confidence * 100)
            doc += "**[\(timestamp)]** `Speaker \(utterance.speaker)` (\(confidence)%)\n"
            doc += "\(utterance.text)\n\n"
        }

        // Word-level details section (collapsed by default in markdown viewers)
        doc += "---\n\n"
        doc += "<details>\n<summary>Word-level Details (\(result.words.count) words)</summary>\n\n"
        doc += "| Time | Word | Confidence | Speaker |\n"
        doc += "|------|------|------------|--------|\n"
        for word in result.words.prefix(100) {  // Limit to first 100 for file size
            let time = String(format: "%.2f", Double(word.start) / 1000.0)
            let conf = String(format: "%.0f%%", word.confidence * 100)
            let spk = word.speaker ?? "-"
            doc += "| \(time)s | \(word.text) | \(conf) | \(spk) |\n"
        }
        if result.words.count > 100 {
            doc += "\n*... and \(result.words.count - 100) more words*\n"
        }
        doc += "\n</details>\n\n"

        // Footer
        doc += "---\n\n"
        doc += "*Generated by Transcripted with AssemblyAI • Duration: \(durationString) • \(result.metadata.wordCount) words • \(result.metadata.speakerCount) speakers*\n"

        return doc
    }

    // MARK: - Rich Combined AssemblyAI Transcript (Mic + System Audio)

    /// Merged utterance for timeline display
    private struct MergedUtterance {
        let timestamp: Int           // milliseconds
        let source: String           // "Mic" or "System"
        let speaker: String          // "You" for mic, "Speaker A/B/C" for system
        let text: String
        let sentiment: String?       // "POSITIVE", "NEUTRAL", "NEGATIVE"
        let entities: [AssemblyAIEntity]
        let confidence: Double
    }

    /// Save rich AssemblyAI transcript with combined mic + system audio and inline annotations
    /// - Parameters:
    ///   - result: Combined result from mic and system audio transcription
    ///   - directory: Optional custom directory
    /// - Returns: URL of saved file, or nil if save failed
    @available(macOS 14.0, *)
    @discardableResult
    static func saveRichAssemblyAITranscript(_ result: CombinedAssemblyAIResult, directory: URL? = nil) -> URL? {
        // Call the new method with empty speaker mappings for backward compatibility
        return saveRichAssemblyAITranscript(result, speakerMappings: [:], directory: directory)
    }

    /// Save rich AssemblyAI transcript with speaker name mappings from Gemini identification
    /// - Parameters:
    ///   - result: Combined result from mic and system audio transcription
    ///   - speakerMappings: Mapping of speaker IDs to identified names from Gemini
    ///   - directory: Optional custom directory
    /// - Returns: URL of saved file, or nil if save failed
    @available(macOS 14.0, *)
    @discardableResult
    static func saveRichAssemblyAITranscript(
        _ result: CombinedAssemblyAIResult,
        speakerMappings: [String: SpeakerMapping],
        directory: URL? = nil
    ) -> URL? {
        let saveDir = directory ?? defaultSaveDirectory

        do {
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        } catch {
            print("❌ Failed to create save directory: \(error.localizedDescription)")
            return nil
        }

        let timestamp = formatTimestamp(Date())
        let filename = "Call_\(timestamp).md"
        let fileURL = saveDir.appendingPathComponent(filename)

        let markdown = formatRichAssemblyAIMarkdown(result: result, speakerMappings: speakerMappings, date: Date())

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✓ Rich AssemblyAI transcript saved to: \(fileURL.path)")
            showSaveNotification(fileURL: fileURL)
            return fileURL
        } catch {
            print("❌ Failed to save rich AssemblyAI transcript: \(error.localizedDescription)")
            return nil
        }
    }

    /// Format rich combined AssemblyAI transcript as markdown with inline annotations
    @available(macOS 14.0, *)
    private static func formatRichAssemblyAIMarkdown(
        result: CombinedAssemblyAIResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        date: Date
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

        // Aggregate data from both sources
        let micWordCount = result.micResult?.metadata.wordCount ?? 0
        let sysWordCount = result.systemResult?.metadata.wordCount ?? 0
        let totalWordCount = micWordCount + sysWordCount

        let micSpeakers = result.micResult?.metadata.speakerCount ?? 0
        let sysSpeakers = result.systemResult?.metadata.speakerCount ?? 0
        let totalSpeakers = micSpeakers + sysSpeakers

        // Determine overall sentiment from both sources
        var allSentiments: [AssemblyAISentimentResult] = []
        if let mic = result.micResult { allSentiments.append(contentsOf: mic.sentimentResults) }
        if let sys = result.systemResult { allSentiments.append(contentsOf: sys.sentimentResults) }

        let overallSentiment = determineOverallSentiment(allSentiments)

        // Merge entities from both sources
        var allEntities: [AssemblyAIEntity] = []
        if let mic = result.micResult { allEntities.append(contentsOf: mic.entities) }
        if let sys = result.systemResult { allEntities.append(contentsOf: sys.entities) }

        // Sources list
        var sources: [String] = []
        if result.micResult != nil { sources.append("mic") }
        if result.systemResult != nil { sources.append("system_audio") }

        // Build YAML frontmatter
        var yaml = """
        ---
        date: \(isoDate)
        time: \(timeString)
        duration: "\(durationString)"
        processing_time: "\(String(format: "%.1f", result.processingTime))s"
        transcription_engine: assemblyai
        sources: [\(sources.joined(separator: ", "))]
        total_speakers: \(totalSpeakers)
        total_word_count: \(totalWordCount)
        overall_sentiment: \(overallSentiment)
        entity_count: \(allEntities.count)
        """

        yaml += "\n---\n"

        // Build document
        var doc = yaml
        doc += "\n# Meeting Recording - \(dateString)\n\n"
        doc += "**Duration:** \(durationString) | **Words:** \(totalWordCount) | **Speakers:** \(totalSpeakers)\n\n"
        doc += "---\n\n"

        // SECTION 1: Summary (placeholder - will be replaced by Gemini-generated summary if available)
        doc += "## Summary\n\n"
        doc += "### Meeting Summary\n\n"

        // Use AssemblyAI summary as initial placeholder (will be replaced by Gemini later)
        if let micSummary = result.micResult?.summary, !micSummary.isEmpty {
            doc += "\(micSummary)\n\n"
        } else if let sysSummary = result.systemResult?.summary, !sysSummary.isEmpty {
            doc += "\(sysSummary)\n\n"
        } else {
            doc += "*Generating summary...*\n\n"
        }

        // SECTION 2: Chapters (primarily from system audio)
        let allChapters = (result.systemResult?.chapters ?? []) + (result.micResult?.chapters ?? [])
        if !allChapters.isEmpty {
            doc += "---\n\n"
            doc += "## Chapters\n\n"
            for (index, chapter) in allChapters.enumerated() {
                let startTime = String(format: "%02d:%02d", chapter.start / 60000, (chapter.start / 1000) % 60)
                doc += "### \(index + 1). \(chapter.headline) [\(startTime)]\n\n"
                doc += "\(chapter.summary)\n\n"
            }
        }

        // SECTION 3: Entities (merged from both sources)
        if !allEntities.isEmpty {
            doc += "---\n\n"
            doc += "## Entities Detected\n\n"
            let groupedEntities = Dictionary(grouping: allEntities, by: { $0.entityType })
            for (entityType, entities) in groupedEntities.sorted(by: { $0.key < $1.key }) {
                let uniqueValues = Array(Set(entities.map { $0.text })).sorted()
                let displayType = entityType.replacingOccurrences(of: "_", with: " ").capitalized
                doc += "- **\(displayType):** \(uniqueValues.joined(separator: ", "))\n"
            }
            doc += "\n"
        }

        // SECTION 4: Sentiment Analysis
        if !allSentiments.isEmpty {
            doc += "---\n\n"
            doc += "## Sentiment Analysis\n\n"
            doc += "**Overall Tone:** \(overallSentiment.capitalized)\n\n"

            // Sentiment by source
            doc += "| Source | Positive | Neutral | Negative |\n"
            doc += "|--------|----------|---------|----------|\n"

            if let mic = result.micResult, !mic.sentimentResults.isEmpty {
                let (pos, neu, neg) = calculateSentimentPercentages(mic.sentimentResults)
                doc += "| Microphone | \(pos)% | \(neu)% | \(neg)% |\n"
            }

            if let sys = result.systemResult, !sys.sentimentResults.isEmpty {
                let (pos, neu, neg) = calculateSentimentPercentages(sys.sentimentResults)
                doc += "| Meeting | \(pos)% | \(neu)% | \(neg)% |\n"
            }

            doc += "\n"
        }

        // SECTION 5: Speaker Analytics
        doc += "---\n\n"
        doc += "## Speaker Analytics\n\n"

        // Collect all unique speaker IDs from both sources
        var allSpeakerIds = Set<String>()
        if let mic = result.micResult {
            for utterance in mic.utterances {
                allSpeakerIds.insert(utterance.speaker)
            }
        }
        if let sys = result.systemResult {
            for utterance in sys.utterances {
                allSpeakerIds.insert(utterance.speaker)
            }
        }

        // Build speaker stats using speaker mappings for display names
        for speakerId in allSpeakerIds.sorted() {
            var totalUtterances = 0
            var totalWords = 0
            var totalTimeMs = 0

            // Count from mic
            if let mic = result.micResult {
                let micUtterances = mic.utterances.filter { $0.speaker == speakerId }
                totalUtterances += micUtterances.count
                totalWords += micUtterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
                totalTimeMs += micUtterances.reduce(0) { $0 + ($1.end - $1.start) }
            }

            // Count from system
            if let sys = result.systemResult {
                let sysUtterances = sys.utterances.filter { $0.speaker == speakerId }
                totalUtterances += sysUtterances.count
                totalWords += sysUtterances.reduce(0) { $0 + $1.text.split(separator: " ").count }
                totalTimeMs += sysUtterances.reduce(0) { $0 + ($1.end - $1.start) }
            }

            if totalUtterances > 0 {
                let speakerName = speakerMappings[speakerId]?.displayName ?? "Speaker \(speakerId)"
                let timeStr = formatTimeInterval(Double(totalTimeMs) / 1000.0)
                doc += "- **\(speakerName):** \(totalUtterances) utterances, ~\(totalWords) words, \(timeStr) speaking\n"
            }
        }

        doc += "\n"

        // SECTION 6: Full Transcript with Inline Annotations
        doc += "---\n\n"
        doc += "## Full Transcript\n\n"

        let mergedTimeline = mergeTimelines(micResult: result.micResult, systemResult: result.systemResult, speakerMappings: speakerMappings)

        for utterance in mergedTimeline {
            let startMinutes = utterance.timestamp / 60000
            let startSeconds = (utterance.timestamp / 1000) % 60
            let timestampStr = String(format: "%02d:%02d", startMinutes, startSeconds)

            // Sentiment emoji
            let emoji = sentimentEmoji(for: utterance.sentiment)

            // Entity markers
            let entityMarkers = inlineEntityMarkers(for: utterance.entities)

            // Format: [00:00] [Source/Speaker] :emoji: Text `[ENTITY: value]`
            var line = "[\(timestampStr)] [\(utterance.source)/\(utterance.speaker)] \(emoji) \(utterance.text)"

            if !entityMarkers.isEmpty {
                line += " \(entityMarkers)"
            }

            doc += "\(line)\n\n"
        }

        // SECTION 7: Word-level Details (collapsible)
        var allWords: [(word: AssemblyAIWord, source: String)] = []
        if let mic = result.micResult {
            for word in mic.words { allWords.append((word, "Mic")) }
        }
        if let sys = result.systemResult {
            for word in sys.words { allWords.append((word, "System")) }
        }

        // Sort by timestamp
        allWords.sort { $0.word.start < $1.word.start }

        if !allWords.isEmpty {
            doc += "---\n\n"
            doc += "<details>\n<summary>Word-level Details (\(allWords.count) words)</summary>\n\n"
            doc += "| Time | Word | Confidence | Speaker | Source |\n"
            doc += "|------|------|------------|---------|--------|\n"

            for (word, source) in allWords.prefix(150) {
                let time = String(format: "%.2f", Double(word.start) / 1000.0)
                let conf = String(format: "%.0f%%", word.confidence * 100)
                let spk = word.speaker ?? "-"
                doc += "| \(time)s | \(word.text) | \(conf) | \(spk) | \(source) |\n"
            }

            if allWords.count > 150 {
                doc += "\n*... and \(allWords.count - 150) more words*\n"
            }

            doc += "\n</details>\n\n"
        }

        // Footer
        doc += "---\n\n"
        doc += "*Generated by Transcripted with AssemblyAI • Duration: \(durationString) • \(totalWordCount) words • \(totalSpeakers) speakers*\n"

        return doc
    }

    // MARK: - Helper Functions for Rich Transcript

    /// Determine overall sentiment from results
    private static func determineOverallSentiment(_ results: [AssemblyAISentimentResult]) -> String {
        guard !results.isEmpty else { return "neutral" }

        let sentimentCounts = Dictionary(grouping: results, by: { $0.sentiment })
        let positiveCount = sentimentCounts["POSITIVE"]?.count ?? 0
        let negativeCount = sentimentCounts["NEGATIVE"]?.count ?? 0

        if positiveCount > negativeCount {
            return "positive"
        } else if negativeCount > positiveCount {
            return "negative"
        }
        return "neutral"
    }

    /// Calculate sentiment percentages
    private static func calculateSentimentPercentages(_ results: [AssemblyAISentimentResult]) -> (positive: Int, neutral: Int, negative: Int) {
        let total = results.count
        guard total > 0 else { return (0, 0, 0) }

        let sentimentCounts = Dictionary(grouping: results, by: { $0.sentiment })
        let pos = Int(Double(sentimentCounts["POSITIVE"]?.count ?? 0) / Double(total) * 100)
        let neg = Int(Double(sentimentCounts["NEGATIVE"]?.count ?? 0) / Double(total) * 100)
        let neu = 100 - pos - neg

        return (pos, neu, neg)
    }

    /// Get sentiment emoji for display
    private static func sentimentEmoji(for sentiment: String?) -> String {
        switch sentiment?.uppercased() {
        case "POSITIVE": return "😊"
        case "NEGATIVE": return "😟"
        case "NEUTRAL": return "😐"
        default: return ""
        }
    }

    /// Get inline entity markers for display
    private static func inlineEntityMarkers(for entities: [AssemblyAIEntity]) -> String {
        guard !entities.isEmpty else { return "" }

        let markers = entities.map { entity in
            let abbrev = abbreviateEntityType(entity.entityType)
            return "`[\(abbrev): \(entity.text)]`"
        }

        return markers.joined(separator: " ")
    }

    /// Abbreviate entity type for inline display
    private static func abbreviateEntityType(_ type: String) -> String {
        switch type.lowercased() {
        case "person_name": return "PER"
        case "location": return "LOC"
        case "organization": return "ORG"
        case "date": return "DATE"
        case "phone_number": return "PHONE"
        case "email_address": return "EMAIL"
        case "money_amount": return "MONEY"
        case "occupation": return "JOB"
        case "event": return "EVENT"
        case "language": return "LANG"
        case "nationality": return "NAT"
        case "political_affiliation": return "POL"
        case "religion": return "REL"
        case "blood_type": return "BLOOD"
        case "drug": return "DRUG"
        case "injury": return "INJ"
        case "medical_process": return "MED"
        case "medical_condition": return "COND"
        default: return type.uppercased().prefix(4).description
        }
    }

    /// Merge mic and system audio timelines into a single sorted list
    /// Uses speaker mappings to display identified names instead of generic "Speaker A/B/C"
    private static func mergeTimelines(
        micResult: AssemblyAITranscriptionResult?,
        systemResult: AssemblyAITranscriptionResult?,
        speakerMappings: [String: SpeakerMapping] = [:]
    ) -> [MergedUtterance] {
        var merged: [MergedUtterance] = []

        // Add mic utterances - use AssemblyAI's speaker diarization
        if let mic = micResult {
            for utterance in mic.utterances {
                let sentiment = findSentiment(at: utterance.start, in: mic.sentimentResults)
                let entities = findEntities(from: utterance.start, to: utterance.end, in: mic.entities)

                // Use speaker mapping if available, otherwise use AssemblyAI's speaker label
                let speakerId = utterance.speaker
                let speakerName = speakerMappings[speakerId]?.displayName ?? "Speaker \(speakerId)"

                merged.append(MergedUtterance(
                    timestamp: utterance.start,
                    source: "Mic",
                    speaker: speakerName,
                    text: utterance.text,
                    sentiment: sentiment,
                    entities: entities,
                    confidence: utterance.confidence
                ))
            }
        }

        // Add system utterances - use AssemblyAI's speaker diarization
        if let sys = systemResult {
            for utterance in sys.utterances {
                let sentiment = findSentiment(at: utterance.start, in: sys.sentimentResults)
                let entities = findEntities(from: utterance.start, to: utterance.end, in: sys.entities)

                // Use speaker mapping if available, otherwise use AssemblyAI's speaker label
                let speakerId = utterance.speaker
                let speakerName = speakerMappings[speakerId]?.displayName ?? "Speaker \(speakerId)"

                merged.append(MergedUtterance(
                    timestamp: utterance.start,
                    source: "System",
                    speaker: speakerName,
                    text: utterance.text,
                    sentiment: sentiment,
                    entities: entities,
                    confidence: utterance.confidence
                ))
            }
        }

        // Sort by timestamp
        return merged.sorted { $0.timestamp < $1.timestamp }
    }

    /// Find sentiment for a given timestamp
    private static func findSentiment(at timestamp: Int, in results: [AssemblyAISentimentResult]) -> String? {
        for result in results {
            if timestamp >= result.start && timestamp <= result.end {
                return result.sentiment
            }
        }
        return nil
    }

    /// Find entities that overlap with a time range
    private static func findEntities(from start: Int, to end: Int, in entities: [AssemblyAIEntity]) -> [AssemblyAIEntity] {
        return entities.filter { entity in
            entity.start >= start && entity.start <= end
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
