import Foundation

/// Handles automatic saving of transcripts to the filesystem
public class TranscriptSaver {

    /// Default save location for the standalone Transcripted app.
    /// Falls back to `CoreStoragePaths.default.transcripts` unless the user has set a
    /// custom location in UserDefaults (the Settings window offers this knob).
    /// Security: validates the custom path against directory traversal and forbidden system
    /// directories before use. Falls back to the default location if validation fails, so
    /// a tampered UserDefaults value cannot redirect transcripts to an arbitrary path.
    ///
    /// Embedders (e.g. the Draft app) should NOT rely on this property — instead pass an
    /// explicit `directory:` argument to `saveTranscript(...)` so their own storage layout
    /// is honoured.
    public static var defaultSaveDirectory: URL {
        let fallback = CoreStoragePaths.default.transcripts

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
    ///   - notifier: Optional notifier; invoked on the main actor after a successful save.
    /// - Returns: URL of saved file, or nil if save failed
    @discardableResult
    public static func save(
        text: String,
        duration: TimeInterval,
        directory: URL? = nil,
        notifier: TranscriptNotifier? = nil
    ) -> URL? {
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
            FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
            AppLogger.pipeline.info("Transcript saved", ["path": fileURL.path])

            // Notify the embedder so they can present a user-facing alert
            if let notifier {
                let savedURL = fileURL
                Task { @MainActor in
                    notifier.notifyTranscriptSaved(fileURL: savedURL)
                }
            }

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
    public static func saveTranscript(
        _ result: TranscriptionResult,
        speakerMappings: [String: SpeakerMapping] = [:],
        speakerSources: [String: String] = [:],
        speakerDbIds: [String: UUID] = [:],
        directory: URL? = nil,
        meetingTitle: String? = nil,
        healthInfo: RecordingHealthInfo? = nil,
        notifier: TranscriptNotifier? = nil,
        speakerStoreForIndex: (any SpeakerStore)? = nil
    ) -> URL? {
        let saveDir = directory ?? defaultSaveDirectory

        do {
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.pipeline.error("Failed to create save directory", ["error": error.localizedDescription])
            return nil
        }

        // Check disk space before writing (prevent partial save where .md succeeds but .json fails)
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: saveDir.path),
           let freeSpace = attrs[.systemFreeSize] as? Int64,
           freeSpace < 50_000_000 { // 50MB minimum
            AppLogger.pipeline.error("Insufficient disk space for transcript save", ["freeSpace": "\(freeSpace / 1_000_000)MB"])
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

        // Serialize file writes to prevent concurrent corruption with retroactive speaker updates
        let savedURL: URL? = fileUpdateQueue.sync {
            do {
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
                FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
                AppLogger.pipeline.info("Transcript saved", ["path": fileURL.path])

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
                    try AgentOutput.writeIndex(
                        to: saveDir,
                        speakerStore: speakerStoreForIndex ?? SpeakerDatabase.shared
                    )
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

        if let savedURL {
            if let notifier {
                Task { @MainActor in
                    notifier.notifyTranscriptSaved(fileURL: savedURL)
                }
            }

            // Record to stats database (outside queue — dispatches to MainActor)
            Task { @MainActor in
                let metadata = StatsService.createMetadata(
                    from: result,
                    transcriptPath: savedURL.path,
                    title: meetingTitle
                )
                await StatsService.shared.recordSession(metadata)
            }
        }

        return savedURL
    }
}

// MARK: - TranscriptStorage conformance
// Empty extension — protocol signatures match TranscriptSaver's static API exactly.
// updateSpeakerNames and retroactivelyUpdateSpeaker live in RetroactiveSpeakerUpdater.swift
// as static methods on TranscriptSaver. Added as part of Step 8 protocol wiring (merge-plan §5.1).

@available(macOS 14.0, *)
extension TranscriptSaver: TranscriptStorage {}
