import Foundation

/// Scans existing transcript files and migrates them to the stats database
/// Used for initial migration when user first updates to version with dashboard
@available(macOS 14.0, *)
final class TranscriptScanner {

    /// Scan transcript folder and migrate to database
    /// - Parameters:
    ///   - directory: Directory to scan (defaults to Transcripted folder)
    ///   - progressHandler: Called with progress updates (0.0 to 1.0)
    /// - Returns: Number of transcripts migrated
    @discardableResult
    static func migrateExistingTranscripts(
        from directory: URL? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async -> Int {
        let transcriptDir = directory ?? TranscriptSaver.defaultSaveDirectory

        guard FileManager.default.fileExists(atPath: transcriptDir.path) else {
            print("⚠️ TranscriptScanner: Directory does not exist: \(transcriptDir.path)")
            return 0
        }

        // Find all markdown files
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: transcriptDir,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            print("❌ TranscriptScanner: Failed to create enumerator")
            return 0
        }

        var markdownFiles: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.pathExtension == "md" {
                markdownFiles.append(fileURL)
            }
        }

        guard !markdownFiles.isEmpty else {
            print("ℹ️ TranscriptScanner: No markdown files found")
            return 0
        }

        print("ℹ️ TranscriptScanner: Found \(markdownFiles.count) transcript files to scan")
        progressHandler?(0.0, "Found \(markdownFiles.count) transcripts...")

        let database = StatsDatabase.shared
        var migrated = 0

        for (index, fileURL) in markdownFiles.enumerated() {
            // Check if already migrated
            if database.recordingExists(transcriptPath: fileURL.path) {
                continue
            }

            // Parse the transcript
            if let (metadata, actionItemsCount) = parseTranscriptFile(fileURL) {
                database.recordSession(metadata)

                // Record action items if present in YAML
                if actionItemsCount > 0 {
                    let records = (0..<actionItemsCount).map { _ in
                        ActionItemRecord(
                            task: "Migrated action item",
                            owner: nil,
                            priority: nil,
                            dueDate: nil,
                            destination: "migrated"
                        )
                    }
                    database.recordActionItems(records, for: fileURL.path)
                }

                migrated += 1
            }

            // Update progress
            let progress = Double(index + 1) / Double(markdownFiles.count)
            let fileName = fileURL.lastPathComponent
            progressHandler?(progress, "Scanning: \(fileName)")

            // Small delay to prevent UI blocking
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }

        print("✓ TranscriptScanner: Migrated \(migrated) transcripts")
        progressHandler?(1.0, "Complete! Migrated \(migrated) transcripts.")

        return migrated
    }

    /// Parse a transcript file and extract metadata
    /// Returns tuple of (metadata, actionItemsCount) or nil if parsing failed
    private static func parseTranscriptFile(_ fileURL: URL) -> (RecordingMetadata, Int)? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            print("⚠️ TranscriptScanner: Could not read file: \(fileURL.lastPathComponent)")
            return nil
        }

        // Extract YAML frontmatter if present
        var date = Date()
        var durationSeconds = 0
        var wordCount = 0
        var speakerCount = 0
        var processingTimeMs = 0
        var title: String?
        var actionItemsCount = 0

        // Check for YAML frontmatter
        if content.hasPrefix("---") {
            if let endIndex = content.range(of: "---", range: content.index(content.startIndex, offsetBy: 3)..<content.endIndex) {
                let yaml = String(content[content.index(content.startIndex, offsetBy: 3)..<endIndex.lowerBound])

                // Parse YAML fields
                let lines = yaml.components(separatedBy: .newlines)
                for line in lines {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2 else { continue }

                    let key = String(parts[0]).trimmingCharacters(in: .whitespaces)
                    let value = String(parts[1]).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")

                    switch key {
                    case "date":
                        let dateFormatter = DateFormatter()
                        dateFormatter.dateFormat = "yyyy-MM-dd"
                        if let parsedDate = dateFormatter.date(from: value) {
                            date = parsedDate
                        }

                    case "time":
                        // Combine with existing date
                        let timeFormatter = DateFormatter()
                        timeFormatter.dateFormat = "HH:mm:ss"
                        if let time = timeFormatter.date(from: value) {
                            let calendar = Calendar.current
                            let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: time)
                            date = calendar.date(bySettingHour: timeComponents.hour ?? 0,
                                                minute: timeComponents.minute ?? 0,
                                                second: timeComponents.second ?? 0,
                                                of: date) ?? date
                        }

                    case "duration":
                        // Parse "MM:SS" format
                        let durationParts = value.split(separator: ":")
                        if durationParts.count == 2 {
                            let minutes = Int(durationParts[0]) ?? 0
                            let seconds = Int(durationParts[1]) ?? 0
                            durationSeconds = minutes * 60 + seconds
                        }

                    case "total_word_count":
                        wordCount = Int(value) ?? 0

                    case "mic_speakers", "system_speakers":
                        speakerCount += Int(value) ?? 0

                    case "processing_time":
                        // Parse "X.Xs" format
                        let numStr = value.replacingOccurrences(of: "s", with: "")
                        if let seconds = Double(numStr) {
                            processingTimeMs = Int(seconds * 1000)
                        }

                    case "action_items":
                        actionItemsCount = Int(value) ?? 0

                    default:
                        break
                    }
                }
            }
        }

        // Fallback: if no duration found, estimate from file creation date
        if durationSeconds == 0 {
            // Try to get file creation date
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let creationDate = attrs[.creationDate] as? Date {
                date = creationDate
            }

            // Estimate duration from word count (average 150 words per minute)
            if wordCount == 0 {
                wordCount = content.split(separator: " ").count
            }
            durationSeconds = max(60, wordCount / 2) // Rough estimate
        }

        // Extract title from filename or content
        title = extractTitle(from: fileURL, content: content)

        let metadata = RecordingMetadata(
            date: date,
            durationSeconds: durationSeconds,
            wordCount: wordCount,
            speakerCount: speakerCount,
            processingTimeMs: processingTimeMs,
            transcriptPath: fileURL.path,
            title: title
        )

        return (metadata, actionItemsCount)
    }

    /// Extract a title from the filename or content
    private static func extractTitle(from fileURL: URL, content: String) -> String? {
        let filename = fileURL.deletingPathExtension().lastPathComponent

        // If filename starts with "Call_", try to extract date and look for better title
        if filename.hasPrefix("Call_") {
            // Look for title in markdown heading
            let lines = content.components(separatedBy: .newlines)
            for line in lines {
                if line.hasPrefix("# ") && !line.contains("Recording") && !line.contains("Call") {
                    return String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                }
            }
            return nil // Use default display title
        }

        // Clean up filename
        let cleaned = filename
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")

        return cleaned
    }

    /// Check if migration is needed
    static func needsMigration() -> Bool {
        let database = StatsDatabase.shared
        let dbCount = database.getTotalRecordingsCount()

        // If database has no records, check if there are transcript files
        if dbCount == 0 {
            let transcriptDir = TranscriptSaver.defaultSaveDirectory
            guard FileManager.default.fileExists(atPath: transcriptDir.path) else {
                return false
            }

            let fileManager = FileManager.default
            if let contents = try? fileManager.contentsOfDirectory(at: transcriptDir, includingPropertiesForKeys: nil) {
                return contents.contains { $0.pathExtension == "md" }
            }
        }

        return false
    }
}
