import Foundation
import AppKit
import UserNotifications

/// Handles automatic saving of transcripts to the filesystem
class TranscriptSaver {

    /// Default save location: ~/Documents/Transcripted/
    /// Reads custom location from UserDefaults if set.
    /// Security: validates the custom path against directory traversal and forbidden system
    /// directories before use. Falls back to the default location if validation fails, so
    /// a tampered UserDefaults value cannot redirect transcripts to an arbitrary path.
    static var defaultSaveDirectory: URL {
        let fallback: URL = {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documentsPath.appendingPathComponent("Transcripted")
        }()

        // Check for custom save location first
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            let candidateURL = URL(fileURLWithPath: customPath)
            let validation = RecordingValidator.validateSavePath(candidateURL)
            guard validation.isValid else {
                AppLogger.pipeline.warning("Custom save path rejected in defaultSaveDirectory, using default", [
                    "path": customPath,
                    "reason": validation.errorMessage ?? "unknown"
                ])
                return fallback
            }
            return candidateURL
        }

        return fallback
    }

    /// Serial queue for file updates — prevents concurrent reads/writes from corrupting transcripts
    static let fileUpdateQueue = DispatchQueue(label: "com.transcripted.fileupdate", qos: .utility)

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

    // MARK: - Local Transcript Saving (Parakeet + PyAnnote)

    /// Save transcript from local Parakeet + PyAnnote diarization pipeline
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

        let markdown = formatTranscriptMarkdown(result: result, speakerMappings: speakerMappings, speakerSources: speakerSources, speakerDbIds: speakerDbIds, date: Date(), meetingTitle: meetingTitle, healthInfo: healthInfo)

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

            // Agent output: write JSON sidecar + index + CLAUDE.md
            let stem = fileURL.deletingPathExtension().lastPathComponent
            do {
                try AgentOutput.writeTranscriptJSON(
                    from: result,
                    speakerMappings: speakerMappings,
                    speakerDbIds: speakerDbIds,
                    to: saveDir,
                    stem: stem
                )
                try AgentOutput.writeIndex(to: saveDir, speakerDB: SpeakerDatabase.shared)
                AgentOutput.writeAgentReadme(to: saveDir)
            } catch {
                AppLogger.pipeline.error("Agent output failed", ["error": error.localizedDescription])
                // Non-fatal — Markdown already saved successfully
            }

            return fileURL
        } catch {
            AppLogger.pipeline.error("Failed to save transcript", ["error": error.localizedDescription])
            return nil
        }
    }

    // MARK: - Notifications

    /// Notification category identifier for "Show in Finder" action
    static let notificationCategoryId = "TRANSCRIPT_SAVED"
    static let showInFinderActionId = "SHOW_IN_FINDER"

    /// Show macOS notification that transcript was saved.
    /// Guards on authorization status to avoid UNErrorDomain error 1.
    static func showSaveNotification(fileURL: URL) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.pipeline.debug("Skipping save notification — not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Transcript Saved"
            content.body = fileURL.lastPathComponent
            content.categoryIdentifier = notificationCategoryId
            content.userInfo = ["fileURL": fileURL.path]

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil // deliver immediately
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    AppLogger.pipeline.error("Failed to deliver notification", ["error": error.localizedDescription])
                }
            }
        }
    }
}
