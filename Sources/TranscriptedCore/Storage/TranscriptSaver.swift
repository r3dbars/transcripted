import Foundation

struct ReplacementTranscriptReservationToken: Hashable, Sendable {
    fileprivate let id: UUID
}

private final class ReplacementTranscriptReservations: @unchecked Sendable {
    private struct Entry {
        let path: String
        let transcriptId: UUID?
        let expectation: TranscriptReplacementExpectation
    }

    private let lock = NSLock()
    private var entries: [ReplacementTranscriptReservationToken: Entry] = [:]

    func reserve(_ url: URL, expectation: TranscriptReplacementExpectation) -> ReplacementTranscriptReservationToken? {
        lock.lock()
        defer { lock.unlock() }

        let path = key(for: url)
        let transcriptId = expectation.captureID
        guard !entries.values.contains(where: {
            $0.path == path || (transcriptId != nil && $0.transcriptId == transcriptId)
        }) else {
            return nil
        }

        let token = ReplacementTranscriptReservationToken(id: UUID())
        entries[token] = Entry(path: path, transcriptId: transcriptId, expectation: expectation)
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

    func reservedExpectation(at url: URL) -> TranscriptReplacementExpectation? {
        let path = key(for: url)
        lock.lock()
        defer { lock.unlock() }
        return entries.values.first { $0.path == path }?.expectation
    }

    func contains(transcriptId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.values.contains { $0.transcriptId == transcriptId }
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
    static func beginReplacingTranscript(
        at url: URL, expectedTranscriptID: UUID? = nil,
        expectation: TranscriptReplacementExpectation? = nil
    ) -> ReplacementTranscriptReservationToken? {
        serializeTranscriptFileUpdate {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            guard let bound = expectation ?? (try? TranscriptReplacementExpectation.capture(
                at: url, expectedCaptureID: expectedTranscriptID
            )), expectedTranscriptID == nil || bound.captureID == expectedTranscriptID,
                  (try? bound.matches(at: url)) == true else { return nil }
            return replacementReservations.reserve(url, expectation: bound)
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
                transcriptId: transcriptIdentity(at: url)
            )
        }
    }

    static func isReplacingTranscript(transcriptId: UUID) -> Bool {
        serializeTranscriptFileUpdate {
            replacementReservations.contains(transcriptId: transcriptId)
        }
    }

    /// Non-blocking reservation probes for MainActor request routing. The
    /// reservation registry has its own lock; callers that need to make a file
    /// mutation decision still use the serialized APIs above.
    static func hasReplacementReservation(at url: URL) -> Bool {
        replacementReservations.contains(url, transcriptId: nil)
    }

    static func hasReplacementReservation(transcriptId: UUID) -> Bool {
        replacementReservations.contains(transcriptId: transcriptId)
    }

    static func isReplacingAnyTranscript(at urls: [URL]) -> Bool {
        serializeTranscriptFileUpdate {
            urls.contains { url in
                replacementReservations.contains(
                    url,
                    transcriptId: transcriptIdentity(at: url)
                )
            }
        }
    }

    static func transcriptIdentity(at url: URL) -> UUID? {
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

    /// Non-recursive listing of a transcript folder, hidden files skipped.
    /// `contentsOfDirectory(at:)` refuses a folder whose own last path
    /// component is a symlink (ENOTDIR), so a meetings folder linked in from
    /// elsewhere listed as empty or unreadable and every stable-id lookup in it
    /// missed. The folder the host chose is still the authority, so list its
    /// target. Entries inside are still checked one by one, and callers keep
    /// refusing symlinked transcript files.
    static func transcriptDirectoryContents(
        of directory: URL,
        fileManager: FileManager = .default
    ) -> [URL]? {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        if let files = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) {
            return files
        }
        let target = directory.resolvingSymlinksInPath()
        guard target.standardizedFileURL.path != directory.standardizedFileURL.path else { return nil }
        return try? fileManager.contentsOfDirectory(
            at: target, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )
    }

    /// Resolves a recovery batch in one bounded directory scan so many stale
    /// journals cannot multiply transcript-directory I/O.
    public static func existingTranscriptURLs(
        in directory: URL,
        transcriptIds: Set<UUID>,
        fileManager: FileManager = .default
    ) -> [UUID: URL] {
        guard !transcriptIds.isEmpty else { return [:] }
        guard let files = transcriptDirectoryContents(of: directory, fileManager: fileManager) else { return [:] }

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

        func render(starred: Bool) -> String {
            var options = formatOptions
            options.starred = starred
            return formatTranscriptMarkdown(
                result: result,
                transcriptId: transcriptId,
                speakerMappings: speakerMappings,
                speakerSources: speakerSources,
                speakerDbIds: speakerDbIds,
                date: transcriptDate,
                meetingTitle: meetingTitle,
                healthInfo: healthInfo,
                transcriptionEngine: transcriptionEngine,
                formatOptions: options
            )
        }

        // A replacement reads authoritative metadata inside the write transaction.
        // Unknown metadata must abort before replacing any bytes or publishing success.
        let expectedStar = formatOptions.starred
        var markdown = render(starred: expectedStar)

        // Serialize file writes to prevent concurrent corruption with retroactive speaker updates.
        // Uses the reentrancy-safe wrapper (not a raw `.sync`) so this cannot deadlock if it is
        // ever invoked while already running inside a `serializeTranscriptFileUpdate` block.
        let savedURL: URL? = serializeTranscriptFileUpdate {
            do {
                if let explicitFileURL {
                    let isReserved = replacementReservations.contains(explicitFileURL, transcriptId: nil)
                    let bound = replacementReservations.reservedExpectation(at: explicitFileURL)
                    let reservedID = bound?.captureID
                    if isReserved {
                        guard let bound, try bound.matches(at: explicitFileURL),
                              reservedID == nil || reservedID == transcriptId else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                    }
                    if let currentStar = try replacedTranscriptStar(explicitFileURL, requiredCaptureID: reservedID),
                       currentStar != expectedStar { markdown = render(starred: currentStar) }
                }
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

    /// A leased replacement must retain its captured identity and protection.
    /// The public explicit-target API also permits a new destination or a plain
    /// readable file; neither claims to replace a reserved meeting capture.
    private static func replacedTranscriptStar(_ url: URL, requiredCaptureID: UUID?) throws -> Bool? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            if requiredCaptureID != nil { throw CocoaError(.fileReadNoSuchFile) }
            return nil
        }
        guard let properties = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              properties.isRegularFile == true, properties.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let values = try TranscriptFrontmatter.readValues(from: url)
        if let requiredCaptureID {
            guard let values, values["capture_type"]?.lowercased() == "meeting",
                  TranscriptFrontmatter.captureID(in: values) == requiredCaptureID else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        guard let values else {
            // Preserve the existing plain-file API, but an incomplete YAML
            // header could conceal a star and must not be treated as unstarred.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let prefix = try handle.read(upToCount: 8) ?? Data()
            let headerPrefixes = ["---\n", "---\r\n", "\u{FEFF}---\n", "\u{FEFF}---\r\n"]
            if headerPrefixes.contains(where: { prefix.starts(with: Data($0.utf8)) }) {
                throw CocoaError(.fileReadCorruptFile)
            }
            return nil
        }
        return TranscriptFrontmatter.isStarred(values: values)
    }

    /// Keeps only the creation date: the new text must get a fresh mtime so mtime-keyed indexes pick it up.
    private struct ExistingFileDates {
        let creationDate: Date

        static func capture(for url: URL?) -> ExistingFileDates? {
            guard let url,
                  FileManager.default.fileExists(atPath: url.path),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let creationDate = attributes[.creationDate] as? Date else {
                return nil
            }

            return ExistingFileDates(creationDate: creationDate)
        }

        func restore(to url: URL) {
            do {
                try FileManager.default.setAttributes([.creationDate: creationDate], ofItemAtPath: url.path)
            } catch {
                AppLogger.pipeline.warning("Failed to restore replacement transcript file dates", [
                    "error_type": String(describing: type(of: error))
                ])
            }
        }
    }
}
