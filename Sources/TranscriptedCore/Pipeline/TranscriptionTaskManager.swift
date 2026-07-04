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
    @Published public private(set) var lastSavedTranscriptTaskId: UUID? = nil
    @Published public var lastSavedTitle: String? = nil
    @Published public var lastSavedDuration: String? = nil
    @Published public var lastSavedSpeakerCount: Int? = nil
    @Published public private(set) var lastFailureDiagnosticMessage: String? = nil

    var lastSavedTranscriptId: UUID?
    private var savedTranscriptTaskIdsByTranscriptId: [UUID: UUID] = [:]
    private var savedTranscriptTaskIdsByURL: [URL: UUID] = [:]
    var activeTasks: [UUID: Task<Void, Never>] = [:]
    private var activeTaskAudio: [UUID: (micURL: URL?, systemURL: URL?, meetingTitle: String?, recordingDate: Date?)] = [:]
    private var preservedTaskIdsForShutdown: Set<UUID> = []
    private var intentionallyCancelledTaskIds: Set<UUID> = []
    private var committedTranscriptTaskIds: Set<UUID> = []
    var pendingSpeakerNamingRequests: [SpeakerNamingRequest] = []
    public let transcription: Transcription

    public let failedTranscriptionManager: FailedTranscriptionManager
    public let statsStore: (any StatsStore)?
    let retainedAudioDirectory: URL?
    private let retainedAudioDirectoryProvider: (() -> URL?)?
    private let transcriptFormatOptionsProvider: (() -> TranscriptFormatOptions)?
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
        transcriptFormatOptionsProvider: (() -> TranscriptFormatOptions)? = nil,
        statsStore: (any StatsStore)? = nil,
        notifier: TranscriptNotifier? = nil
    ) {
        self.failedTranscriptionManager = failedTranscriptionManager
        self.statsStore = statsStore
        self.notifier = notifier
        self.retainedAudioDirectory = retainedAudioDirectory
        self.retainedAudioDirectoryProvider = retainedAudioDirectoryProvider
        self.transcriptFormatOptionsProvider = transcriptFormatOptionsProvider
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
        taskId: UUID = UUID(),
        micURL: URL,
        systemURL: URL?,
        outputFolder: URL,
        healthInfo: RecordingHealthInfo? = nil,
        meetingTitle: String? = nil,
        splitLocalSpeakers: Bool = false,
        recordingDate: Date? = nil
    ) {

        // Guard: reject concurrent pipelines to prevent model contention
        if !activeTasks.isEmpty {
            AppLogger.pipeline.warning("Rejecting transcription — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            addFailedTranscriptionRetainingAudio(
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                errorMessage: "Transcription already in progress",
                meetingTitle: meetingTitle,
                recordingDate: recordingDate
            )
            publishFailure(
                displayMessage: "Transcription already in progress",
                diagnosticMessage: "Transcription already in progress"
            )
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
            id: taskId,
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            healthInfo: healthInfo,
            splitLocalSpeakers: splitLocalSpeakers,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate
        )

        activeCount += 1
        backgroundTaskCount += 1
        activeTaskAudio[task.id] = (
            micURL: micURL,
            systemURL: systemURL,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate
        )
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
                    meetingTitle: task.meetingTitle,
                    recordingDate: task.recordingDate
                )

                await MainActor.run {
                    guard !self.finishCancelledTaskIfNeeded(taskId: task.id) else { return }
                    self.publishTranscriptSaved(from: transcriptURL, taskId: task.id)
                    self.handleTaskCompletion(taskId: task.id)
                }

            } catch {
                AppLogger.pipeline.error("Transcription task failed", ["taskId": "\(task.id)", "error": "\(error.localizedDescription)"])

                await MainActor.run {
                    if self.preservedTaskIdsForShutdown.remove(task.id) != nil {
                        self.handleTaskCompletion(taskId: task.id)
                        return
                    }
                    guard !self.finishCancelledTaskIfNeeded(taskId: task.id, error: error) else { return }

                    self.publishFailure(
                        displayMessage: "Transcription failed",
                        diagnosticMessage: Self.safeFailureDiagnosticMessage(for: error)
                    )
                    self.addFailedTranscriptionRetainingAvailableAudio(
                        micAudioURL: micURL,
                        systemAudioURL: systemURL,
                        errorMessage: error.localizedDescription,
                        taskId: task.id,
                        meetingTitle: task.meetingTitle,
                        recordingDate: task.recordingDate
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
        meetingTitle: String? = nil,
        recordingDate: Date? = nil
    ) {
        if !activeTasks.isEmpty {
            AppLogger.pipeline.warning("Rejecting imported transcription — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            removeRecordingFile(audioURL, label: "rejected imported recording")
            publishFailure(
                displayMessage: "Another transcript is already running. Wait for it to finish, then import the file again.",
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
                displayMessage: "That audio file is too short to transcribe. Choose audio that is at least two seconds long.",
                diagnosticMessage: "Recording too short"
            )
            scheduleStatusReset(delay: 3)
            return
        }

        let taskId = UUID()
        activeCount += 1
        backgroundTaskCount += 1
        activeTaskAudio[taskId] = (
            micURL: audioURL,
            systemURL: nil,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate
        )
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
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate
                )

                await MainActor.run {
                    guard !self.finishCancelledTaskIfNeeded(taskId: taskId) else { return }
                    self.publishTranscriptSaved(from: transcriptURL, taskId: taskId)
                    self.handleTaskCompletion(taskId: taskId)
                }
            } catch {
                AppLogger.pipeline.error("Imported transcription task failed", [
                    "taskId": taskId.uuidString,
                    "error": error.localizedDescription
                ])

                await MainActor.run {
                    if self.preservedTaskIdsForShutdown.remove(taskId) != nil {
                        self.handleTaskCompletion(taskId: taskId)
                        return
                    }
                    if self.finishCancelledTaskIfNeeded(taskId: taskId, error: error) {
                        self.removeRecordingFile(audioURL, label: "cancelled imported recording")
                        return
                    }
                    self.removeRecordingFile(audioURL, label: "failed imported recording")
                    let diagnosticMessage = Self.safeFailureDiagnosticMessage(for: error)
                    self.publishFailure(
                        displayMessage: Self.importedAudioFailureDisplayMessage(forDiagnosticMessage: diagnosticMessage),
                        diagnosticMessage: diagnosticMessage
                    )
                    self.sendFailureNotification(errorMessage: error.localizedDescription)
                    self.handleTaskCompletion(taskId: taskId)
                    self.scheduleStatusReset(delay: 4)
                }
            }
        }

        activeTasks[taskId] = asyncTask
    }

    /// Re-transcribe audio retained beside an already-saved meeting transcript.
    /// Unlike live-capture scratch audio, the source files are user-facing retained
    /// artifacts, so this path never deletes them after success, failure, or rejection.
    public func startSavedAudioRetranscription(
        micURL: URL?,
        systemURL: URL,
        outputFolder: URL,
        meetingTitle: String? = nil,
        splitLocalSpeakers: Bool = false,
        replacementTranscriptURL: URL? = nil,
        recordingDate: Date? = nil,
        onReplacementTranscriptCommitted: (@MainActor @Sendable (URL) -> Void)? = nil
    ) {
        if !activeTasks.isEmpty {
            AppLogger.pipeline.warning("Rejecting saved-audio retranscription — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            publishFailure(
                displayMessage: "Another transcript is already running. Wait for it to finish, then try again.",
                diagnosticMessage: "Transcription already in progress"
            )
            scheduleStatusReset(delay: 4)
            return
        }

        let minDuration: TimeInterval = 2.0
        let micDuration = micURL.flatMap { audioDuration(url: $0) }
        let systemDuration = audioDuration(url: systemURL)
        let hasUsableMicAudio = micDuration.map { $0 >= minDuration } ?? false
        let hasUsableSystemAudio = systemDuration.map { $0 >= minDuration } ?? false
        let hasUnknownDuration = systemDuration == nil || (micURL != nil && micDuration == nil)

        guard hasUsableMicAudio || hasUsableSystemAudio || hasUnknownDuration else {
            AppLogger.pipeline.info("Saved audio too short, skipping retranscription", [
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? (micURL == nil ? "none" : "unknown"),
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? "unknown"
            ])
            publishFailure(
                displayMessage: "That saved audio is too short to transcribe again.",
                diagnosticMessage: "Recording too short"
            )
            scheduleStatusReset(delay: 3)
            return
        }

        let taskId = UUID()
        activeCount += 1
        backgroundTaskCount += 1
        publishNonFailureStatus(.gettingReady)

        AppLogger.pipeline.info("Starting saved-audio retranscription task", [
            "taskId": taskId.uuidString,
            "activeCount": "\(activeCount)",
            "hasMic": "\(micURL != nil)",
            "splitLocalSpeakers": "\(splitLocalSpeakers)"
        ])

        let asyncTask = Task {
            do {
                await MainActor.run {
                    self.publishNonFailureStatus(.transcribing(progress: 0.0))
                }

                let transcriptURL = try await self.transcribeMultichannelPipeline(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputFolder: outputFolder,
                    taskId: taskId,
                    healthInfo: nil,
                    splitLocalSpeakers: splitLocalSpeakers,
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    removeSourceAudioAfterArchive: false,
                    targetTranscriptURL: replacementTranscriptURL,
                    archiveRecordingAudio: replacementTranscriptURL == nil
                )

                await MainActor.run {
                    guard !self.finishCancelledTaskIfNeeded(taskId: taskId) else { return }
                    if replacementTranscriptURL != nil {
                        onReplacementTranscriptCommitted?(transcriptURL)
                    }
                    self.publishTranscriptSaved(from: transcriptURL, taskId: taskId)
                    self.handleTaskCompletion(taskId: taskId)
                }
            } catch {
                AppLogger.pipeline.error("Saved-audio retranscription task failed", [
                    "taskId": taskId.uuidString,
                    "error": error.localizedDescription
                ])

                await MainActor.run {
                    guard !self.finishCancelledTaskIfNeeded(taskId: taskId, error: error) else { return }
                    let diagnosticMessage = Self.safeFailureDiagnosticMessage(for: error)
                    self.publishFailure(
                        displayMessage: Self.savedAudioRetranscriptionFailureDisplayMessage(forDiagnosticMessage: diagnosticMessage),
                        diagnosticMessage: diagnosticMessage
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
            case .noSpeechDetected:
                return "No speech detected"
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
            "audio file is too short",
            "saved audio is too short",
            "audio is too short",
            "recording is too short",
            "too short to transcribe",
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
            "no speech detected",
            "no speech was found",
        ]) {
            return "No speech detected"
        }

        if normalized.contains(anyOf: [
            "invalid audio",
            "invalid audio data",
            "invalid audio format",
            "audio file has an invalid sample rate or channel count",
            "avaudiofile",
            "avfaudio error",
            "com.apple.coreaudio.avfaudio",
            "coreaudio error",
            "failed to create avaudioconverter",
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

    private static func importedAudioFailureDisplayMessage(forDiagnosticMessage message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("transcription already in progress") {
            return "Another transcript is already running. Wait for it to finish, then import the file again."
        }
        if normalized.contains("recording too short") {
            return "That audio file is too short to transcribe. Choose audio that is at least two seconds long."
        }
        if normalized.contains("empty audio file") {
            return "That audio file has no readable audio. Choose a different recording and try again."
        }
        if normalized.contains("no speech detected") {
            return "No speech was found in that audio file. Choose a file with clear spoken audio and try again."
        }
        if normalized.contains("invalid audio format") {
            return "Transcripted couldn't read that audio file. Choose a WAV, MP3, M4A, AAC, or AIFF file."
        }
        if normalized.contains("failed to save transcript") {
            return "Transcripted couldn't save the transcript. Check your capture folder and try again."
        }
        if normalized.contains("model not loaded") {
            return "The local transcription model was not ready. Try again after Models finishes loading."
        }
        if normalized.contains("diarization failed") {
            return "Transcripted couldn't separate speakers in that file. Try importing it again."
        }
        if normalized.contains("transcription inference failed") {
            return "The local transcription model couldn't process that file. Try converting it to WAV or M4A and import again."
        }

        return "Transcripted couldn't transcribe that audio file. Try converting it to WAV or M4A and import again."
    }

    static func savedAudioRetranscriptionFailureDisplayMessage(forDiagnosticMessage message: String) -> String {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("transcription already in progress") {
            return "Another transcript is already running. Wait for it to finish, then try again."
        }
        if normalized.contains("recording too short") {
            return "That saved audio is too short to transcribe again."
        }
        if normalized.contains("empty audio file") {
            return "That saved audio has no readable audio. Try another saved recording."
        }
        if normalized.contains("no speech detected") {
            return "No speech was found in that saved audio. Try a recording with clearer spoken audio."
        }
        if normalized.contains("invalid audio format") {
            return "Transcripted couldn't read that saved audio. Try another retained recording."
        }
        if normalized.contains("failed to save transcript") {
            return "Transcripted couldn't save the transcript. Check your capture folder and try again."
        }
        if normalized.contains("model not loaded") {
            return "The local transcription model was not ready. Try again after Models finishes loading."
        }
        if normalized.contains("diarization failed") {
            return "Transcripted couldn't separate speakers in that saved audio. Try again with the retained recording."
        }
        if normalized.contains("transcription inference failed") {
            return "The local transcription model couldn't process that saved audio. Try again, or start a new recording if the retained audio is damaged."
        }

        return "Transcripted couldn't re-transcribe that saved audio. Try again, or start a new recording if the retained audio is damaged."
    }

    private func publishFailure(displayMessage: String, diagnosticMessage: String) {
        lastFailureDiagnosticMessage = diagnosticMessage
        displayStatus = .failed(message: displayMessage)
    }

    private func publishNonFailureStatus(_ status: DisplayStatus) {
        lastFailureDiagnosticMessage = nil
        displayStatus = status
    }

    func publishTranscriptSaved(from transcriptURL: URL, taskId: UUID? = nil) {
        populateSavedMetadata(from: transcriptURL, taskId: taskId)
        publishNonFailureStatus(.transcriptSaved)
        scheduleStatusReset(delay: 4)
    }

    public func addFailedTranscriptionRetainingAudio(
        micAudioURL: URL,
        systemAudioURL: URL?,
        errorMessage: String,
        taskId: UUID = UUID(),
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        archiveAudio: Bool = true
    ) {
        _ = addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            taskId: taskId,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio
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

        let retryIsUsingOriginalAudio = activeTasks[id] != nil
        let promotedSystemAudioURL = systemAudioURL ?? existingFailure.systemAudioURL
        let didPersist = failedTranscriptionManager.updateFailedTranscriptionAudio(
            id: id,
            micAudioURL: micAudioURL,
            systemAudioURL: promotedSystemAudioURL
        )
        guard didPersist else { return false }

        scheduleFailedRecordingAudioArchive(
            micURL: micAudioURL,
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

    @discardableResult
    public func addFailedTranscriptionRetainingAvailableAudio(
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        taskId: UUID = UUID(),
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        archiveAudio: Bool = true
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
            removeOriginalsAfterArchive: false
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
        removeOriginalsAfterArchive: Bool
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
            id: taskId,
            micAudioURL: failedMicURL,
            systemAudioURL: failedSystemURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate
        )
        guard didPersist else {
            if let retainedAudio {
                removeRetainedFailedAudio(retainedAudio)
            }
            return false
        }

        // The failed-queue entry is durable — the crash-recovery journal next
        // to the original scratch audio is no longer needed.
        if let originalMicURL {
            MeetingRecordingJournalStore.removeJournal(forMicAudioURL: originalMicURL)
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

    // MARK: - Orphaned Recording Recovery

    /// Outcome of inspecting one leftover recording journal at launch.
    private struct OrphanedRecordingCandidate: Sendable {
        enum Disposition: Sendable {
            case stale(reason: String)
            case skip(reason: String)
            case recover(micURL: URL?, systemURL: URL?, startedAt: Date)
        }
        let journalURL: URL
        let disposition: Disposition
    }

    /// Audio files written within this window are treated as live: another
    /// Transcripted process (a dev build next to production) could be
    /// recording into the same scratch directory right now.
    nonisolated private static let orphanedRecordingLivenessWindow: TimeInterval = 120

    /// Scans the recordings scratch directory for journals left behind by a
    /// previous process and turns their audio into visible, retryable
    /// failed-queue entries. This is the only path that recovers a meeting
    /// whose preservation code never ran (crash, force-kill, power loss).
    @discardableResult
    public func recoverOrphanedRecordings(in scratchDirectory: URL) async -> Int {
        let candidates = await Task.detached(priority: .utility) {
            Self.collectOrphanedRecordingCandidates(in: scratchDirectory)
        }.value

        var recovered = 0
        for candidate in candidates {
            switch candidate.disposition {
            case .skip(let reason):
                AppLogger.pipeline.info("Left recording journal in place", [
                    "file": candidate.journalURL.lastPathComponent,
                    "reason": reason
                ])
            case .stale(let reason):
                try? FileManager.default.removeItem(at: candidate.journalURL)
                AppLogger.pipeline.info("Removed stale recording journal", [
                    "file": candidate.journalURL.lastPathComponent,
                    "reason": reason
                ])
            case .recover(let micURL, let systemURL, let startedAt):
                let didPersist = addFailedTranscriptionRetainingAvailableAudio(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: "Recording was interrupted before it could be saved. The recovered audio is ready to transcribe.",
                    recordingDate: startedAt,
                    archiveAudio: true
                )
                if didPersist {
                    try? FileManager.default.removeItem(at: candidate.journalURL)
                    recovered += 1
                    AppLogger.pipeline.info("Recovered orphaned recording into failed queue", [
                        "journal": candidate.journalURL.lastPathComponent,
                        "hasMic": "\(micURL != nil)",
                        "hasSystem": "\(systemURL != nil)"
                    ])
                }
            }
        }
        if !candidates.isEmpty {
            AppLogger.pipeline.info("Recording journal scan finished", [
                "journals": "\(candidates.count)",
                "recovered": "\(recovered)"
            ])
        }
        return recovered
    }

    nonisolated private static func collectOrphanedRecordingCandidates(in directory: URL) -> [OrphanedRecordingCandidate] {
        MeetingRecordingJournalStore.journalURLs(in: directory).compactMap {
            inspectOrphanedRecordingJournal(at: $0, directory: directory)
        }
    }

    nonisolated private static func inspectOrphanedRecordingJournal(
        at journalURL: URL,
        directory: URL
    ) -> OrphanedRecordingCandidate? {
        guard let journal = MeetingRecordingJournalStore.load(at: journalURL) else {
            return OrphanedRecordingCandidate(journalURL: journalURL, disposition: .stale(reason: "unreadable journal"))
        }

        // Journals store bare filenames; resolve them inside the scratch
        // directory only so a tampered journal cannot point recovery at
        // arbitrary files.
        func resolve(_ filename: String?) -> URL? {
            guard let filename, !filename.isEmpty,
                  !filename.contains("/"), !filename.contains("..") else { return nil }
            let url = directory.appendingPathComponent(filename)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        let primaryURL = resolve(journal.primaryMicFilename)
        let segmentRecords = journal.micSegments.compactMap { record -> MicRecordingSegment? in
            guard let url = resolve(record.filename) else { return nil }
            return MicRecordingSegment(url: url, gapBeforeDuration: record.gapBefore)
        }
        let systemURL = resolve(journal.systemAudioFilename)
        let finalURL = resolve(journal.finalMicFilename)
        let mergedSibling: URL? = journal.primaryMicFilename.flatMap { primaryName in
            resolve((primaryName as NSString).deletingPathExtension + "_merged.wav")
        }

        let allAudio = ([primaryURL, systemURL, finalURL, mergedSibling] + segmentRecords.map(\.url))
            .compactMap { $0 }
        guard !allAudio.isEmpty else {
            return OrphanedRecordingCandidate(journalURL: journalURL, disposition: .stale(reason: "no audio files remain"))
        }

        let liveCutoff = Date().addingTimeInterval(-orphanedRecordingLivenessWindow)
        for url in allAudio {
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if let modified = attributes?[.modificationDate] as? Date, modified > liveCutoff {
                return OrphanedRecordingCandidate(journalURL: journalURL, disposition: .skip(reason: "audio recently written"))
            }
        }

        // Crash-orphaned WAVs read as zero-length until their headers are repaired.
        for url in allAudio where url.pathExtension.lowercased() == "wav" {
            if (try? WAVHeaderRepair.repairIfNeeded(at: url)) == true {
                AppLogger.pipeline.info("Repaired orphaned recording WAV header", [
                    "file": url.lastPathComponent
                ])
            }
        }

        var micURL = finalURL ?? mergedSibling
        if micURL == nil, segmentRecords.count > 1 {
            micURL = (try? MicRecordingFileMerger.merge(
                primaryURL: primaryURL ?? segmentRecords[0].url,
                segments: segmentRecords
            ))?.url
        }
        if micURL == nil {
            micURL = primaryURL ?? segmentRecords.first?.url
        }

        guard micURL != nil || systemURL != nil else {
            return OrphanedRecordingCandidate(journalURL: journalURL, disposition: .stale(reason: "no usable audio"))
        }
        return OrphanedRecordingCandidate(
            journalURL: journalURL,
            disposition: .recover(micURL: micURL, systemURL: systemURL, startedAt: journal.startedAt)
        )
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
                _ = failedTranscriptionManager.removeFailedTranscription(id: failedId)
            }
            return false
        }

        AppLogger.pipeline.info("Retrying failed transcription", ["failedId": "\(failedId)"])

        // Register the retry work itself in activeTasks before the first suspension
        // point: startTranscription's `activeTasks.isEmpty` guard must block until the
        // retry finishes, and cancelAll() must reach the in-flight inference — so the
        // stored task has to be the one doing the work, not a placeholder.
        let outcome = RetryOutcome()
        let retryTask = Task { [weak self] in
            guard let self else { return }
            outcome.didPublish = await self.performRetry(
                failed: failed,
                failedId: failedId,
                outputFolder: outputFolder
            )
        }
        activeTasks[failedId] = retryTask
        await retryTask.value
        return outcome.didPublish
    }

    /// Mutable box that hands the retry's published result across the stored
    /// `Task<Void, Never>` boundary. Main-actor confined like the manager.
    private final class RetryOutcome {
        var didPublish = false
    }

    private func performRetry(
        failed: FailedTranscription,
        failedId: UUID,
        outputFolder: URL
    ) async -> Bool {
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
                recordingDate: failed.recordingDate ?? failed.timestamp,
                sourceFailedTranscriptionId: failedId
            )

            AppLogger.pipeline.info("Retry successful", ["file": transcriptURL.lastPathComponent])

            let didPublishRetry = await MainActor.run {
                guard !self.finishCancelledTaskIfNeeded(taskId: failedId) else { return false }

                let waitingForSpeakerNames = self.hasPendingSpeakerNamingRequest(sourceFailedTranscriptionId: failedId)
                self.removeSupersededRetrySourceAudioIfNeeded(
                    failedId: failedId,
                    micURL: failed.micAudioURL,
                    systemURL: failed.systemAudioURL
                )
                if waitingForSpeakerNames {
                    AppLogger.pipeline.info("Retry transcript saved; keeping failed meeting until speaker names finalize", [
                        "failedId": failedId.uuidString
                    ])
                } else {
                    failedTranscriptionManager.deleteFailedTranscription(id: failedId)
                }
                self.activeTasks.removeValue(forKey: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.publishTranscriptSaved(from: transcriptURL, taskId: failedId)
                return true
            }

            return didPublishRetry

        } catch {
            AppLogger.pipeline.error("Retry failed", ["error": "\(error.localizedDescription)"])
            let diagnosticMessage = "Retry failed: \(Self.safeFailureDiagnosticMessage(for: error))"
            await MainActor.run {
                guard !self.finishCancelledTaskIfNeeded(taskId: failedId, error: error) else { return }

                self.activeTasks.removeValue(forKey: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                failedTranscriptionManager.updateFailedTranscriptionError(
                    id: failedId,
                    errorMessage: diagnosticMessage
                )
                self.removeSupersededRetrySourceAudioIfNeeded(
                    failedId: failedId,
                    micURL: failed.micAudioURL,
                    systemURL: failed.systemAudioURL
                )
                self.publishFailure(
                    displayMessage: "Retry failed",
                    diagnosticMessage: diagnosticMessage
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

    private func removeSupersededRetrySourceAudioIfNeeded(
        failedId: UUID,
        micURL: URL,
        systemURL: URL?
    ) {
        guard let current = failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == failedId }) else {
            return
        }

        if current.micAudioURL != micURL {
            removeManagedCleanupFile(micURL, label: "superseded retry mic scratch")
        }
        if let systemURL, current.systemAudioURL != systemURL {
            removeManagedCleanupFile(systemURL, label: "superseded retry system scratch")
        }
    }

    // MARK: - Task Completion & Cleanup

    func handleTaskCompletion(taskId: UUID) {
        activeTasks.removeValue(forKey: taskId)
        activeTaskAudio.removeValue(forKey: taskId)
        preservedTaskIdsForShutdown.remove(taskId)
        intentionallyCancelledTaskIds.remove(taskId)
        committedTranscriptTaskIds.remove(taskId)
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

    func canCommitTaskSideEffects(taskId: UUID) -> Bool {
        activeTasks[taskId] != nil && !intentionallyCancelledTaskIds.contains(taskId)
    }

    func markTaskTranscriptCommitted(taskId: UUID) {
        committedTranscriptTaskIds.insert(taskId)
        // Transcript is durably on disk — the crash-recovery journal for this
        // recording's scratch audio is no longer needed.
        if let micURL = activeTaskAudio[taskId]?.micURL {
            MeetingRecordingJournalStore.removeJournal(forMicAudioURL: micURL)
        }
    }

    private func finishCancelledTaskIfNeeded(taskId: UUID, error: Error? = nil) -> Bool {
        if committedTranscriptTaskIds.contains(taskId) {
            intentionallyCancelledTaskIds.remove(taskId)
            AppLogger.pipeline.info("Preserving committed transcription task outcome after cancellation", [
                "taskId": "\(taskId)"
            ])
            return false
        }

        guard intentionallyCancelledTaskIds.contains(taskId) || error is CancellationError else {
            return false
        }

        intentionallyCancelledTaskIds.remove(taskId)
        let hadActiveTask = activeTasks.removeValue(forKey: taskId) != nil
        activeTaskAudio.removeValue(forKey: taskId)
        preservedTaskIdsForShutdown.remove(taskId)
        if hadActiveTask {
            activeCount = max(0, activeCount - 1)
            backgroundTaskCount = max(0, backgroundTaskCount - 1)
        }
        if activeCount == 0 {
            publishNonFailureStatus(.idle)
        }

        AppLogger.pipeline.info("Suppressed cancelled transcription task outcome", [
            "taskId": "\(taskId)",
            "remaining": "\(activeCount)",
            "backgroundTasks": "\(backgroundTaskCount)"
        ])
        return true
    }

    public func cancelAll() {
        for (taskId, task) in activeTasks {
            intentionallyCancelledTaskIds.insert(taskId)
            task.cancel()
            if let audio = activeTaskAudio[taskId] {
                removeManagedCleanupFile(audio.micURL, label: "cancelled live mic scratch")
                removeManagedCleanupFile(audio.systemURL, label: "cancelled live system scratch")
            }
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
                meetingTitle: audio.meetingTitle,
                recordingDate: audio.recordingDate
            ) {
                preservedCount += 1
            }
        }
        return preservedCount
    }

    /// Populate saved transcript metadata from the file's YAML frontmatter.
    /// Reads the YAML frontmatter in bounded chunks so larger metadata blocks
    /// (many speakers, gap events, etc.) still parse without reading the whole file.
    func populateSavedMetadata(from url: URL, taskId: UUID? = nil) {
        let previousTaskId = lastSavedTranscriptTaskId
        let previousURL = lastSavedTranscriptURL
        let previousTranscriptId = lastSavedTranscriptId
        let canonicalURL = Self.canonicalSavedTranscriptURL(url)

        lastSavedTranscriptTaskId = taskId
            ?? savedTranscriptTaskIdsByURL[canonicalURL]
            ?? (previousURL.map(Self.canonicalSavedTranscriptURL) == canonicalURL ? previousTaskId : nil)
        lastSavedTranscriptURL = url
        lastSavedTranscriptId = nil
        let name = url.deletingPathExtension().lastPathComponent
        lastSavedTitle = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let values = try? TranscriptFrontmatter.readValues(from: url) else {
            rememberSavedTranscriptOwner(taskId: lastSavedTranscriptTaskId, url: canonicalURL, transcriptId: nil)
            return
        }

        if let transcriptId = values["transcript_id"] {
            let parsedTranscriptId = UUID(uuidString: transcriptId)
            lastSavedTranscriptId = parsedTranscriptId
            if taskId == nil, let parsedTranscriptId {
                if let knownTaskId = savedTranscriptTaskIdsByTranscriptId[parsedTranscriptId] {
                    lastSavedTranscriptTaskId = knownTaskId
                } else if lastSavedTranscriptTaskId == nil,
                          previousTranscriptId == parsedTranscriptId {
                    lastSavedTranscriptTaskId = previousTaskId
                }
            }
        }
        rememberSavedTranscriptOwner(
            taskId: lastSavedTranscriptTaskId,
            url: canonicalURL,
            transcriptId: lastSavedTranscriptId
        )
        if let title = values["title"] {
            lastSavedTitle = title
        }
        lastSavedDuration = values["duration"]
        lastSavedSpeakerCount = (Int(values["mic_speakers"] ?? "") ?? 0)
            + (Int(values["system_speakers"] ?? "") ?? 0)
    }

    private static func canonicalSavedTranscriptURL(_ url: URL) -> URL {
        url.standardizedFileURL
    }

    private func rememberSavedTranscriptOwner(taskId: UUID?, url: URL, transcriptId: UUID?) {
        guard let taskId else { return }
        savedTranscriptTaskIdsByURL[url] = taskId
        if let transcriptId {
            savedTranscriptTaskIdsByTranscriptId[transcriptId] = taskId
        }
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

    func resolvedTranscriptFormatOptions(hasMicAudio: Bool, hasSystemAudio: Bool = true) -> TranscriptFormatOptions {
        var audioSources: [TranscriptAudioSource] = []
        if hasMicAudio {
            audioSources.append(.microphone)
        }
        if hasSystemAudio {
            audioSources.append(.systemAudio)
        }
        return (transcriptFormatOptionsProvider?() ?? .default)
            .withAudioSources(audioSources)
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

    private func scheduleFailedRecordingAudioArchive(
        micURL: URL?,
        systemURL: URL?,
        taskId: UUID,
        removeOriginalsAfterArchive: Bool,
        originalMicCleanupLabel: String,
        originalSystemCleanupLabel: String
    ) {
        guard let retainedAudioDirectory = resolvedRetainedAudioDirectory() else { return }

        let failedStem = "Failed_\(DateFormattingHelper.formatFilename(Date()))_\(String(taskId.uuidString.prefix(8)))"
        let placeholderTranscriptURL = retainedAudioDirectory
            .appendingPathComponent(failedStem)
            .appendingPathExtension("md")

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
        let placeholderMicURL = makeSilentMicPlaceholderIfNeeded(
            retainedAudio: retainedAudio,
            hasOriginalMic: micURL != nil,
            failedSystemURL: retainedAudio.systemURL ?? systemURL
        )
        guard let updatedMicURL = retainedAudio.micURL ?? micURL ?? placeholderMicURL else {
            removeRetainedFailedAudio(retainedAudio)
            return
        }
        let didPersist = failedTranscriptionManager.updateFailedTranscriptionAudio(
            id: taskId,
            micAudioURL: updatedMicURL,
            systemAudioURL: retainedAudio.systemURL ?? systemURL
        )

        guard didPersist else {
            removeRetainedFailedAudio(retainedAudio)
            return
        }

        guard removeOriginalsAfterArchive else { return }
        if retainedAudio.micURL != nil {
            removeManagedCleanupFile(micURL, label: originalMicCleanupLabel)
        }
        if retainedAudio.systemURL != nil {
            removeManagedCleanupFile(systemURL, label: originalSystemCleanupLabel)
        }
    }

    nonisolated private static func archiveFailedRecordingAudio(
        micURL: URL?,
        systemURL: URL?,
        taskId: UUID,
        transcriptURL: URL,
        archiveRoot: URL
    ) -> RetainedRecordingAudio? {
        do {
            let retainedAudio = try RecordingAudioArchiver.archive(
                micURL: micURL,
                systemURL: systemURL,
                transcriptURL: transcriptURL,
                archiveRoot: archiveRoot
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
}

private extension String {
    func contains(anyOf fragments: [String]) -> Bool {
        fragments.contains(where: contains)
    }
}
