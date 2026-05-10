import Foundation

/// Scans existing transcript files and migrates them to the stats database
/// Used for initial migration when user first updates to version with dashboard
@available(macOS 14.0, *)
public enum TranscriptScanner {
    private static let cooperativeYieldNanoseconds: UInt64 = 10_000_000

    /// Scan transcript folder and migrate to database
    /// - Parameters:
    ///   - directory: Directory to scan (defaults to Transcripted folder)
    ///   - progressHandler: Called with progress updates (0.0 to 1.0)
    /// - Returns: Number of transcripts migrated
    @discardableResult
    public static func migrateExistingTranscripts(
        from directory: URL? = nil,
        progressHandler: ((Double, String) -> Void)? = nil
    ) async -> Int {
        let transcriptDir = directory ?? TranscriptSaver.defaultSaveDirectory

        guard FileManager.default.fileExists(atPath: transcriptDir.path) else {
            AppLogger.pipeline.warning("TranscriptScanner directory does not exist", ["path": transcriptDir.path])
            return 0
        }

        // Find all markdown files
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: transcriptDir,
            includingPropertiesForKeys: [.isRegularFileKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            AppLogger.pipeline.error("TranscriptScanner failed to create enumerator")
            return 0
        }

        var markdownFiles: [URL] = []
        while let fileURL = enumerator.nextObject() as? URL {
            if fileURL.pathExtension == "md" {
                markdownFiles.append(fileURL)
            }
        }

        guard !markdownFiles.isEmpty else {
            AppLogger.pipeline.debug("TranscriptScanner: No markdown files found")
            return 0
        }

        AppLogger.pipeline.info("TranscriptScanner found files to scan", ["count": "\(markdownFiles.count)"])
        progressHandler?(0.0, "Found \(markdownFiles.count) transcripts...")

        let database = StatsDatabase.shared
        var migrated = 0

        for (index, fileURL) in markdownFiles.enumerated() {
            // Parse the transcript
            if let (metadata, _) = parseTranscriptFile(fileURL) {
                if database.recordingExists(id: metadata.id) || database.recordingExists(transcriptPath: fileURL.path) {
                    continue
                }
                database.recordSession(metadata)
                migrated += 1
            }

            // Update progress
            let progress = Double(index + 1) / Double(markdownFiles.count)
            let fileName = fileURL.lastPathComponent
            progressHandler?(progress, "Scanning: \(fileName)")

            // Small delay to prevent UI blocking
            try? await Task.sleep(nanoseconds: Self.cooperativeYieldNanoseconds)
        }

        AppLogger.pipeline.info("TranscriptScanner migration complete", ["migrated": "\(migrated)"])
        progressHandler?(1.0, "Complete! Migrated \(migrated) transcripts.")

        return migrated
    }

    /// Parse a transcript file and extract metadata
    /// Returns tuple of (metadata, actionItemsCount) or nil if parsing failed
    private static func parseTranscriptFile(_ fileURL: URL) -> (RecordingMetadata, Int)? {
        guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
            AppLogger.pipeline.warning("TranscriptScanner could not read file", ["file": fileURL.lastPathComponent])
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
        var captureID: String?

        if let values = TranscriptFrontmatter.values(in: content) {
            if let parsedDate = TranscriptFrontmatter.date(values: values) {
                date = parsedDate
            }

            if let timeValue = values["time"] {
                let timeFormatter = DateFormatter()
                timeFormatter.dateFormat = "HH:mm:ss"
                if let time = timeFormatter.date(from: timeValue) {
                    let calendar = Calendar.current
                    let timeComponents = calendar.dateComponents([.hour, .minute, .second], from: time)
                    date = calendar.date(
                        bySettingHour: timeComponents.hour ?? 0,
                        minute: timeComponents.minute ?? 0,
                        second: timeComponents.second ?? 0,
                        of: date
                    ) ?? date
                }
            }

            if let duration = TranscriptFrontmatter.durationSeconds(from: values["duration"]) {
                durationSeconds = duration
            }

            wordCount = Int(values["total_word_count"] ?? "") ?? wordCount
            speakerCount = (Int(values["mic_speakers"] ?? "") ?? 0)
                + (Int(values["system_speakers"] ?? "") ?? 0)

            if let processingTime = values["processing_time"] {
                let numStr = processingTime.replacingOccurrences(of: "s", with: "")
                if let seconds = Double(numStr) {
                    processingTimeMs = Int(seconds * 1000)
                }
            }

            actionItemsCount = Int(values["action_items"] ?? "") ?? actionItemsCount

            if let rawCaptureID = values["transcript_id"] ?? values["capture_id"] {
                // Security: cap length to prevent unbounded strings from an adversarially
                // crafted transcript file from being stored in the stats database.
                // A legitimate UUID is 36 chars; 256 gives generous slack for any future formats.
                if rawCaptureID.count > 256 {
                    AppLogger.pipeline.warning("TranscriptScanner: oversized capture_id truncated", [
                        "path": fileURL.lastPathComponent,
                        "length": "\(rawCaptureID.count)"
                    ])
                }
                captureID = String(rawCaptureID.prefix(256))
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
        // Security: cap at 1024 chars to bound what reaches the stats database from on-disk files.
        title = extractTitle(from: fileURL, content: content).map { String($0.prefix(1024)) }

        let metadata = RecordingMetadata(
            id: captureID ?? UUID().uuidString,
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
    public static func needsMigration() -> Bool {
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
