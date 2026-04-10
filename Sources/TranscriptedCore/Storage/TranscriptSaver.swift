import Foundation

/// Handles automatic saving of transcripts to the filesystem
public class TranscriptSaver {
    private static let minimumFreeSpaceForTranscriptSave: Int64 = 50_000_000

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
        let saveDir = directory ?? defaultSaveDirectory
        do {
            try ensureSaveDirectoryExists(saveDir)
        } catch {
            AppLogger.pipeline.error("Failed to create save directory", ["error": error.localizedDescription])
            return nil
        }

        let fileURL = nextTranscriptFileURL(in: saveDir)
        let markdown = formatMarkdown(text: text, duration: duration, date: Date())

        do {
            try writeMarkdown(markdown, to: fileURL)
            notifySavedTranscript(fileURL, notifier: notifier)
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
        speakerStoreForIndex: (any SpeakerStore)? = nil,
        statsStore: (any StatsStore)? = nil
    ) -> URL? {
        let saveDir = directory ?? defaultSaveDirectory

        do {
            try ensureSaveDirectoryExists(saveDir)
        } catch {
            AppLogger.pipeline.error("Failed to create save directory", ["error": error.localizedDescription])
            return nil
        }

        guard hasMinimumFreeSpace(in: saveDir) else {
            return nil
        }

        let fileURL = nextTranscriptFileURL(in: saveDir)
        let markdown = formatTranscriptMarkdown(result: result, speakerMappings: speakerMappings, speakerSources: speakerSources, speakerDbIds: speakerDbIds, date: Date(), meetingTitle: meetingTitle, healthInfo: healthInfo)

        // Serialize file writes to prevent concurrent corruption with retroactive speaker updates
        let savedURL: URL? = fileUpdateQueue.sync {
            do {
                try writeMarkdown(markdown, to: fileURL)

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
            notifySavedTranscript(savedURL, notifier: notifier)

            let metadata = StatsService.createMetadata(
                from: result,
                transcriptPath: savedURL.path,
                title: meetingTitle
            )
            if let statsStore {
                statsStore.recordSession(metadata)
            } else {
                Task { @MainActor in
                    await StatsService.shared.recordSession(metadata)
                }
            }
        }

        return savedURL
    }

    private static func ensureSaveDirectoryExists(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private static func hasMinimumFreeSpace(in directory: URL) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let freeSpace = attrs[.systemFreeSize] as? Int64 else {
            return true
        }

        guard freeSpace >= minimumFreeSpaceForTranscriptSave else {
            AppLogger.pipeline.error("Insufficient disk space for transcript save", ["freeSpace": "\(freeSpace / 1_000_000)MB"])
            return false
        }

        return true
    }

    private static func nextTranscriptFileURL(in directory: URL) -> URL {
        let timestamp = DateFormattingHelper.formatFilename(Date())
        var fileURL = directory.appendingPathComponent("Call_\(timestamp).md")
        var counter = 1
        while FileManager.default.fileExists(atPath: fileURL.path) {
            fileURL = directory.appendingPathComponent("Call_\(timestamp)_\(counter).md")
            counter += 1
        }
        return fileURL
    }

    private static func writeMarkdown(_ markdown: String, to fileURL: URL) throws {
        try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
        FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
        AppLogger.pipeline.info("Transcript saved", ["path": fileURL.path])
    }

    private static func notifySavedTranscript(_ fileURL: URL, notifier: TranscriptNotifier?) {
        guard let notifier else { return }
        Task { @MainActor in
            notifier.notifyTranscriptSaved(fileURL: fileURL)
        }
    }
}

// MARK: - TranscriptStorage conformance
// Empty extension — protocol signatures match TranscriptSaver's static API exactly.
// updateSpeakerNames and retroactivelyUpdateSpeaker live in RetroactiveSpeakerUpdater.swift
// as static methods on TranscriptSaver. Added as part of Step 8 protocol wiring (merge-plan §5.1).

@available(macOS 14.0, *)
extension TranscriptSaver: TranscriptStorage {}
