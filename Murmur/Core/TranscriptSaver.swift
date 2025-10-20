import Foundation
import AppKit

/// Handles automatic saving of transcripts to the filesystem
class TranscriptSaver {

    /// Default save location: ~/Documents/Murmur Transcripts/
    /// Reads custom location from UserDefaults if set
    static var defaultSaveDirectory: URL {
        // Check for custom save location first
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            return URL(fileURLWithPath: customPath)
        }

        // Fall back to default location
        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return documentsPath.appendingPathComponent("Murmur Transcripts")
    }

    /// Save transcript to file with automatic timestamped naming
    /// - Parameters:
    ///   - text: The transcript text to save
    ///   - duration: Recording duration in seconds
    ///   - directory: Optional custom directory (defaults to ~/Documents/Murmur Transcripts/)
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

    /// Save timestamped transcript segments in timeline format
    /// - Parameters:
    ///   - segments: Array of timestamped transcript segments
    ///   - duration: Recording duration in seconds
    ///   - processingTime: Time taken to process transcript (in seconds)
    ///   - directory: Optional custom directory (defaults to ~/Documents/Murmur Transcripts/)
    /// - Returns: URL of saved file, or nil if save failed
    @discardableResult
    static func save(segments: [TimestampedSegment], duration: TimeInterval, processingTime: TimeInterval, directory: URL? = nil) -> URL? {
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

        let markdown = formatMarkdownWithTimestamps(segments: segments, duration: duration, processingTime: processingTime, date: Date())

        do {
            try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
            print("✓ Transcript saved to: \(fileURL.path)")
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

        *Recorded with Murmur*
        """
    }

    /// Format transcript with timeline (inline style)
    private static func formatMarkdownWithTimestamps(segments: [TimestampedSegment], duration: TimeInterval, processingTime: TimeInterval, date: Date) -> String {
        let dateFormatter = DateFormatter()
        dateFormatter.dateStyle = .medium
        dateFormatter.timeStyle = .short
        let dateString = dateFormatter.string(from: date)

        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        let durationString = String(format: "%d:%02d", minutes, seconds)

        let totalWords = segments.reduce(0) { $0 + $1.text.split(separator: " ").count }

        // Extract unique speakers for YAML
        let speakers = Set(segments.map { $0.source.lowercased().replacingOccurrences(of: " ", with: "_") })
        let speakerList = speakers.sorted().map { "  - \($0)" }.joined(separator: "\n")

        // Format timestamp for YAML and metadata
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm:ss"
        let timeString = timeFormatter.string(from: date)

        let isoFormatter = DateFormatter()
        isoFormatter.dateFormat = "yyyy-MM-dd"
        let isoDate = isoFormatter.string(from: date)

        // Build timeline entries with new format: [00:00] [Mic] Text
        var timelineLines: [String] = []
        for segment in segments {
            let timestamp = formatTimeInterval(segment.timestamp)
            // Map source to shorter labels
            let sourceLabel = segment.source == "System Audio" ? "SysAudio" : segment.source
            let line = "[\(timestamp)] [\(sourceLabel)] \(segment.text)"
            timelineLines.append(line)
        }

        let timeline = timelineLines.isEmpty ? "*No transcript available*" : timelineLines.joined(separator: "\n")

        // Format processing time with 1 decimal place
        let processingTimeString = String(format: "%.1fs", processingTime)

        return """
        ---
        date: \(isoDate)
        time: \(timeString)
        duration: "\(durationString)"
        processing_time: "\(processingTimeString)"
        word_count: \(totalWords)
        ---

        # Call Recording - \(dateString)

        ## Summary
        [Summary will be generated here - placeholder for future LLM integration]

        ---

        \(timeline)

        ---

        *Generated by Murmur • Duration: \(durationString) • \(totalWords) words*
        """
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
