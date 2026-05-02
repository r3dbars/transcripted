import Foundation
import AVFoundation

// MARK: - Transcription Task Queue & Orchestration
// Extensions in: SpeakerNamingCoordinator.swift, TranscriptionPipelineRunner.swift
// Types in: DisplayStatus.swift (DisplayStatus enum, TranscriptionTask struct)

@available(macOS 14.0, *)
@MainActor
public class TranscriptionTaskManager: ObservableObject {
    @Published public var activeCount: Int = 0
    @Published public var justCompleted: Bool = false
    @Published public var displayStatus: DisplayStatus = .idle
    @Published public var backgroundTaskCount: Int = 0
    @Published public var speakerNamingRequest: SpeakerNamingRequest? = nil
    @Published public var lastSavedTranscriptURL: URL? = nil
    @Published public var lastSavedTitle: String? = nil
    @Published public var lastSavedDuration: String? = nil
    @Published public var lastSavedSpeakerCount: Int? = nil

    var activeTasks: [UUID: Task<Void, Never>] = [:]
    public let transcription: Transcription

    public let failedTranscriptionManager: FailedTranscriptionManager
    public let statsStore: (any StatsStore)?
    let retainedAudioDirectory: URL?
    private let retainedAudioDirectoryProvider: (() -> URL?)?
    private let cleanupDirectories: [URL]

    /// Embedder-supplied notifier for transcript-saved and failure events. Optional — when
    /// `nil`, notification hooks become no-ops, which keeps Core usable from headless contexts
    /// (tests, CLI tools) and embedders that prefer their own in-app presentation.
    public let notifier: TranscriptNotifier?

    public init(
        failedTranscriptionManager: FailedTranscriptionManager,
        speechToText: any SpeechToTextEngine,
        diarization: any DiarizationEngine,
        speakerStore: any SpeakerStore,
        speakerClipsDirectory: URL = CoreStoragePaths.default.speakerClips,
        cleanupDirectories: [URL]? = nil,
        retainedAudioDirectory: URL? = nil,
        retainedAudioDirectoryProvider: (() -> URL?)? = nil,
        statsStore: (any StatsStore)? = nil,
        notifier: TranscriptNotifier? = nil
    ) {
        self.failedTranscriptionManager = failedTranscriptionManager
        self.statsStore = statsStore
        self.notifier = notifier
        self.retainedAudioDirectory = retainedAudioDirectory
        self.retainedAudioDirectoryProvider = retainedAudioDirectoryProvider
        self.cleanupDirectories = (cleanupDirectories ?? [speakerClipsDirectory])
            .map(Self.canonicalDirectoryURL)
        self.transcription = Transcription(
            speechToText: speechToText,
            diarization: diarization,
            speakerStore: speakerStore,
            speakerClipsDirectory: speakerClipsDirectory
        )
    }

    // MARK: - Task Lifecycle

    /// Start a new transcription task in the background.
    /// When `splitLocalSpeakers` is true, the mic channel goes through PyAnnote diarization
    /// so multiple in-room speakers can be named individually (GitHub #312). Default false
    /// preserves the single-"You" behavior.
    public func startTranscription(
        micURL: URL,
        systemURL: URL?,
        outputFolder: URL,
        healthInfo: RecordingHealthInfo? = nil,
        splitLocalSpeakers: Bool = false
    ) {

        // Guard: reject concurrent pipelines to prevent model contention
        if !activeTasks.isEmpty {
            AppLogger.pipeline.warning("Rejecting transcription — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            failedTranscriptionManager.addFailedTranscription(
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                errorMessage: "Transcription already in progress"
            )
            displayStatus = .failed(message: "Transcription already in progress")
            scheduleStatusReset(delay: 4)
            return
        }

        guard systemURL != nil else {
            let errorMessage = PipelineError.missingSystemAudio.localizedDescription
            AppLogger.pipeline.warning("Rejecting transcription — system audio capture is missing")
            archiveFailedRecordingAudioIfConfigured(
                micURL: micURL,
                systemURL: nil,
                taskId: UUID()
            )
            failedTranscriptionManager.addFailedTranscription(
                micAudioURL: micURL,
                systemAudioURL: nil,
                errorMessage: errorMessage
            )
            displayStatus = .failed(message: "System audio required")
            sendFailureNotification(errorMessage: errorMessage)
            scheduleStatusReset(delay: 4)
            return
        }

        // Gate: reject only when every available capture track is too short.
        // Meeting recovery can produce a very short mic stub while system audio is still
        // intact and fully transcribable, so don't throw away the whole recording just
        // because the mic side is below Parakeet's minimum length.
        let minDuration: TimeInterval = 2.0
        let micDuration = audioDuration(url: micURL)
        let systemDuration = systemURL.flatMap { audioDuration(url: $0) }
        let hasUsableMicAudio = (micDuration ?? 0) >= minDuration
        let hasUsableSystemAudio = (systemDuration ?? 0) >= minDuration

        guard hasUsableMicAudio || hasUsableSystemAudio else {
            AppLogger.pipeline.info("Recording too short, skipping transcription", [
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? "unknown",
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? "none"
            ])

            removeRecordingFile(micURL, label: "short mic recording")
            if let systemURL {
                removeRecordingFile(systemURL, label: "short system recording")
            }

            self.displayStatus = .failed(message: "Recording too short")
            self.scheduleStatusReset(delay: 3)
            return
        }

        if !hasUsableMicAudio, hasUsableSystemAudio {
            AppLogger.pipeline.warning("Proceeding with short mic capture because system audio is still usable", [
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? "unknown",
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? "unknown"
            ])
        }

        let task = TranscriptionTask(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            healthInfo: healthInfo,
            splitLocalSpeakers: splitLocalSpeakers
        )

        activeCount += 1
        backgroundTaskCount += 1
        displayStatus = .gettingReady

        AppLogger.pipeline.info("Starting transcription task", [
            "taskId": "\(task.id)",
            "activeCount": "\(activeCount)",
            "splitLocalSpeakers": "\(splitLocalSpeakers)"
        ])

        let asyncTask = Task {
            do {
                await MainActor.run {
                    self.displayStatus = .transcribing(progress: 0.0)
                }

                let transcriptURL = try await self.transcribeWithSpeakerIdentification(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputFolder: outputFolder,
                    taskId: task.id,
                    healthInfo: task.healthInfo,
                    splitLocalSpeakers: task.splitLocalSpeakers
                )

                await MainActor.run {
                    if self.speakerNamingRequest == nil {
                        self.populateSavedMetadata(from: transcriptURL)
                        self.displayStatus = .transcriptSaved
                        self.scheduleStatusReset(delay: 4)
                    } else {
                        self.displayStatus = .finishing
                    }
                    self.handleTaskCompletion(taskId: task.id)
                }

            } catch {
                AppLogger.pipeline.error("Transcription task failed", ["taskId": "\(task.id)", "error": "\(error.localizedDescription)"])

                await MainActor.run {
                    self.archiveFailedRecordingAudioIfConfigured(
                        micURL: micURL,
                        systemURL: systemURL,
                        taskId: task.id
                    )
                    self.displayStatus = .failed(message: "Transcription failed")
                    self.failedTranscriptionManager.addFailedTranscription(
                        micAudioURL: micURL,
                        systemAudioURL: systemURL,
                        errorMessage: error.localizedDescription
                    )
                    self.sendFailureNotification(errorMessage: error.localizedDescription)
                    self.handleTaskCompletion(taskId: task.id)
                }
            }
        }

        activeTasks[task.id] = asyncTask
    }

    /// Start a new transcription task for an imported audio file.
    /// Imported files reuse the system-audio speaker path and are not added to the
    /// failed-transcription queue because the user can simply re-import the source file.
    public func startImportedTranscription(
        audioURL: URL,
        outputFolder: URL,
        meetingTitle: String? = nil
    ) {
        if !activeTasks.isEmpty {
            AppLogger.pipeline.warning("Rejecting imported transcription — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            removeRecordingFile(audioURL, label: "rejected imported recording")
            displayStatus = .failed(message: "Transcription already in progress")
            scheduleStatusReset(delay: 4)
            return
        }

        let minDuration: TimeInterval = 2.0
        if let audioDuration = audioDuration(url: audioURL), audioDuration < minDuration {
            AppLogger.pipeline.info("Imported recording too short, skipping transcription", ["duration": String(format: "%.1fs", audioDuration)])
            removeRecordingFile(audioURL, label: "short imported recording")
            displayStatus = .failed(message: "Recording too short")
            scheduleStatusReset(delay: 3)
            return
        }

        let taskId = UUID()
        activeCount += 1
        backgroundTaskCount += 1
        displayStatus = .gettingReady

        AppLogger.pipeline.info("Starting imported transcription task", [
            "taskId": taskId.uuidString,
            "activeCount": "\(activeCount)"
        ])

        let asyncTask = Task {
            do {
                await MainActor.run {
                    self.displayStatus = .transcribing(progress: 0.0)
                }

                let transcriptURL = try await self.transcribeImportedAudio(
                    audioURL: audioURL,
                    outputFolder: outputFolder,
                    taskId: taskId,
                    meetingTitle: meetingTitle
                )

                await MainActor.run {
                    if self.speakerNamingRequest == nil {
                        self.populateSavedMetadata(from: transcriptURL)
                        self.displayStatus = .transcriptSaved
                        self.scheduleStatusReset(delay: 4)
                    } else {
                        self.displayStatus = .finishing
                    }
                    self.handleTaskCompletion(taskId: taskId)
                }
            } catch {
                AppLogger.pipeline.error("Imported transcription task failed", [
                    "taskId": taskId.uuidString,
                    "error": error.localizedDescription
                ])

                await MainActor.run {
                    self.removeRecordingFile(audioURL, label: "failed imported recording")
                    self.displayStatus = .failed(message: "Transcription failed")
                    self.sendFailureNotification(errorMessage: error.localizedDescription)
                    self.handleTaskCompletion(taskId: taskId)
                    self.scheduleStatusReset(delay: 4)
                }
            }
        }

        activeTasks[taskId] = asyncTask
    }

    /// Retry a failed transcription by its ID
    public func retryFailedTranscription(failedId: UUID, outputFolder: URL) async -> Bool {
        // Guard: reject if a pipeline is already active — same constraint as startTranscription.
        // Without this guard a retry launched from Settings can run concurrently with a fresh
        // transcription, causing model contention (both Parakeet and PyAnnote are single-instance;
        // parallel pipelines cause inference errors and hangs).
        guard activeTasks.isEmpty else {
            AppLogger.pipeline.warning("Rejecting retry — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            return false
        }

        guard let failed = failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == failedId }) else {
            AppLogger.pipeline.error("Failed transcription not found", ["failedId": "\(failedId)"])
            return false
        }

        guard failed.isRetryable else {
            AppLogger.pipeline.info("Skipping retry — failure is permanent", ["failedId": "\(failedId)", "error": failed.errorMessage])
            return false
        }

        guard failed.audioFilesExist() else {
            AppLogger.pipeline.error("Audio files no longer exist for failed transcription", ["failedId": "\(failedId)"])
            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
            }
            return false
        }

        AppLogger.pipeline.info("Retrying failed transcription", ["failedId": "\(failedId)"])

        // Register a sentinel in activeTasks before the first suspension point so that
        // startTranscription's `activeTasks.isEmpty` guard blocks until the retry finishes.
        // The sentinel Task does no work — its presence in the dict is what matters.
        activeTasks[failedId] = Task {}

        await MainActor.run {
            failedTranscriptionManager.incrementRetryCount(id: failedId)
            self.activeCount += 1
            self.backgroundTaskCount += 1
            self.displayStatus = .gettingReady
        }

        do {
            // Retries don't carry the original task's splitLocalSpeakers flag — retries are
            // rare and the feature default is off, so we use the default. If users retry
            // after enabling local split, they can restart the meeting capture instead.
            let transcriptURL = try await transcribeWithSpeakerIdentification(
                micURL: failed.micAudioURL,
                systemURL: failed.systemAudioURL,
                outputFolder: outputFolder,
                taskId: failedId,
                healthInfo: nil,
                splitLocalSpeakers: false
            )

            AppLogger.pipeline.info("Retry successful", ["file": transcriptURL.lastPathComponent])

            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
                self.activeTasks.removeValue(forKey: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                if self.speakerNamingRequest == nil {
                    self.populateSavedMetadata(from: transcriptURL)
                    self.displayStatus = .transcriptSaved
                    self.scheduleStatusReset(delay: 4)
                } else {
                    self.displayStatus = .finishing
                }
            }

            return true

        } catch {
            AppLogger.pipeline.error("Retry failed", ["error": "\(error.localizedDescription)"])
            await MainActor.run {
                self.activeTasks.removeValue(forKey: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.displayStatus = .failed(message: "Retry failed")
                self.scheduleStatusReset(delay: 8)
            }
            return false
        }
    }

    // MARK: - Task Completion & Cleanup

    func handleTaskCompletion(taskId: UUID) {
        activeTasks.removeValue(forKey: taskId)
        activeCount = max(0, activeCount - 1)
        backgroundTaskCount = max(0, backgroundTaskCount - 1)

        AppLogger.pipeline.info("Task cleaned up", ["taskId": "\(taskId)", "remaining": "\(activeCount)", "backgroundTasks": "\(backgroundTaskCount)"])

        if activeCount == 0 {
            justCompleted = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.justCompleted = false
            }
        }
    }

    public func cancelAll() {
        for (taskId, task) in activeTasks {
            task.cancel()
            AppLogger.pipeline.info("Cancelled task", ["taskId": "\(taskId)"])
        }
        activeTasks.removeAll()
        activeCount = 0
        backgroundTaskCount = 0
        displayStatus = .idle
    }

    /// Populate saved transcript metadata from the file's YAML frontmatter.
    /// Reads the YAML frontmatter in bounded chunks so larger metadata blocks
    /// (many speakers, gap events, etc.) still parse without reading the whole file.
    func populateSavedMetadata(from url: URL) {
        lastSavedTranscriptURL = url
        let name = url.deletingPathExtension().lastPathComponent
        lastSavedTitle = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let yaml = readYAMLFrontmatter(from: url) else { return }
        var speakers = 0
        for line in yaml.components(separatedBy: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { String($0).trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            switch parts[0] {
            case "title": lastSavedTitle = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "duration": lastSavedDuration = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            case "mic_speakers", "system_speakers": speakers += Int(parts[1]) ?? 0
            default: break
            }
        }
        lastSavedSpeakerCount = speakers
    }

    private func readYAMLFrontmatter(from url: URL, chunkSize: Int = 2048, maxBytes: Int = 64 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var data = Data()
        let closingMarker = Data("\n---\n".utf8)

        while data.count < maxBytes {
            let remaining = maxBytes - data.count
            let chunk = handle.readData(ofLength: min(chunkSize, remaining))
            guard !chunk.isEmpty else { break }
            data.append(chunk)

            if data.starts(with: Data("---".utf8)),
               let endRange = data.range(of: closingMarker, in: 3..<data.count),
               let raw = String(data: data[..<endRange.lowerBound], encoding: .utf8) {
                return String(raw.dropFirst(4))
            }
        }

        return nil
    }

    func scheduleStatusReset(delay: TimeInterval = 3) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            // Don't reset if speaker naming is in progress —
            // SpeakerNamingCoordinator will re-publish .transcriptSaved when done
            guard self.speakerNamingRequest == nil else { return }
            switch self.displayStatus {
            case .transcriptSaved, .failed:
                self.displayStatus = .idle
            default:
                break
            }
        }
    }

    // MARK: - Utilities

    /// Ask the embedder to request system notification permission. No-op if no notifier
    /// was supplied at init.
    public func requestNotificationPermission() {
        notifier?.requestNotificationPermission()
    }

    func audioDuration(url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = Double(file.length)
        let sampleRate = file.processingFormat.sampleRate
        guard AudioRecordingFormatPolicy.isUsableSampleRate(sampleRate) else { return nil }
        return frames / sampleRate
    }

    func sendFailureNotification(errorMessage: String) {
        guard let notifier else {
            AppLogger.pipeline.debug("Skipping failure notification — no notifier configured")
            return
        }
        notifier.notifyTranscriptionFailed(errorMessage: errorMessage)
    }

    nonisolated private func removeRecordingFile(_ url: URL, label: String) {
        // Security: only delete scratch files inside Transcripted-managed cleanup roots.
        // `startImportedTranscription` accepts a URL from the caller, so without a containment
        // check a misuse or tampered in-memory request could unlink arbitrary user files.
        guard isSafeCleanupURL(url) else {
            AppLogger.pipeline.error("Refused to delete out-of-sandbox recording file", [
                "label": label,
                "path": url.path
            ])
            return
        }

        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            AppLogger.pipeline.warning("Failed to remove recording file", [
                "label": label,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
        }
    }

    func resolvedRetainedAudioDirectory() -> URL? {
        retainedAudioDirectoryProvider?() ?? retainedAudioDirectory
    }

    nonisolated func removeManagedCleanupFile(_ url: URL?, label: String) {
        guard let url else { return }
        removeRecordingFile(url, label: label)
    }

    nonisolated private func isSafeCleanupURL(_ url: URL) -> Bool {
        let canonicalURL = Self.canonicalURL(url)
        return cleanupDirectories.contains { root in
            Self.isFile(canonicalURL, containedIn: root)
        }
    }

    private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private static func canonicalDirectoryURL(_ url: URL) -> URL {
        canonicalURL(url)
    }

    private static func isFile(_ fileURL: URL, containedIn directoryURL: URL) -> Bool {
        let filePath = canonicalURL(fileURL).path
        let directoryPath = canonicalDirectoryURL(directoryURL).path
        let normalizedDirectoryPath = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath.hasPrefix(normalizedDirectoryPath)
    }

    private func archiveFailedRecordingAudioIfConfigured(
        micURL: URL?,
        systemURL: URL?,
        taskId: UUID
    ) {
        guard let retainedAudioDirectory = resolvedRetainedAudioDirectory() else { return }

        let failedStem = "Failed_\(DateFormattingHelper.formatFilename(Date()))_\(String(taskId.uuidString.prefix(8)))"
        let placeholderTranscriptURL = retainedAudioDirectory
            .appendingPathComponent(failedStem)
            .appendingPathExtension("md")

        do {
            let retainedAudio = try RecordingAudioArchiver.archive(
                micURL: micURL,
                systemURL: systemURL,
                transcriptURL: placeholderTranscriptURL,
                archiveRoot: retainedAudioDirectory
            )
            AppLogger.pipeline.info("Retained failed meeting audio files", [
                "directory": retainedAudio.directory.lastPathComponent,
                "mic": retainedAudio.micURL?.lastPathComponent ?? "none",
                "system": retainedAudio.systemURL?.lastPathComponent ?? "none"
            ])
        } catch {
            AppLogger.pipeline.warning("Failed to retain failed meeting audio", [
                "taskId": taskId.uuidString,
                "error": error.localizedDescription
            ])
        }
    }
}
