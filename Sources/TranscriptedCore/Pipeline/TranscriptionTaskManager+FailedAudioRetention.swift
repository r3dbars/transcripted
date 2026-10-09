import Foundation
import AVFoundation

// MARK: - Failed-audio retention: keeping failed audio and archiving it into the failed queue

extension TranscriptionTaskManager {
    /// Retains failed audio before writing the durable failed-queue row, without
    /// doing large file copies on the main actor. This is for async failure paths
    /// where losing the process mid-copy can still fall back to the recording
    /// journal / scratch audio recovery on next launch.
    @discardableResult
    public func addFailedTranscriptionRetainingAvailableAudioAfterArchive(
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        taskId: UUID = UUID(),
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        archiveAudio: Bool = true,
        errorKind: PipelineErrorKind? = nil,
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        micOnlyByChoice: Bool = false
    ) async -> Bool {
        guard micAudioURL != nil || systemAudioURL != nil else {
            AppLogger.pipeline.error("No audio files available to retain for failed transcription", [
                "taskId": taskId.uuidString
            ])
            return false
        }

        if archiveAudio,
           let retainedAudioDirectory = resolvedRetainedAudioDirectory() {
            let placeholderTranscriptURL = Self.placeholderFailedTranscriptURL(taskId: taskId, in: retainedAudioDirectory)

            let retainedAudio = await Task.detached(priority: .utility) {
                Self.archiveFailedRecordingAudio(
                    micURL: micAudioURL,
                    systemURL: systemAudioURL,
                    taskId: taskId,
                    transcriptURL: placeholderTranscriptURL,
                    archiveRoot: retainedAudioDirectory
                )
            }.value

            if let retainedAudio {
                return enqueueFailedTranscriptionAfterRetainingAudio(
                    taskId: taskId,
                    retainedAudio: retainedAudio,
                    originalMicURL: micAudioURL,
                    originalSystemURL: systemAudioURL,
                    errorMessage: errorMessage,
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    removeOriginalsAfterArchive: true,
                    errorKind: errorKind,
                    splitLocalSpeakers: splitLocalSpeakers,
                    languageSelection: languageSelection,
                    micOnlyByChoice: micOnlyByChoice
                )
            }
        }

        return addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            taskId: taskId,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio,
            errorKind: errorKind,
            splitLocalSpeakers: splitLocalSpeakers,
            languageSelection: languageSelection,
            micOnlyByChoice: micOnlyByChoice
        )
    }

    @discardableResult
    public func persistUnexpectedCaptureStopFailure(
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        taskId: UUID = UUID(),
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        archiveAudio: Bool = true,
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        micOnlyByChoice: Bool = false
    ) async -> Bool {
        await addFailedTranscriptionRetainingAvailableAudioAfterArchive(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            taskId: taskId,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio,
            splitLocalSpeakers: splitLocalSpeakers,
            languageSelection: languageSelection,
            micOnlyByChoice: micOnlyByChoice
        )
    }

    @discardableResult
    public func promoteFinalizedFailedTranscriptionAudio(
        id: UUID,
        micAudioURL: URL,
        systemAudioURL: URL?
    ) -> Bool {
        guard let existingFailure = failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == id }) else {
            AppLogger.pipeline.warning("Failed transcription audio promotion skipped because entry was missing", [
                "id": id.uuidString
            ])
            return false
        }

        let fileManager = FileManager.default
        let liveMicAudioURL = fileManager.fileExists(atPath: micAudioURL.path) ? micAudioURL : nil
        let liveSystemAudioURL = systemAudioURL.flatMap { url in
            fileManager.fileExists(atPath: url.path) ? url : nil
        }
        guard liveMicAudioURL != nil || liveSystemAudioURL != nil else {
            return fileManager.fileExists(atPath: existingFailure.micAudioURL.path)
        }
        let promotedMicAudioURL = liveMicAudioURL ?? existingFailure.micAudioURL
        let retryIsUsingOriginalAudio = activeTasks[id] != nil
        let promotedSystemAudioURL = liveSystemAudioURL ?? existingFailure.systemAudioURL
        let didPersist = failedTranscriptionManager.updateFailedTranscriptionAudio(
            id: id,
            micAudioURL: promotedMicAudioURL,
            systemAudioURL: promotedSystemAudioURL
        )
        guard didPersist else { return false }

        MeetingRecordingJournalStore.removeJournal(
            forMicAudioURL: promotedMicAudioURL,
            allowedRoots: cleanupDirectories
        )

        scheduleFailedRecordingAudioArchive(
            micURL: promotedMicAudioURL,
            systemURL: promotedSystemAudioURL,
            taskId: id,
            removeOriginalsAfterArchive: !retryIsUsingOriginalAudio,
            originalMicCleanupLabel: "finalized failed mic scratch",
            originalSystemCleanupLabel: "finalized failed system scratch"
        )
        if retryIsUsingOriginalAudio {
            AppLogger.pipeline.info("Deferred finalized failed audio scratch cleanup until active retry finishes", [
                "id": id.uuidString
            ])
        }
        return true
    }

    /// A terminal user action or completed retry owns a late finalization only
    /// to clean it up. Reuse Core's canonical scratch containment checks and
    /// clear the matching crash-recovery journal before removing the files.
    public func discardFinalizedFailedTranscriptionAudio(
        micAudioURL: URL?,
        systemAudioURL: URL?
    ) {
        MeetingRecordingJournalStore.discardRecordingArtifacts(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            allowedRoots: cleanupDirectories
        )
    }

    /// Checks whether the crash-recovery journal still durably owns a late
    /// callback whose bounded app-side identity has already been evicted.
    public func hasRecordingJournal(
        micAudioURL: URL?,
        systemAudioURL: URL?
    ) -> Bool {
        MeetingRecordingJournalStore.hasRecordingJournal(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            allowedRoots: cleanupDirectories
        )
    }

    @discardableResult
    public func addFailedTranscriptionRetainingAvailableAudio(
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        taskId: UUID = UUID(),
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        archiveAudio: Bool = true,
        clearRecordingJournalAfterPersistence: Bool = true,
        errorKind: PipelineErrorKind? = nil,
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        micOnlyByChoice: Bool = false,
        confirmationMeetingId: UUID? = nil
    ) -> Bool {
        guard micAudioURL != nil || systemAudioURL != nil else {
            AppLogger.pipeline.error("No audio files available to retain for failed transcription", [
                "taskId": taskId.uuidString
            ])
            return false
        }

        let didPersist = enqueueFailedTranscriptionAfterRetainingAudio(
            taskId: taskId,
            retainedAudio: nil,
            originalMicURL: micAudioURL,
            originalSystemURL: systemAudioURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            removeOriginalsAfterArchive: false,
            clearRecordingJournalAfterPersistence: clearRecordingJournalAfterPersistence,
            errorKind: errorKind,
            splitLocalSpeakers: splitLocalSpeakers,
            languageSelection: languageSelection,
            micOnlyByChoice: micOnlyByChoice,
            confirmationMeetingId: confirmationMeetingId
        )
        if didPersist, archiveAudio {
            scheduleFailedRecordingAudioArchive(
                micURL: micAudioURL,
                systemURL: systemAudioURL,
                taskId: taskId,
                removeOriginalsAfterArchive: true,
                originalMicCleanupLabel: "archived failed mic scratch",
                originalSystemCleanupLabel: "archived failed system scratch"
            )
        }
        return didPersist
    }

    @discardableResult
    private func enqueueFailedTranscriptionAfterRetainingAudio(
        taskId: UUID,
        retainedAudio: RetainedRecordingAudio?,
        originalMicURL: URL?,
        originalSystemURL: URL?,
        errorMessage: String,
        meetingTitle: String?,
        recordingDate: Date?,
        removeOriginalsAfterArchive: Bool,
        clearRecordingJournalAfterPersistence: Bool = true,
        errorKind: PipelineErrorKind? = nil,
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        micOnlyByChoice: Bool = false,
        confirmationMeetingId: UUID? = nil
    ) -> Bool {
        let retainedMicURL = existingAudioURL(retainedAudio?.micURL)
        let retainedSystemURL = existingAudioURL(retainedAudio?.systemURL)
        let originalMicURLForRetry = retainedMicURL == nil ? existingAudioURL(originalMicURL) : nil
        let originalSystemURLForRetry = retainedSystemURL == nil ? existingAudioURL(originalSystemURL) : nil
        let pendingOriginalSystemURL = retainedAudio == nil ? originalSystemURL : nil
        let failedSystemURL = retainedSystemURL ?? originalSystemURLForRetry ?? pendingOriginalSystemURL
        let placeholderSystemURL = retainedSystemURL ?? originalSystemURLForRetry
        let placeholderMicURL = makeSilentMicPlaceholderIfNeeded(
            retainedAudio: retainedAudio,
            hasOriginalMic: retainedMicURL != nil || originalMicURLForRetry != nil,
            failedSystemURL: placeholderSystemURL,
            taskId: taskId
        )
        // A timeout row may intentionally point at a mic path that will appear
        // after late finalization. Preserve that legacy future path only when
        // there is no readable system track that can own a real placeholder.
        let pendingMicURL = originalSystemURLForRetry == nil && retainedSystemURL == nil
            ? originalMicURL
            : nil
        guard let failedMicURL = retainedMicURL ?? originalMicURLForRetry ?? placeholderMicURL ?? pendingMicURL else {
            AppLogger.pipeline.error("Failed transcription was not queued because no microphone track or placeholder is available")
            return false
        }

        let didPersist = failedTranscriptionManager.addFailedTranscription(
            id: taskId,
            micAudioURL: failedMicURL,
            systemAudioURL: failedSystemURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            errorKind: errorKind,
            splitLocalSpeakers: splitLocalSpeakers,
            languageSelection: languageSelection,
            micOnlyByChoice: micOnlyByChoice,
            confirmationMeetingId: confirmationMeetingId ?? self.confirmationMeetingId(for: taskId)
        )
        guard didPersist else {
            if let retainedAudio {
                removeRetainedFailedAudio(retainedAudio)
            }
            return false
        }

        // A normal failed row owns all of its audio after persistence. A timed-
        // out multi-segment stop keeps the journal until late finalization so a
        // crash cannot lose segment filenames that are not represented by the row.
        if clearRecordingJournalAfterPersistence {
            MeetingRecordingJournalStore.removeJournal(
                micAudioURL: originalMicURL,
                systemAudioURL: originalSystemURL,
                allowedRoots: cleanupDirectories
            )
        }

        guard removeOriginalsAfterArchive else { return true }

        if retainedAudio?.micURL != nil {
            removeManagedCleanupFile(originalMicURL, label: "archived failed mic scratch")
        } else if placeholderMicURL != nil {
            removeManagedCleanupFile(originalMicURL, label: "missing failed mic scratch")
        }
        if retainedAudio?.systemURL != nil {
            removeManagedCleanupFile(originalSystemURL, label: "archived failed system scratch")
        }
        return true
    }

    private func removeRetainedFailedAudio(_ retainedAudio: RetainedRecordingAudio) {
        let fileManager = FileManager.default
        for url in [retainedAudio.micURL, retainedAudio.systemURL].compactMap({ $0 }) {
            try? fileManager.removeItem(at: url)
        }

        let remaining = (try? fileManager.contentsOfDirectory(
            at: retainedAudio.directory,
            includingPropertiesForKeys: nil
        )) ?? []
        if remaining.isEmpty {
            try? fileManager.removeItem(at: retainedAudio.directory)
        }
    }

    private func makeSilentMicPlaceholderIfNeeded(
        retainedAudio: RetainedRecordingAudio?,
        hasOriginalMic: Bool,
        failedSystemURL: URL?,
        taskId: UUID
    ) -> URL? {
        guard !hasOriginalMic,
              let failedSystemURL else {
            return nil
        }

        let placeholderDirectory = retainedAudio?.directory ?? failedSystemURL.deletingLastPathComponent()
        let placeholderStem = retainedAudio == nil
            ? "microphone_placeholder_\(taskId.uuidString)"
            : "microphone_placeholder"
        let placeholderURL = placeholderDirectory
            .appendingPathComponent(placeholderStem)
            .appendingPathExtension("wav")
        do {
            try FileManager.default.createDirectory(
                at: placeholderDirectory,
                withIntermediateDirectories: true
            )
            try Self.writeSilentWAV(to: placeholderURL, duration: 2.5)
            FileManager.default.restrictToOwnerOnly(atPath: placeholderURL.path)
            AppLogger.pipeline.warning("Created silent microphone placeholder for system-only failed meeting audio")
            if retainedAudio == nil {
                // Scratch-directory placeholder: the archive pass will mint its
                // own inside the retained-audio directory and repoint the row,
                // leaving this one with no owner. Remember it so that repoint
                // can retire it.
                scratchMicPlaceholderURLsByTaskId[taskId] = placeholderURL
            }
            return placeholderURL
        } catch {
            AppLogger.pipeline.error("Failed to create silent microphone placeholder", [
                "error": error.localizedDescription
            ])
            return nil
        }
    }

    /// A non-nil URL is not enough for durable retry ownership. Late capture
    /// finalization and partial archive failures can leave a path whose file was
    /// never created, so only persist sources that are actually readable.
    private func existingAudioURL(_ url: URL?) -> URL? {
        guard let url, FileManager.default.isReadableFile(atPath: url.path) else {
            return nil
        }
        return url
    }

    private static func writeSilentWAV(to url: URL, duration: TimeInterval) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw PipelineError.invalidAudioFormat(detail: "Could not create placeholder audio format")
        }
        let frameCount = AVAudioFrameCount((duration * format.sampleRate).rounded(.up))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw PipelineError.invalidAudioFormat(detail: "Could not create placeholder audio buffer")
        }
        buffer.frameLength = frameCount
        // Zero explicitly rather than relying on an undocumented allocator
        // guarantee — this placeholder is fed straight back into the pipeline
        // on retry, so garbage here would be transcribed as audio. Matches
        // `MicRecordingFileMerger.writeSilence`.
        if let channelData = buffer.floatChannelData?[0] {
            channelData.initialize(repeating: 0, count: Int(frameCount))
        }
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
    }

    private func scheduleFailedRecordingAudioArchive(
        micURL: URL?,
        systemURL: URL?,
        taskId: UUID,
        removeOriginalsAfterArchive: Bool,
        originalMicCleanupLabel: String,
        originalSystemCleanupLabel: String
    ) {
        guard let retainedAudioDirectory = resolvedRetainedAudioDirectory() else { return }

        let placeholderTranscriptURL = Self.placeholderFailedTranscriptURL(taskId: taskId, in: retainedAudioDirectory)

        if Self.shouldArchiveFailedAudioSynchronouslyForTests {
            guard let retainedAudio = Self.archiveFailedRecordingAudio(
                micURL: micURL,
                systemURL: systemURL,
                taskId: taskId,
                transcriptURL: placeholderTranscriptURL,
                archiveRoot: retainedAudioDirectory
            ) else { return }
            applyRetainedFailedRecordingAudio(
                retainedAudio,
                micURL: micURL,
                systemURL: systemURL,
                taskId: taskId,
                removeOriginalsAfterArchive: removeOriginalsAfterArchive,
                originalMicCleanupLabel: originalMicCleanupLabel,
                originalSystemCleanupLabel: originalSystemCleanupLabel
            )
            return
        }

        Task { [weak self] in
            let retainedAudio = await Task.detached(priority: .utility) {
                Self.archiveFailedRecordingAudio(
                    micURL: micURL,
                    systemURL: systemURL,
                    taskId: taskId,
                    transcriptURL: placeholderTranscriptURL,
                    archiveRoot: retainedAudioDirectory
                )
            }.value

            guard let self, let retainedAudio else { return }
            self.applyRetainedFailedRecordingAudio(
                retainedAudio,
                micURL: micURL,
                systemURL: systemURL,
                taskId: taskId,
                removeOriginalsAfterArchive: removeOriginalsAfterArchive,
                originalMicCleanupLabel: originalMicCleanupLabel,
                originalSystemCleanupLabel: originalSystemCleanupLabel
            )
        }
    }

    private func applyRetainedFailedRecordingAudio(
        _ retainedAudio: RetainedRecordingAudio,
        micURL: URL?,
        systemURL: URL?,
        taskId: UUID,
        removeOriginalsAfterArchive: Bool,
        originalMicCleanupLabel: String,
        originalSystemCleanupLabel: String
    ) {
        let retainedMicURL = existingAudioURL(retainedAudio.micURL)
        let retainedSystemURL = existingAudioURL(retainedAudio.systemURL)
        let originalMicURLForRetry = retainedMicURL == nil ? existingAudioURL(micURL) : nil
        let originalSystemURLForRetry = retainedSystemURL == nil ? existingAudioURL(systemURL) : nil
        let placeholderMicURL = makeSilentMicPlaceholderIfNeeded(
            retainedAudio: retainedAudio,
            hasOriginalMic: retainedMicURL != nil || originalMicURLForRetry != nil,
            failedSystemURL: retainedSystemURL ?? originalSystemURLForRetry,
            taskId: taskId
        )
        guard let updatedMicURL = retainedMicURL ?? originalMicURLForRetry ?? placeholderMicURL else {
            removeRetainedFailedAudio(retainedAudio)
            return
        }
        let didPersist = failedTranscriptionManager.updateFailedTranscriptionAudio(
            id: taskId,
            micAudioURL: updatedMicURL,
            systemAudioURL: retainedSystemURL ?? originalSystemURLForRetry
        )

        guard didPersist else {
            removeRetainedFailedAudio(retainedAudio)
            return
        }

        // The row now points at the archived audio, so any scratch placeholder
        // minted for this task when the failure was first queued is orphaned.
        // This is deliberately not gated on `retainedAudio.micURL` — for a
        // system-only failure that is always nil, which is exactly the case
        // that leaks. Guard against retiring the file the row still points at.
        if let scratchPlaceholderURL = scratchMicPlaceholderURLsByTaskId.removeValue(forKey: taskId),
           scratchPlaceholderURL.standardizedFileURL != updatedMicURL.standardizedFileURL {
            do {
                try FileManager.default.removeItem(at: scratchPlaceholderURL)
                AppLogger.pipeline.info("Retired superseded scratch microphone placeholder", [
                    "taskId": taskId.uuidString
                ])
            } catch {
                AppLogger.pipeline.warning("Could not retire superseded scratch microphone placeholder", [
                    "taskId": taskId.uuidString,
                    "error": error.localizedDescription
                ])
            }
        }

        guard removeOriginalsAfterArchive else { return }
        if let retainedMicURL = retainedAudio.micURL {
            removeSupersededFailedAudioSource(
                micURL,
                replacementURL: retainedMicURL,
                taskId: taskId,
                label: originalMicCleanupLabel
            )
        }
        if let retainedSystemURL = retainedAudio.systemURL {
            removeSupersededFailedAudioSource(
                systemURL,
                replacementURL: retainedSystemURL,
                taskId: taskId,
                label: originalSystemCleanupLabel
            )
        }
    }

    /// A failed row may already point inside the retained-audio root when a
    /// later finalizer re-archives it. Normal scratch cleanup intentionally
    /// refuses that root, so retire the superseded retained file through a
    /// separate containment-checked path after the queue update is durable.
    private func removeSupersededFailedAudioSource(
        _ originalURL: URL?,
        replacementURL: URL,
        taskId: UUID,
        label: String
    ) {
        guard let originalURL,
              Self.canonicalURL(originalURL) != Self.canonicalURL(replacementURL) else {
            return
        }

        if isSafeCleanupURL(originalURL) {
            _ = removeRecordingFile(originalURL, label: label)
            return
        }

        guard let retainedRoot = resolvedRetainedAudioDirectory(),
              Self.isFile(originalURL, containedIn: retainedRoot) else {
            AppLogger.pipeline.warning("Refused to remove superseded failed audio outside managed roots", [
                "label": label,
                "file": originalURL.lastPathComponent
            ])
            return
        }
        let isStillReferenced = failedTranscriptionManager.failedTranscriptions.contains { failed in
            failed.id != taskId
                && (Self.canonicalURL(failed.micAudioURL) == Self.canonicalURL(originalURL)
                    || failed.systemAudioURL.map(Self.canonicalURL) == Self.canonicalURL(originalURL))
        }
        guard !isStillReferenced else { return }

        do {
            try FileManager.default.removeItem(at: originalURL)
            let parent = originalURL.deletingLastPathComponent()
            let remaining = (try? FileManager.default.contentsOfDirectory(
                at: parent,
                includingPropertiesForKeys: nil
            )) ?? []
            if remaining.isEmpty, Self.isFile(parent, containedIn: retainedRoot) {
                try? FileManager.default.removeItem(at: parent)
            }
        } catch {
            if (error as NSError).code != NSFileNoSuchFileError {
                AppLogger.pipeline.warning("Failed to remove superseded retained failed audio", [
                    "label": label,
                    "file": originalURL.lastPathComponent,
                    "errorType": "\(type(of: error))"
                ])
            }
        }
    }

    nonisolated private static func archiveFailedRecordingAudio(
        micURL: URL?,
        systemURL: URL?,
        taskId: UUID,
        transcriptURL: URL,
        archiveRoot: URL
    ) -> RetainedRecordingAudio? {
        Self.recordFailedAudioArchiveThread()
        do {
            let retainedAudio = try RecordingAudioArchiver.archive(
                micURL: micURL,
                systemURL: systemURL,
                transcriptURL: transcriptURL,
                archiveRoot: archiveRoot,
                fileManager: FailedAudioArchiveThreadProbe.fileManager()
            )
            AppLogger.pipeline.info("Retained failed meeting audio files", [
                "hasMic": "\(retainedAudio.micURL != nil)",
                "hasSystem": "\(retainedAudio.systemURL != nil)"
            ])
            return retainedAudio
        } catch {
            AppLogger.pipeline.warning("Failed to retain failed meeting audio", [
                "taskId": taskId.uuidString,
                "errorType": "\(type(of: error))"
            ])
            return nil
        }
    }

    nonisolated private static var shouldArchiveFailedAudioSynchronouslyForTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.processName == "xctest"
    }

    nonisolated static func setFailedAudioArchiveThreadProbe(
        _ probe: (@Sendable (Bool) -> Void)?
    ) {
        FailedAudioArchiveThreadProbe.set(probe)
    }

    nonisolated static func setFailedAudioArchiveFileManager(_ fileManager: FileManager?) {
        FailedAudioArchiveThreadProbe.setFileManager(fileManager)
    }

    nonisolated private static func recordFailedAudioArchiveThread() {
        FailedAudioArchiveThreadProbe.record(onMainThread: Thread.isMainThread)
    }
}

private enum FailedAudioArchiveThreadProbe {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (Bool) -> Void)?
    nonisolated(unsafe) private static var archiveFileManager: FileManager?

    static func set(_ probe: (@Sendable (Bool) -> Void)?) {
        lock.lock()
        handler = probe
        lock.unlock()
    }

    static func setFileManager(_ fileManager: FileManager?) {
        lock.lock()
        archiveFileManager = fileManager
        lock.unlock()
    }

    static func fileManager() -> FileManager {
        lock.lock()
        let fileManager = archiveFileManager
        lock.unlock()
        return fileManager ?? .default
    }

    static func record(onMainThread: Bool) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(onMainThread)
    }
}

extension TranscriptionTaskManager {
    /// Placeholder transcript path a failed-audio archive is keyed under; the
    /// stem format is shared with RecordingAudioArchiver's audio folder naming.
    private nonisolated static func placeholderFailedTranscriptURL(taskId: UUID, in directory: URL) -> URL {
        let failedStem = "Failed_\(DateFormattingHelper.formatFilename(Date()))_\(String(taskId.uuidString.prefix(8)))"
        return directory
            .appendingPathComponent(failedStem)
            .appendingPathExtension("md")
    }
}
