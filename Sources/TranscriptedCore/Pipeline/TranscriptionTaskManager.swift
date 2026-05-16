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
    @Published public private(set) var lastFailureDiagnosticMessage: String? = nil

    var lastSavedTranscriptId: UUID?
    var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTaskAudio: [UUID: (micURL: URL, systemURL: URL?, meetingTitle: String?)] = [:]
    private var preservedTaskIdsForShutdown: Set<UUID> = []
    var pendingSpeakerNamingRequests: [SpeakerNamingRequest] = []
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
        meetingTitle: String? = nil,
        splitLocalSpeakers: Bool = false
    ) {

        // Guard: reject concurrent pipelines to prevent model contention
        if !activeTasks.isEmpty {
            AppLogger.pipeline.warning("Rejecting transcription — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            addFailedTranscriptionRetainingAudio(
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                errorMessage: "Transcription already in progress",
                meetingTitle: meetingTitle
            )
            publishFailure(
                displayMessage: "Transcription already in progress",
                diagnosticMessage: "Transcription already in progress"
            )
            scheduleStatusReset(delay: 4)
            return
        }

        guard systemURL != nil else {
            let errorMessage = PipelineError.missingSystemAudio.localizedDescription
            AppLogger.pipeline.warning("Rejecting transcription — system audio capture is missing")
            addFailedTranscriptionRetainingAudio(
                micAudioURL: micURL,
                systemAudioURL: nil,
                errorMessage: errorMessage,
                meetingTitle: meetingTitle
            )
            publishFailure(
                displayMessage: "System audio required",
                diagnosticMessage: errorMessage
            )
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
        let hasUsableMicAudio = micDuration.map { $0 >= minDuration } ?? false
        let hasUsableSystemAudio = systemDuration.map { $0 >= minDuration } ?? false
        let hasUnknownDuration = micDuration == nil || (systemURL != nil && systemDuration == nil)

        guard hasUsableMicAudio || hasUsableSystemAudio || hasUnknownDuration else {
            AppLogger.pipeline.info("Recording too short, skipping transcription", [
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? "unknown",
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? "none"
            ])

            removeRecordingFile(micURL, label: "short mic recording")
            if let systemURL {
                removeRecordingFile(systemURL, label: "short system recording")
            }

            self.publishFailure(
                displayMessage: "Recording too short",
                diagnosticMessage: "Recording too short"
            )
            self.scheduleStatusReset(delay: 3)
            return
        }

        if hasUnknownDuration {
            AppLogger.pipeline.warning("Recording duration could not be verified; preserving retry path instead of treating it as short", [
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? "unknown",
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? (systemURL == nil ? "none" : "unknown")
            ])
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
            splitLocalSpeakers: splitLocalSpeakers,
            meetingTitle: meetingTitle
        )

        activeCount += 1
        backgroundTaskCount += 1
        activeTaskAudio[task.id] = (micURL: micURL, systemURL: systemURL, meetingTitle: meetingTitle)
        publishNonFailureStatus(.gettingReady)

        AppLogger.pipeline.info("Starting transcription task", [
            "taskId": "\(task.id)",
            "activeCount": "\(activeCount)",
            "splitLocalSpeakers": "\(splitLocalSpeakers)"
        ])

        let asyncTask = Task {
            do {
                await MainActor.run {
                    self.publishNonFailureStatus(.transcribing(progress: 0.0))
                }

                let transcriptURL = try await self.transcribeWithSpeakerIdentification(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputFolder: outputFolder,
                    taskId: task.id,
                    healthInfo: task.healthInfo,
                    splitLocalSpeakers: task.splitLocalSpeakers,
                    meetingTitle: task.meetingTitle
                )

                await MainActor.run {
                    self.publishTranscriptSaved(from: transcriptURL)
                    self.handleTaskCompletion(taskId: task.id)
                }

            } catch {
                AppLogger.pipeline.error("Transcription task failed", ["taskId": "\(task.id)", "error": "\(error.localizedDescription)"])

                await MainActor.run {
                    if self.preservedTaskIdsForShutdown.remove(task.id) != nil {
                        self.handleTaskCompletion(taskId: task.id)
                        return
                    }

                    self.publishFailure(
                        displayMessage: "Transcription failed",
                        diagnosticMessage: Self.safeFailureDiagnosticMessage(for: error)
                    )
                    self.addFailedTranscriptionRetainingAvailableAudio(
                        micAudioURL: micURL,
                        systemAudioURL: systemURL,
                        errorMessage: error.localizedDescription,
                        taskId: task.id,
                        meetingTitle: task.meetingTitle
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
            publishFailure(
                displayMessage: "Transcription already in progress",
                diagnosticMessage: "Transcription already in progress"
            )
            scheduleStatusReset(delay: 4)
            return
        }

        let minDuration: TimeInterval = 2.0
        if let audioDuration = audioDuration(url: audioURL), audioDuration < minDuration {
            AppLogger.pipeline.info("Imported recording too short, skipping transcription", ["duration": String(format: "%.1fs", audioDuration)])
            removeRecordingFile(audioURL, label: "short imported recording")
            publishFailure(
                displayMessage: "Recording too short",
                diagnosticMessage: "Recording too short"
            )
            scheduleStatusReset(delay: 3)
            return
        }

        let taskId = UUID()
        activeCount += 1
        backgroundTaskCount += 1
        publishNonFailureStatus(.gettingReady)

        AppLogger.pipeline.info("Starting imported transcription task", [
            "taskId": taskId.uuidString,
            "activeCount": "\(activeCount)"
        ])

        let asyncTask = Task {
            do {
                await MainActor.run {
                    self.publishNonFailureStatus(.transcribing(progress: 0.0))
                }

                let transcriptURL = try await self.transcribeImportedAudio(
                    audioURL: audioURL,
                    outputFolder: outputFolder,
                    taskId: taskId,
                    meetingTitle: meetingTitle
                )

                await MainActor.run {
                    self.publishTranscriptSaved(from: transcriptURL)
                    self.handleTaskCompletion(taskId: taskId)
                }
            } catch {
                AppLogger.pipeline.error("Imported transcription task failed", [
                    "taskId": taskId.uuidString,
                    "error": error.localizedDescription
                ])

                await MainActor.run {
                    self.removeRecordingFile(audioURL, label: "failed imported recording")
                    self.publishFailure(
                        displayMessage: "Transcription failed",
                        diagnosticMessage: Self.safeFailureDiagnosticMessage(for: error)
                    )
                    self.sendFailureNotification(errorMessage: error.localizedDescription)
                    self.handleTaskCompletion(taskId: taskId)
                    self.scheduleStatusReset(delay: 4)
                }
            }
        }

        activeTasks[taskId] = asyncTask
    }

    public static func safeFailureDiagnosticMessage(for error: Error) -> String {
        if let pipelineError = error as? PipelineError {
            switch pipelineError {
            case .emptyAudioFile:
                return "Empty audio file"
            case .recordingTooShort:
                return "Recording too short"
            case .invalidAudioFormat:
                return "Invalid audio format"
            case .missingSystemAudio:
                return PipelineError.missingSystemAudio.localizedDescription
            case .modelNotLoaded(let model):
                return "\(model) model not loaded"
            case .modelInferenceFailed(let model, _):
                return "\(model) inference failed"
            case .saveFailed:
                return "Failed to save transcript"
            case .unknown(let underlying):
                return safeFailureDiagnosticMessage(forText: underlying)
            }
        }

        return safeFailureDiagnosticMessage(forText: error.localizedDescription)
    }

    private static func safeFailureDiagnosticMessage(forText message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("transcription already in progress") {
            return "Transcription already in progress"
        }

        if normalized.contains(anyOf: [
            "system audio is required",
            "system audio recording",
            "screen recording",
        ]) {
            return PipelineError.missingSystemAudio.localizedDescription
        }

        if normalized.contains(anyOf: [
            "recording too short",
            "at least 1 second",
            "at least 2 seconds",
            "at least one second",
            "at least two seconds",
        ]) && (normalized.contains("audio") || normalized.contains("recording")) {
            return "Recording too short"
        }

        if normalized.contains(anyOf: [
            "empty audio",
            "empty audio file",
            "no samples recorded",
        ]) {
            return "Empty audio file"
        }

        if normalized.contains(anyOf: [
            "invalid audio",
            "invalid audio data",
            "invalid audio format",
        ]) {
            return "Invalid audio format"
        }

        if normalized.contains(anyOf: [
            "failed to save",
            "could not write transcript",
            "permission denied",
        ]) {
            return "Failed to save transcript"
        }

        if normalized.contains(anyOf: [
            "model not loaded",
            "models were not ready",
            "model failed to load",
            "speech model failed to load",
        ]) {
            return "Model not loaded"
        }

        if normalized.contains(anyOf: [
            "pyannote",
            "sortformer",
            "wespeaker",
            "diarization",
        ]) {
            return "Diarization failed"
        }

        if normalized.contains(anyOf: [
            "asr",
            "core ml",
            "coreml",
            "failed to transcribe",
            "fluid",
            "inference",
            "mlmodel",
            "multiarray",
            "parakeet",
            "prediction",
            "preprocessor",
            "transcription failed",
            "whisper",
        ]) {
            return "Transcription inference failed"
        }

        return "Pipeline failed"
    }

    private func publishFailure(displayMessage: String, diagnosticMessage: String) {
        lastFailureDiagnosticMessage = diagnosticMessage
        displayStatus = .failed(message: displayMessage)
    }

    private func publishNonFailureStatus(_ status: DisplayStatus) {
        lastFailureDiagnosticMessage = nil
        displayStatus = status
    }

    func publishTranscriptSaved(from transcriptURL: URL) {
        populateSavedMetadata(from: transcriptURL)
        publishNonFailureStatus(.transcriptSaved)
        scheduleStatusReset(delay: 4)
    }

    public func addFailedTranscriptionRetainingAudio(
        micAudioURL: URL,
        systemAudioURL: URL?,
        errorMessage: String,
        taskId: UUID = UUID(),
        meetingTitle: String? = nil
    ) {
        _ = addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            taskId: taskId,
            meetingTitle: meetingTitle
        )
    }

    @discardableResult
    public func addFailedTranscriptionRetainingAvailableAudio(
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        taskId: UUID = UUID(),
        meetingTitle: String? = nil
    ) -> Bool {
        guard micAudioURL != nil || systemAudioURL != nil else {
            AppLogger.pipeline.error("No audio files available to retain for failed transcription", [
                "taskId": taskId.uuidString
            ])
            return false
        }

        let retainedAudio = archiveFailedRecordingAudioIfConfigured(
            micURL: micAudioURL,
            systemURL: systemAudioURL,
            taskId: taskId
        )
        return enqueueFailedTranscriptionAfterRetainingAudio(
            retainedAudio: retainedAudio,
            originalMicURL: micAudioURL,
            originalSystemURL: systemAudioURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle
        )
    }

    @discardableResult
    private func enqueueFailedTranscriptionAfterRetainingAudio(
        retainedAudio: RetainedRecordingAudio?,
        originalMicURL: URL?,
        originalSystemURL: URL?,
        errorMessage: String,
        meetingTitle: String?
    ) -> Bool {
        let failedSystemURL = retainedAudio?.systemURL ?? originalSystemURL
        let placeholderMicURL = makeSilentMicPlaceholderIfNeeded(
            retainedAudio: retainedAudio,
            hasOriginalMic: originalMicURL != nil,
            failedSystemURL: failedSystemURL
        )
        guard let failedMicURL = retainedAudio?.micURL ?? originalMicURL ?? placeholderMicURL else {
            AppLogger.pipeline.error("Failed transcription was not queued because no microphone track or placeholder is available")
            return false
        }

        let didPersist = failedTranscriptionManager.addFailedTranscription(
            micAudioURL: failedMicURL,
            systemAudioURL: failedSystemURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle
        )
        guard didPersist else { return false }

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

    private func makeSilentMicPlaceholderIfNeeded(
        retainedAudio: RetainedRecordingAudio?,
        hasOriginalMic: Bool,
        failedSystemURL: URL?
    ) -> URL? {
        guard !hasOriginalMic,
              let failedSystemURL else {
            return nil
        }

        let placeholderDirectory = retainedAudio?.directory ?? failedSystemURL.deletingLastPathComponent()
        let placeholderURL = placeholderDirectory
            .appendingPathComponent("microphone_placeholder")
            .appendingPathExtension("wav")
        do {
            try FileManager.default.createDirectory(
                at: placeholderDirectory,
                withIntermediateDirectories: true
            )
            try Self.writeSilentWAV(to: placeholderURL, duration: 2.5)
            FileManager.default.restrictToOwnerOnly(atPath: placeholderURL.path)
            AppLogger.pipeline.warning("Created silent microphone placeholder for system-only failed meeting audio")
            return placeholderURL
        } catch {
            AppLogger.pipeline.error("Failed to create silent microphone placeholder", [
                "error": error.localizedDescription
            ])
            return nil
        }
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
        let file = try AVAudioFile(
            forWriting: url,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        try file.write(from: buffer)
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
            self.publishNonFailureStatus(.gettingReady)
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
                splitLocalSpeakers: false,
                meetingTitle: failed.meetingTitle,
                sourceFailedTranscriptionId: failedId
            )

            AppLogger.pipeline.info("Retry successful", ["file": transcriptURL.lastPathComponent])

            await MainActor.run {
                let waitingForSpeakerNames = self.hasPendingSpeakerNamingRequest(sourceFailedTranscriptionId: failedId)
                if waitingForSpeakerNames {
                    AppLogger.pipeline.info("Retry transcript saved; keeping failed meeting until speaker names finalize", [
                        "failedId": failedId.uuidString
                    ])
                } else {
                    failedTranscriptionManager.removeFailedTranscription(id: failedId)
                }
                self.activeTasks.removeValue(forKey: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.publishTranscriptSaved(from: transcriptURL)
            }

            return true

        } catch {
            AppLogger.pipeline.error("Retry failed", ["error": "\(error.localizedDescription)"])
            await MainActor.run {
                self.activeTasks.removeValue(forKey: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.publishFailure(
                    displayMessage: "Retry failed",
                    diagnosticMessage: "Retry failed: \(Self.safeFailureDiagnosticMessage(for: error))"
                )
                self.scheduleStatusReset(delay: 8)
            }
            return false
        }
    }

    private func hasPendingSpeakerNamingRequest(sourceFailedTranscriptionId: UUID) -> Bool {
        speakerNamingRequest?.sourceFailedTranscriptionId == sourceFailedTranscriptionId
            || pendingSpeakerNamingRequests.contains {
                $0.sourceFailedTranscriptionId == sourceFailedTranscriptionId
            }
    }

    // MARK: - Task Completion & Cleanup

    func handleTaskCompletion(taskId: UUID) {
        activeTasks.removeValue(forKey: taskId)
        activeTaskAudio.removeValue(forKey: taskId)
        preservedTaskIdsForShutdown.remove(taskId)
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
        activeTaskAudio.removeAll()
        preservedTaskIdsForShutdown.removeAll()
        activeCount = 0
        backgroundTaskCount = 0
        publishNonFailureStatus(.idle)
    }

    @discardableResult
    public func preserveActiveTranscriptionsForShutdown(errorMessage: String) -> Int {
        let activeAudio = activeTaskAudio
        guard !activeAudio.isEmpty else { return 0 }

        for taskId in activeAudio.keys {
            preservedTaskIdsForShutdown.insert(taskId)
        }

        for (taskId, task) in activeTasks {
            task.cancel()
            AppLogger.pipeline.warning("Preserving active transcription audio during shutdown", [
                "taskId": taskId.uuidString
            ])
        }

        activeTasks.removeAll()
        activeTaskAudio.removeAll()
        activeCount = 0
        backgroundTaskCount = 0
        publishNonFailureStatus(.idle)

        var preservedCount = 0
        for (taskId, audio) in activeAudio {
            if addFailedTranscriptionRetainingAvailableAudio(
                micAudioURL: audio.micURL,
                systemAudioURL: audio.systemURL,
                errorMessage: errorMessage,
                taskId: taskId,
                meetingTitle: audio.meetingTitle
            ) {
                preservedCount += 1
            }
        }
        return preservedCount
    }

    /// Populate saved transcript metadata from the file's YAML frontmatter.
    /// Reads the YAML frontmatter in bounded chunks so larger metadata blocks
    /// (many speakers, gap events, etc.) still parse without reading the whole file.
    func populateSavedMetadata(from url: URL) {
        lastSavedTranscriptURL = url
        lastSavedTranscriptId = nil
        let name = url.deletingPathExtension().lastPathComponent
        lastSavedTitle = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let values = try? TranscriptFrontmatter.readValues(from: url) else { return }

        if let transcriptId = values["transcript_id"] {
            lastSavedTranscriptId = UUID(uuidString: transcriptId)
        }
        if let title = values["title"] {
            lastSavedTitle = title
        }
        lastSavedDuration = values["duration"]
        lastSavedSpeakerCount = (Int(values["mic_speakers"] ?? "") ?? 0)
            + (Int(values["system_speakers"] ?? "") ?? 0)
    }

    func scheduleStatusReset(delay: TimeInterval = 3) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            if self.speakerNamingRequest != nil {
                if case .transcriptSaved = self.displayStatus {
                    self.publishNonFailureStatus(.idle)
                }
                return
            }
            switch self.displayStatus {
            case .transcriptSaved, .failed:
                self.publishNonFailureStatus(.idle)
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

    nonisolated private static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    nonisolated private static func canonicalDirectoryURL(_ url: URL) -> URL {
        canonicalURL(url)
    }

    nonisolated private static func isFile(_ fileURL: URL, containedIn directoryURL: URL) -> Bool {
        let filePath = canonicalURL(fileURL).path
        let directoryPath = canonicalDirectoryURL(directoryURL).path
        let normalizedDirectoryPath = directoryPath.hasSuffix("/") ? directoryPath : directoryPath + "/"
        return filePath.hasPrefix(normalizedDirectoryPath)
    }

    private func archiveFailedRecordingAudioIfConfigured(
        micURL: URL?,
        systemURL: URL?,
        taskId: UUID
    ) -> RetainedRecordingAudio? {
        guard let retainedAudioDirectory = resolvedRetainedAudioDirectory() else { return nil }

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
}

private extension String {
    func contains(anyOf fragments: [String]) -> Bool {
        fragments.contains(where: contains)
    }
}
