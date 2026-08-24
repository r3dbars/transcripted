import Foundation

struct ReplacementTranscriptReservationToken: Hashable, Sendable {
    fileprivate let id: UUID
}

private final class ReplacementTranscriptReservations: @unchecked Sendable {
    private struct Entry {
        let path: String
        let transcriptId: UUID?
    }

    private let lock = NSLock()
    private var entries: [ReplacementTranscriptReservationToken: Entry] = [:]

    func reserve(_ url: URL, transcriptId: UUID?) -> ReplacementTranscriptReservationToken? {
        lock.lock()
        defer { lock.unlock() }

        let path = key(for: url)
        guard !entries.values.contains(where: {
            $0.path == path || (transcriptId != nil && $0.transcriptId == transcriptId)
        }) else {
            return nil
        }

        let token = ReplacementTranscriptReservationToken(id: UUID())
        entries[token] = Entry(path: path, transcriptId: transcriptId)
        return token
    }

    func release(_ token: ReplacementTranscriptReservationToken) {
        lock.lock()
        entries.removeValue(forKey: token)
        lock.unlock()
    }

    func contains(_ url: URL, transcriptId: UUID?) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let path = key(for: url)
        return entries.values.contains {
            $0.path == path || (transcriptId != nil && $0.transcriptId == transcriptId)
        }
    }

    private func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public enum TranscriptFileUpdateError: Error, LocalizedError, Equatable {
    case replacementInProgress

    public var errorDescription: String? {
        "That meeting is being re-transcribed. Try again when it finishes."
    }
}

/// Handles automatic saving of transcripts to the filesystem
public class TranscriptSaver {
    private static let fileUpdateQueueSpecific = DispatchSpecificKey<Void>()
    private static let stableIdentityReadChunkSize = 2 * 1024
    private static let replacementReservations = ReplacementTranscriptReservations()

    /// Default save location for the standalone Transcripted app.
    /// Falls back to `CoreStoragePaths.default.transcripts` unless the user has set a
    /// custom location in UserDefaults (the Settings window offers this knob).
    /// Security: validates the custom path against directory traversal and forbidden system
    /// directories before use. Falls back to the default location if validation fails, so
    /// a tampered UserDefaults value cannot redirect transcripts to an arbitrary path.
    ///
    /// Embedders (e.g. the app in this repo) should NOT rely on this property — instead pass an
    /// explicit `directory:` argument to `saveTranscript(...)` so their own storage layout
    /// is honoured.
    public static var defaultSaveDirectory: URL {
        let fallback = CoreStoragePaths.default.transcripts

        // Check for custom save location first
        if let customPath = RecordingValidator.normalizedCustomSavePath(),
           !customPath.isEmpty {
            if let validation = RecordingValidator.validateRawSavePath(customPath) {
                AppLogger.pipeline.warning("Custom save path rejected in defaultSaveDirectory, using default", [
                    "path": customPath,
                    "reason": validation.errorMessage ?? "unknown"
                ])
                return fallback
            }

            let captureLibraryURL = URL(fileURLWithPath: customPath, isDirectory: true)
            let validation = RecordingValidator.validateSavePath(captureLibraryURL)
            guard validation.isValid else {
                AppLogger.pipeline.warning("Custom save path rejected in defaultSaveDirectory, using default", [
                    "path": customPath,
                    "reason": validation.errorMessage ?? "unknown"
                ])
                return fallback
            }
            return captureLibraryURL.appendingPathComponent("meetings", isDirectory: true)
        }

        return fallback
    }

    /// Serial queue for file updates — prevents concurrent reads/writes from corrupting transcripts
    static let fileUpdateQueue: DispatchQueue = {
        let queue = DispatchQueue(label: "com.transcripted.fileupdate", qos: .utility)
        queue.setSpecific(key: fileUpdateQueueSpecific, value: ())
        return queue
    }()

    /// Run a whole-file transcript update under the same serializer as speaker-name rewrites.
    public static func serializeTranscriptFileUpdate<T>(_ update: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: fileUpdateQueueSpecific) != nil {
            return try update()
        }
        return try fileUpdateQueue.sync(execute: update)
    }

    /// Run a user-initiated transcript mutation only when none of its targets
    /// is owned by an in-place replacement. Identity matching keeps the barrier
    /// intact if a path alias or rename changes the target's visible URL.
    public static func serializeTranscriptFileUpdate<T>(
        protecting transcriptURLs: [URL],
        _ update: () throws -> T
    ) throws -> T {
        try serializeTranscriptFileUpdate {
            guard !isReplacingAnyTranscript(at: transcriptURLs) else {
                throw TranscriptFileUpdateError.replacementInProgress
            }
            return try update()
        }
    }

    /// Reserve one saved transcript for in-place replacement. The reservation is
    /// established under the same serializer as speaker edits, so an edit either
    /// finishes before replacement starts or fails closed while it is active.
    @discardableResult
    static func beginReplacingTranscript(at url: URL) -> ReplacementTranscriptReservationToken? {
        serializeTranscriptFileUpdate {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return replacementReservations.reserve(
                url,
                transcriptId: stableTranscriptIdentity(at: url)
            )
        }
    }

    static func finishReplacingTranscript(_ token: ReplacementTranscriptReservationToken) {
        serializeTranscriptFileUpdate {
            replacementReservations.release(token)
        }
    }

    static func isReplacingTranscript(at url: URL) -> Bool {
        serializeTranscriptFileUpdate {
            replacementReservations.contains(
                url,
                transcriptId: stableTranscriptIdentity(at: url)
            )
        }
    }

    static func isReplacingAnyTranscript(at urls: [URL]) -> Bool {
        serializeTranscriptFileUpdate {
            urls.contains { url in
                replacementReservations.contains(
                    url,
                    transcriptId: stableTranscriptIdentity(at: url)
                )
            }
        }
    }

    private static func stableTranscriptIdentity(at url: URL) -> UUID? {
        guard let values = try? TranscriptFrontmatter.readValues(
            from: url,
            byteLimit: stableIdentityReadChunkSize
        ) else {
            return nil
        }
        return TranscriptFrontmatter.captureID(in: values)
    }

    /// Finds an already-written transcript by its stable frontmatter identity.
    /// Recovery uses this to make a crash immediately after the atomic Markdown
    /// write idempotent instead of producing a second timestamp-suffixed file.
    public static func existingTranscriptURL(
        in directory: URL,
        transcriptId: UUID,
        fileManager: FileManager = .default
    ) -> URL? {
        existingTranscriptURLs(
            in: directory,
            transcriptIds: [transcriptId],
            fileManager: fileManager
        )[transcriptId]
    }

    /// Resolves a recovery batch in one bounded directory scan so many stale
    /// journals cannot multiply transcript-directory I/O.
    public static func existingTranscriptURLs(
        in directory: URL,
        transcriptIds: Set<UUID>,
        fileManager: FileManager = .default
    ) -> [UUID: URL] {
        guard !transcriptIds.isEmpty else { return [:] }
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [:] }

        var matches: [UUID: URL] = [:]
        let markdownFiles = files
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in markdownFiles {
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let frontmatter = try? TranscriptFrontmatter.readValues(
                    from: url,
                    byteLimit: stableIdentityReadChunkSize
                  ),
                  let transcriptId = TranscriptFrontmatter.captureID(in: frontmatter),
                  transcriptIds.contains(transcriptId),
                  matches[transcriptId] == nil
            else { continue }
            matches[transcriptId] = url
        }
        return matches
    }

    /// Save transcript to file with automatic timestamped naming
    /// - Parameters:
    ///   - text: The transcript text to save
    ///   - duration: Recording duration in seconds
    ///   - directory: Optional custom directory (defaults to `CoreStoragePaths.default.transcripts`)
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

    // MARK: - Local Transcript Saving (STT + PyAnnote)

    /// Save transcript from the local STT + PyAnnote diarization pipeline
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
        transcriptId: UUID,
        speakerMappings: [String: SpeakerMapping] = [:],
        speakerSources: [String: String] = [:],
        speakerDbIds: [String: UUID] = [:],
        directory: URL? = nil,
        meetingTitle: String? = nil,
        healthInfo: RecordingHealthInfo? = nil,
        notifier: TranscriptNotifier? = nil,
        speakerStore: (any SpeakerStore)? = nil,
        statsStore: (any StatsStore)? = nil,
        formatOptions: TranscriptFormatOptions = .default
    ) -> URL? {
        return saveTranscript(
            result,
            transcriptId: transcriptId,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            directory: directory,
            meetingTitle: meetingTitle,
            healthInfo: healthInfo,
            notifier: notifier,
            speakerStore: speakerStore,
            statsStore: statsStore,
            transcriptionEngine: .parakeetLocal,
            formatOptions: formatOptions
        )
    }

    @available(macOS 14.0, *)
    @discardableResult
    public static func saveTranscript(
        _ result: TranscriptionResult,
        transcriptId: UUID,
        speakerMappings: [String: SpeakerMapping] = [:],
        speakerSources: [String: String] = [:],
        speakerDbIds: [String: UUID] = [:],
        directory: URL? = nil,
        meetingTitle: String? = nil,
        healthInfo: RecordingHealthInfo? = nil,
        notifier: TranscriptNotifier? = nil,
        speakerStore: (any SpeakerStore)? = nil,
        statsStore: (any StatsStore)? = nil
    ) -> URL? {
        saveTranscript(
            result,
            transcriptId: transcriptId,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            directory: directory,
            meetingTitle: meetingTitle,
            healthInfo: healthInfo,
            notifier: notifier,
            speakerStore: speakerStore,
            statsStore: statsStore,
            formatOptions: .default
        )
    }

    @available(macOS 14.0, *)
    @discardableResult
    public static func saveTranscript(
        _ result: TranscriptionResult,
        transcriptId: UUID,
        speakerMappings: [String: SpeakerMapping] = [:],
        speakerSources: [String: String] = [:],
        speakerDbIds: [String: UUID] = [:],
        directory: URL? = nil,
        meetingTitle: String? = nil,
        healthInfo: RecordingHealthInfo? = nil,
        notifier: TranscriptNotifier? = nil,
        speakerStore: (any SpeakerStore)? = nil,
        statsStore: (any StatsStore)? = nil,
        recordingDate: Date? = nil,
        targetURL: URL? = nil,
        transcriptionEngine: SpeechTranscriptionEngineDescriptor,
        formatOptions: TranscriptFormatOptions = .default
    ) -> URL? {
        let explicitFileURL = targetURL
        let saveDir = explicitFileURL?.deletingLastPathComponent() ?? directory ?? defaultSaveDirectory

        do {
            try FileManager.default.createDirectory(at: saveDir, withIntermediateDirectories: true)
        } catch {
            AppLogger.pipeline.error("Failed to create save directory", ["error": error.localizedDescription])
            return nil
        }

        // Check disk space before writing.
        if let attrs = try? FileManager.default.attributesOfFileSystem(forPath: saveDir.path),
           let freeSpace = attrs[.systemFreeSize] as? Int64,
           freeSpace < 50_000_000 { // 50MB minimum
            AppLogger.pipeline.error("Insufficient disk space for transcript save", ["freeSpace": "\(freeSpace / 1_000_000)MB"])
            return nil
        }

        let transcriptDate = recordingDate ?? Date()
        let fileURL: URL
        let replacementFileDates = ExistingFileDates.capture(for: explicitFileURL)
        if let explicitFileURL {
            fileURL = explicitFileURL
        } else {
            let timestamp = DateFormattingHelper.formatFilename(transcriptDate)
            var candidateURL = saveDir.appendingPathComponent("Call_\(timestamp).md")
            var counter = 1
            while FileManager.default.fileExists(atPath: candidateURL.path) {
                candidateURL = saveDir.appendingPathComponent("Call_\(timestamp)_\(counter).md")
                counter += 1
            }
            fileURL = candidateURL
        }

        let markdown = formatTranscriptMarkdown(
            result: result,
            transcriptId: transcriptId,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            date: transcriptDate,
            meetingTitle: meetingTitle,
            healthInfo: healthInfo,
            transcriptionEngine: transcriptionEngine,
            formatOptions: formatOptions
        )

        // Serialize file writes to prevent concurrent corruption with retroactive speaker updates.
        // Uses the reentrancy-safe wrapper (not a raw `.sync`) so this cannot deadlock if it is
        // ever invoked while already running inside a `serializeTranscriptFileUpdate` block.
        let savedURL: URL? = serializeTranscriptFileUpdate {
            do {
                try markdown.write(to: fileURL, atomically: true, encoding: .utf8)
                FileManager.default.restrictToOwnerOnly(atPath: fileURL.path)
                replacementFileDates?.restore(to: fileURL)

                AppLogger.pipeline.info("Transcript saved", ["path": fileURL.path])

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
            let metadata = RecordingMetadata.from(
                result: result,
                captureId: transcriptId,
                transcriptPath: savedURL.path,
                title: meetingTitle,
                date: transcriptDate
            )
            (statsStore ?? StatsDatabase.shared).recordSession(metadata)
        }

        return savedURL
    }

    private struct ExistingFileDates {
        let creationDate: Date?
        let modificationDate: Date?

        static func capture(for url: URL?) -> ExistingFileDates? {
            guard let url,
                  FileManager.default.fileExists(atPath: url.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                return nil
            }

            return ExistingFileDates(
                creationDate: attributes[.creationDate] as? Date,
                modificationDate: attributes[.modificationDate] as? Date
            )
        }

        func restore(to url: URL) {
            var attributes: [FileAttributeKey: Any] = [:]
            if let creationDate {
                attributes[.creationDate] = creationDate
            }
            if let modificationDate {
                attributes[.modificationDate] = modificationDate
            }
            guard !attributes.isEmpty else { return }

            do {
                try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
            } catch {
                AppLogger.pipeline.warning("Failed to restore replacement transcript file dates", [
                    "error_type": String(describing: type(of: error))
                ])
            }
        }
    }
}

@available(macOS 14.0, *)
