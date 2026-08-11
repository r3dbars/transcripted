import Foundation
import AVFoundation

// MARK: - Transcription Task Queue & Orchestration
// Extensions in: SpeakerNamingCoordinator.swift, TranscriptionPipelineRunner.swift
// Types in: DisplayStatus.swift (DisplayStatus enum, TranscriptionTask struct)

@available(macOS 14.0, *)
@MainActor
public class TranscriptionTaskManager: ObservableObject {
    private struct ActiveTaskAudio {
        let micURL: URL?
        let systemURL: URL?
        let meetingTitle: String?
        let recordingDate: Date?
        let importedRecoverySession: (any ImportedTranscriptionRecoverySession)?
    }

    /// Every task tracked by this manager is in exactly one of these states by
    /// construction. This replaced four collections that used to be updated in
    /// lockstep, keyed by the same `UUID`, with fragile ordering requirements
    /// (`activeTaskAudio`, `preservedTaskIdsForShutdown`,
    /// `intentionallyCancelledTaskIds`, `committedTranscriptTaskIds`). See the
    /// combination-analysis in the PR description for how each case was derived
    /// from the reachable combinations of those four collections.
    ///
    /// `activeTasks: [UUID: Task<Void, Never>]` (the actual concurrency handle)
    /// stays a separate stored property rather than folding into this enum: it
    /// is directly poked by several test files (`manager.activeTasks[id] =
    /// sentinel`, `.removeValue(forKey:)`) as an occupancy-guard test seam, so
    /// collapsing it here would mean rewriting those direct pokes for no
    /// behavior change. `TaskLifecycleState` is looked up by the same `UUID`
    /// used as an `activeTasks` key; every key that appears in `activeTasks`
    /// should have a corresponding entry here, but the reverse is not always
    /// true (see `.preservedForShutdown`).
    private enum TaskLifecycleState {
        /// Running normally: not yet committed, cancelled, or preserved.
        /// `audio` is `nil` for saved-audio-retranscription and failed-row
        /// retry tasks, which reuse already-retained source files and were
        /// never entered into the old `activeTaskAudio` map either.
        case active(audio: ActiveTaskAudio?)

        /// `markTaskTranscriptCommitted(taskId:)` ran while the task was still
        /// occupying `activeTasks` (finishing speaker-naming / scratch-cleanup
        /// work after the transcript already saved). `audio` mirrors whatever
        /// the task started with — imported jobs still need
        /// `importedRecoverySession` after commit.
        case committed(audio: ActiveTaskAudio?)

        /// `cancelAll()` marked this task's outcome as intentionally
        /// cancelled. Audio (if any) was already synchronously discarded by
        /// `cancelAll()` before this state was entered.
        case cancelling

        /// `cancelAll()` raced a task whose side effects had *already*
        /// committed — reachable, not merely theoretical, because `cancelAll()`
        /// unconditionally marks every `activeTasks` key cancelled without
        /// checking commit state first. The marker is transient: the next
        /// `finishCancelledTaskIfNeeded` call collapses this back to
        /// `.committed` (dropping the cancel marker) so the task's own success
        /// path still runs and its outcome is preserved.
        case cancellingCommitted

        /// `preserveActiveTranscriptionsForShutdown()` already synchronously
        /// persisted this task's audio into the failed queue and evicted it
        /// from `activeTasks` and the occupancy counters. Only this marker
        /// remains so the still-running (uncooperative CoreML) task body can
        /// recognize its own outcome should be suppressed when it eventually
        /// returns. Deliberately has no associated `Task<Void, Never>` — by
        /// the time this case exists, `activeTasks` no longer has an entry for
        /// this id.
        ///
        /// `wasCommitted` carries forward whatever `isCommitted` was true at the
        /// moment of preservation. This is required, not decorative: on the old
        /// five-collection code, `committedTranscriptTaskIds` and
        /// `preservedTaskIdsForShutdown` were independent `Set`s, so a task that
        /// committed *before* shutdown kept its committed membership even after
        /// `cancelAll()` later wiped `preservedTaskIdsForShutdown` with its own
        /// unconditional `.removeAll()` — `finishCancelledTaskIfNeeded` would
        /// still see `committedTranscriptTaskIds.contains(taskId) == true` and
        /// give the committed outcome precedence over the task's own
        /// `CancellationError`. Collapsing to a payload-less `.preservedForShutdown`
        /// would silently lose that precedence the moment `cancelAll()` clears the
        /// marker. See `cancelAll()`'s handling of this case.
        case preservedForShutdown(wasCommitted: Bool)

        var audio: ActiveTaskAudio? {
            switch self {
            case .active(let audio), .committed(let audio):
                return audio
            case .cancelling, .cancellingCommitted, .preservedForShutdown:
                return nil
            }
        }

        var isCommitted: Bool {
            switch self {
            case .committed, .cancellingCommitted:
                return true
            case .preservedForShutdown(let wasCommitted):
                return wasCommitted
            case .active, .cancelling:
                return false
            }
        }

        var isCancelling: Bool {
            switch self {
            case .cancelling, .cancellingCommitted:
                return true
            case .active, .committed, .preservedForShutdown:
                return false
            }
        }
    }

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
    @Published public private(set) var lastFailureErrorKind: PipelineErrorKind? = nil

    var lastSavedTranscriptId: UUID?
    private var savedTranscriptTaskIdsByTranscriptId: [UUID: UUID] = [:]
    private var savedTranscriptTaskIdsByURL: [URL: UUID] = [:]
    var activeTasks: [UUID: Task<Void, Never>] = [:]
    /// Single source of truth for everything the old `activeTaskAudio` /
    /// `preservedTaskIdsForShutdown` / `intentionallyCancelledTaskIds` /
    /// `committedTranscriptTaskIds` collections tracked. See
    /// `TaskLifecycleState` for the combination analysis.
    private var tasks: [UUID: TaskLifecycleState] = [:]
    var pendingSpeakerNamingRequests: [SpeakerNamingRequest] = []
    public let transcription: Transcription

    public let failedTranscriptionManager: FailedTranscriptionManager
    public let statsStore: (any StatsStore)?
    let retainedAudioDirectory: URL?
    private let retainedAudioDirectoryProvider: (() -> URL?)?
    private let transcriptFormatOptionsProvider: (() -> TranscriptFormatOptions)?
    private let cleanupDirectories: [URL]
    private var orphanedRecordingRecoveryTask: Task<Int, Never>?
    private var orphanedRecordingRecoveryRequestGeneration: UInt64 = 0
    /// Deterministic task-start delay point for recovery scheduler tests.
    var orphanedRecordingRecoveryTaskCreatedObserver: (() -> Void)?
    /// Deterministic pause point for recovery interleaving tests.
    var orphanedRecordingRecoveryPassObserver: (() -> Void)?

    /// Embedder-supplied notifier for transcript-saved and failure events. Optional — when
    /// `nil`, notification hooks become no-ops, which keeps Core usable from headless contexts
    /// (tests, CLI tools) and embedders that prefer their own in-app presentation.
    public let notifier: TranscriptNotifier?

    public var hasPreservableActiveTranscriptionAudio: Bool {
        tasks.values.contains { state in
            guard let audio = state.audio else { return false }
            return audio.micURL != nil || audio.systemURL != nil
        }
    }

    /// Active pipeline work that should keep quit confirmation enabled.
    ///
    /// Saved-audio retranscriptions and failed-row retries use already-retained
    /// source files, so they intentionally do not enter `activeTaskAudio`. They
    /// still need the background-work quit warning while inference is running.
    /// Conversely, `cancelAll()` leaves non-cooperative model work in
    /// `activeTasks` for single-flight occupancy, but marks it intentionally
    /// cancelled after discarding any owned scratch audio. That cancelled
    /// occupancy must not revive a misleading save-audio prompt.
    public var hasActiveTranscriptionWorkRequiringQuitConfirmation: Bool {
        activeTasks.keys.contains { !(tasks[$0]?.isCancelling ?? false) }
    }

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
        micURL: URL?,
        systemURL: URL?,
        outputFolder: URL,
        healthInfo: RecordingHealthInfo? = nil,
        meetingTitle: String? = nil,
        splitLocalSpeakers: Bool = false,
        recordingDate: Date? = nil
    ) {

        guard micURL != nil || systemURL != nil else {
            publishFailure(
                displayMessage: "No meeting audio was captured",
                diagnosticMessage: "No meeting audio files were available"
            )
            scheduleStatusReset(delay: 4)
            return
        }

        // Guard: reject concurrent pipelines to prevent model contention
        if !activeTasks.isEmpty {
            AppLogger.pipeline.warning("Rejecting transcription — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            addFailedTranscriptionRetainingAvailableAudio(
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
        let micDuration = micURL.flatMap { audioDuration(url: $0) }
        let systemDuration = systemURL.flatMap { audioDuration(url: $0) }
        let hasUsableMicAudio = micDuration.map { $0 >= minDuration } ?? false
        let hasUsableSystemAudio = systemDuration.map { $0 >= minDuration } ?? false
        let hasUnknownDuration = (micURL != nil && micDuration == nil)
            || (systemURL != nil && systemDuration == nil)

        guard hasUsableMicAudio || hasUsableSystemAudio || hasUnknownDuration else {
            AppLogger.pipeline.info("Recording too short, skipping transcription", [
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? (micURL == nil ? "none" : "unknown"),
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? "none"
            ])

            if let micURL {
                removeRecordingFile(micURL, label: "short mic recording")
            }
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
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? (micURL == nil ? "none" : "unknown"),
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? (systemURL == nil ? "none" : "unknown")
            ])
        }

        if !hasUsableMicAudio, hasUsableSystemAudio {
            AppLogger.pipeline.warning("Proceeding without usable mic audio because system audio is still usable", [
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? (micURL == nil ? "none" : "unknown"),
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? "unknown"
            ])
        }

        let effectiveHealthInfo = micURL == nil && systemURL != nil
            ? (healthInfo ?? .perfect).markingMicrophoneAudioUnusable()
            : healthInfo
        let task = TranscriptionTask(
            id: taskId,
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            healthInfo: effectiveHealthInfo,
            splitLocalSpeakers: splitLocalSpeakers,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate
        )

        activeCount += 1
        backgroundTaskCount += 1
        tasks[task.id] = .active(audio: ActiveTaskAudio(
            micURL: micURL,
            systemURL: systemURL,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            importedRecoverySession: nil
        ))
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

                // Computed once, here, while the typed error is still in hand — threaded
                // through to both the live display state and the persisted failed-queue
                // row so downstream classifiers don't have to re-derive it from strings.
                let errorKind = Self.failureKind(for: error)

                let shouldPreserveFailedAudio = await MainActor.run { () -> Bool in
                    if self.consumePreservedForShutdownMarker(taskId: task.id) {
                        self.handleTaskCompletion(taskId: task.id)
                        return false
                    }
                    guard !self.finishCancelledTaskIfNeeded(taskId: task.id, error: error) else { return false }

                    self.publishFailure(
                        displayMessage: "Transcription failed",
                        diagnosticMessage: Self.safeFailureDiagnosticMessage(for: error),
                        errorKind: errorKind
                    )
                    return true
                }

                guard shouldPreserveFailedAudio else { return }

                _ = await self.addFailedTranscriptionRetainingAvailableAudioAfterArchive(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: error.localizedDescription,
                    taskId: task.id,
                    meetingTitle: task.meetingTitle,
                    recordingDate: task.recordingDate,
                    errorKind: errorKind
                )

                await MainActor.run {
                    self.sendFailureNotification(errorMessage: error.localizedDescription)
                    self.handleTaskCompletion(taskId: task.id)
                }
            }
        }

        activeTasks[task.id] = asyncTask
    }

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
        errorKind: PipelineErrorKind? = nil
    ) async -> Bool {
        guard micAudioURL != nil || systemAudioURL != nil else {
            AppLogger.pipeline.error("No audio files available to retain for failed transcription", [
                "taskId": taskId.uuidString
            ])
            return false
        }

        if archiveAudio,
           let retainedAudioDirectory = resolvedRetainedAudioDirectory() {
            let failedStem = "Failed_\(DateFormattingHelper.formatFilename(Date()))_\(String(taskId.uuidString.prefix(8)))"
            let placeholderTranscriptURL = retainedAudioDirectory
                .appendingPathComponent(failedStem)
                .appendingPathExtension("md")

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
                    errorKind: errorKind
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
            errorKind: errorKind
        )
    }

    /// Start a new transcription task for an imported audio file.
    /// Imported files reuse the system-audio speaker path and are not added to the
    /// failed-transcription queue because the user can simply re-import the source file.
    public func startImportedTranscription(
        taskId: UUID = UUID(),
        audioURL: URL,
        outputFolder: URL,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        recoverySession: (any ImportedTranscriptionRecoverySession)? = nil
    ) {
        precondition(
            recoverySession == nil || recoverySession?.jobID == taskId,
            "Imported recovery session must use the queued job identity"
        )
        if !activeTasks.isEmpty {
            AppLogger.pipeline.warning("Rejecting imported transcription — another pipeline is already active", ["activeCount": "\(activeTasks.count)"])
            if removeImportedRecordingFile(
                audioURL,
                recoverySession: recoverySession,
                label: "rejected imported recording"
            ) {
                recoverySession?.scratchCleanupConfirmed()
            }
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
            if removeImportedRecordingFile(
                audioURL,
                recoverySession: recoverySession,
                label: "short imported recording"
            ) {
                recoverySession?.scratchCleanupConfirmed()
            }
            publishFailure(
                displayMessage: "That audio file is too short to transcribe. Choose audio that is at least two seconds long.",
                diagnosticMessage: "Recording too short"
            )
            scheduleStatusReset(delay: 3)
            return
        }

        activeCount += 1
        backgroundTaskCount += 1
        tasks[taskId] = .active(audio: ActiveTaskAudio(
            micURL: audioURL,
            systemURL: nil,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            importedRecoverySession: recoverySession
        ))
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
                    if self.consumePreservedForShutdownMarker(taskId: taskId) {
                        self.handleTaskCompletion(taskId: taskId)
                        return
                    }
                    if self.finishCancelledTaskIfNeeded(taskId: taskId, error: error) {
                        if self.removeImportedRecordingFile(
                            audioURL,
                            recoverySession: recoverySession,
                            label: "cancelled imported recording"
                        ) {
                            recoverySession?.scratchCleanupConfirmed()
                        }
                        return
                    }
                    if self.removeImportedRecordingFile(
                        audioURL,
                        recoverySession: recoverySession,
                        label: "failed imported recording"
                    ) {
                        recoverySession?.scratchCleanupConfirmed()
                    }
                    self.publishFailure(Self.failurePresentation(for: error, flow: .importedAudio))
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

        if let replacementTranscriptURL {
            guard TranscriptSaver.beginReplacingTranscript(at: replacementTranscriptURL) else {
                publishFailure(
                    displayMessage: "That meeting is already being re-transcribed.",
                    diagnosticMessage: "Replacement transcript already in progress"
                )
                scheduleStatusReset(delay: 4)
                return
            }
        }

        let taskId = UUID()
        activeCount += 1
        backgroundTaskCount += 1
        // Saved-audio retranscriptions and failed-row retries reuse already-retained
        // source files, so — like the old `activeTaskAudio` map — this intentionally
        // carries no audio: there is nothing to preserve on shutdown or discard on cancel.
        tasks[taskId] = .active(audio: nil)
        publishNonFailureStatus(.gettingReady)

        AppLogger.pipeline.info("Starting saved-audio retranscription task", [
            "taskId": taskId.uuidString,
            "activeCount": "\(activeCount)",
            "hasMic": "\(micURL != nil)",
            "splitLocalSpeakers": "\(splitLocalSpeakers)"
        ])

        let asyncTask = Task {
            defer {
                if let replacementTranscriptURL {
                    TranscriptSaver.finishReplacingTranscript(at: replacementTranscriptURL)
                }
            }

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
                    self.publishFailure(Self.failurePresentation(for: error, flow: .savedAudioRetranscription))
                    self.sendFailureNotification(errorMessage: error.localizedDescription)
                    self.handleTaskCompletion(taskId: taskId)
                    self.scheduleStatusReset(delay: 4)
                }
            }
        }

        activeTasks[taskId] = asyncTask
    }

    public static func safeFailureDiagnosticMessage(for error: Error) -> String {
        failureClassification(for: error).message
    }

    /// Everything a failure call site publishes for a thrown pipeline error,
    /// derived from one classification pass.
    struct FailurePresentation {
        let displayMessage: String
        let diagnosticMessage: String
        /// The narrow typed kind that gets PERSISTED — see `failureKind(for:)`.
        /// nil for anything that didn't arrive as a genuine typed `PipelineError`,
        /// even though `displayMessage` still uses the broad text classification.
        let errorKind: PipelineErrorKind?
    }

    /// Classifies `error` once and routes the resulting `PipelineErrorKind`
    /// through the per-flow `PipelineFailureDisplayCopy` table, instead of
    /// re-deriving the failure bucket by string-matching the diagnostic
    /// message it just produced.
    ///
    /// One deliberate behavior change from the old string-matching chains:
    /// a typed `PipelineError.modelInferenceFailed` produces the diagnostic
    /// "<model> inference failed", which the old chains failed to match
    /// (they only looked for "transcription inference failed"), silently
    /// dropping typed inference failures to the generic fallback copy. The
    /// kind-routed table now shows the inference-specific copy for both the
    /// typed and text-classified paths.
    static func failurePresentation(for error: Error, flow: PipelineFailureDisplayCopy.Flow) -> FailurePresentation {
        let classification = failureClassification(for: error)
        return FailurePresentation(
            displayMessage: PipelineFailureDisplayCopy.message(for: classification.kind, flow: flow),
            diagnosticMessage: classification.message,
            errorKind: failureKind(for: error)
        )
    }

    /// Typed classification to PERSIST as `FailedTranscription.errorKind` —
    /// deliberately narrower than `safeFailureDiagnosticMessage(for:)`.
    ///
    /// This only returns non-nil when `error` is a genuine `PipelineError`
    /// case with the typed error actually in hand (excluding `.unknown`,
    /// which just wraps free text). Every other error — including any
    /// `PipelineError.unknown` — returns nil here, even though
    /// `safeFailureDiagnosticMessage` classifies a much broader set of
    /// free-form `NSError`/`localizedDescription` text for the *display*
    /// message. That broad text net must never leak into what gets
    /// persisted as `errorKind`: `FailedTranscription.isRetryable` and
    /// `MeetingFailureKind` trust `errorKind` over the legacy string
    /// fallback, and the legacy fallback's keyword net (in
    /// `FailedTranscription.legacyPipelineError` / `MeetingFailureKind
    /// .classify(message:)`) is intentionally much narrower than the
    /// display-message net — e.g. a raw CoreAudio `-50` NSError's
    /// description contains "avfaudio"/"coreaudio", which the display-message
    /// fallback recognizes as invalid-audio-format, but which the legacy
    /// retry-classification net does not, so on `main` that failure stayed
    /// retryable and bucketed as unexpected rather than becoming permanently
    /// non-retryable. Returning nil here for text-routed errors preserves
    /// that behavior: the caller keeps using the (unchanged) legacy fallback
    /// for anything that didn't arrive as a typed `PipelineError`.
    public static func failureKind(for error: Error) -> PipelineErrorKind? {
        guard let pipelineError = error as? PipelineError else { return nil }
        switch pipelineError {
        case .emptyAudioFile:
            return .emptyAudioFile
        case .microphoneAudioUnusable:
            return .microphoneAudioUnusable
        case .noSpeechDetected:
            return .noSpeechDetected
        case .recordingTooShort:
            return .recordingTooShort
        case .invalidAudioFormat:
            return .invalidAudioFormat
        case .missingSystemAudio:
            return .missingSystemAudio
        case .modelNotLoaded:
            return .modelNotLoaded
        case .modelInferenceFailed:
            // NOTE: legacy text classification would bucket an underlying
            // message naming a diarization model (e.g. "PyAnnote") as
            // `.diarizationFailed` instead. No current throw site passes a
            // diarization model name through `.modelInferenceFailed` — every
            // call site here is a transcription-model failure — so this is a
            // latent divergence, not an active one. If a diarization engine
            // ever starts throwing `.modelInferenceFailed`, this should
            // switch on the model name the same way the legacy text path
            // does, rather than assuming transcription.
            return .transcriptionInferenceFailed
        case .saveFailed:
            return .saveFailed
        case .unknown:
            // Free text wrapped in a PipelineError case, not a real typed
            // classification — treat it like any other untyped error.
            return nil
        }
    }

    /// Backs `safeFailureDiagnosticMessage(for:)` and the display-copy routing
    /// in `failurePresentation(for:flow:)`. Its `kind` half is the BROAD
    /// display classification — it is deliberately NOT the source of
    /// `failureKind(for:)` above, which uses its own narrower, typed-only
    /// switch instead of this text-inclusive one.
    private static func failureClassification(for error: Error) -> (kind: PipelineErrorKind, message: String) {
        if let pipelineError = error as? PipelineError {
            switch pipelineError {
            case .emptyAudioFile:
                return (.emptyAudioFile, "Empty audio file")
            case .microphoneAudioUnusable:
                return (.microphoneAudioUnusable, "Microphone audio was not usable")
            case .noSpeechDetected:
                return (.noSpeechDetected, "No speech detected")
            case .recordingTooShort:
                return (.recordingTooShort, "Recording too short")
            case .invalidAudioFormat:
                return (.invalidAudioFormat, "Invalid audio format")
            case .missingSystemAudio:
                return (.missingSystemAudio, PipelineError.missingSystemAudio.localizedDescription)
            case .modelNotLoaded(let model):
                return (.modelNotLoaded, "\(model) model not loaded")
            case .modelInferenceFailed(let model, _):
                // Assumes transcription, like failureKind(for:) — see the NOTE
                // there about the latent diarization-model-name divergence from
                // the legacy text net. Display copy inherits the same assumption.
                return (.transcriptionInferenceFailed, "\(model) inference failed")
            case .saveFailed:
                return (.saveFailed, "Failed to save transcript")
            case .unknown(let underlying):
                return failureClassification(forText: underlying)
            }
        }

        return failureClassification(forText: error.localizedDescription)
    }

    private static func failureClassification(forText message: String) -> (kind: PipelineErrorKind, message: String) {
        let normalized = message.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if normalized.contains("transcription already in progress") {
            return (.transcriptionAlreadyInProgress, "Transcription already in progress")
        }

        if normalized.contains(anyOf: [
            "system audio is required",
            "system audio recording",
            "screen recording",
        ]) {
            return (.missingSystemAudio, PipelineError.missingSystemAudio.localizedDescription)
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
            return (.recordingTooShort, "Recording too short")
        }

        if normalized.contains(anyOf: [
            "empty audio",
            "empty audio file",
            "no samples recorded",
        ]) {
            return (.emptyAudioFile, "Empty audio file")
        }

        if normalized.contains(anyOf: [
            "no speech detected",
            "no speech was found",
        ]) {
            return (.noSpeechDetected, "No speech detected")
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
            return (.invalidAudioFormat, "Invalid audio format")
        }

        if normalized.contains(anyOf: [
            "failed to save",
            "could not write transcript",
            "permission denied",
        ]) {
            return (.saveFailed, "Failed to save transcript")
        }

        if normalized.contains(anyOf: [
            "model not loaded",
            "models were not ready",
            "model failed to load",
            "speech model failed to load",
        ]) {
            return (.modelNotLoaded, "Model not loaded")
        }

        if normalized.contains(anyOf: [
            "pyannote",
            "sortformer",
            "wespeaker",
            "diarization",
        ]) {
            return (.diarizationFailed, "Diarization failed")
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
            return (.transcriptionInferenceFailed, "Transcription inference failed")
        }

        return (.pipelineFailed, "Pipeline failed")
    }

    // Text-based display-copy entry points, kept only for diagnostic strings
    // that arrive without the original error in hand. The production failure
    // paths classify the thrown error directly via `failurePresentation(for:flow:)`;
    // these reuse the same text classifier + kind table rather than a separate
    // string-matching chain.

    static func importedAudioFailureDisplayMessage(forDiagnosticMessage message: String) -> String {
        PipelineFailureDisplayCopy.message(for: failureClassification(forText: message).kind, flow: .importedAudio)
    }

    static func savedAudioRetranscriptionFailureDisplayMessage(forDiagnosticMessage message: String) -> String {
        PipelineFailureDisplayCopy.message(for: failureClassification(forText: message).kind, flow: .savedAudioRetranscription)
    }

    private func publishFailure(_ failure: FailurePresentation) {
        publishFailure(
            displayMessage: failure.displayMessage,
            diagnosticMessage: failure.diagnosticMessage,
            errorKind: failure.errorKind
        )
    }

    private func publishFailure(displayMessage: String, diagnosticMessage: String, errorKind: PipelineErrorKind? = nil) {
        lastFailureDiagnosticMessage = diagnosticMessage
        lastFailureErrorKind = errorKind
        displayStatus = .failed(message: displayMessage)
    }

    private func publishNonFailureStatus(_ status: DisplayStatus) {
        lastFailureDiagnosticMessage = nil
        lastFailureErrorKind = nil
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
        archiveAudio: Bool = true,
        errorKind: PipelineErrorKind? = nil
    ) {
        _ = addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            taskId: taskId,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio,
            errorKind: errorKind
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
        errorKind: PipelineErrorKind? = nil
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
            errorKind: errorKind
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
        errorKind: PipelineErrorKind? = nil
    ) -> Bool {
        let retainedMicURL = existingAudioURL(retainedAudio?.micURL)
        let retainedSystemURL = existingAudioURL(retainedAudio?.systemURL)
        let originalMicURLForRetry = existingAudioURL(originalMicURL)
        let originalSystemURLForRetry = existingAudioURL(originalSystemURL)
        let pendingOriginalSystemURL = retainedAudio == nil ? originalSystemURL : nil
        let failedSystemURL = retainedSystemURL ?? originalSystemURLForRetry ?? pendingOriginalSystemURL
        let placeholderSystemURL = retainedSystemURL ?? originalSystemURLForRetry
        let placeholderMicURL = makeSilentMicPlaceholderIfNeeded(
            retainedAudio: retainedAudio,
            hasOriginalMic: originalMicURLForRetry != nil,
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
            errorKind: errorKind
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

    // MARK: - Orphaned Recording Recovery

    /// Outcome of inspecting one leftover recording journal at launch.
    private struct OrphanedRecordingCandidate: Sendable {
        enum Disposition: Sendable {
            case stale(reason: String)
            case skip(reason: String, retryAfter: TimeInterval?)
            case recover(
                micURL: URL?,
                systemURL: URL?,
                originalMicURL: URL?,
                startedAt: Date
            )
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
        await recoverOrphanedRecordings(
            in: scratchDirectory,
            livenessWindow: Self.orphanedRecordingLivenessWindow,
            waitForRecentJournals: true
        )
    }

    @discardableResult
    func recoverOrphanedRecordings(
        in scratchDirectory: URL,
        livenessWindow: TimeInterval,
        waitForRecentJournals: Bool
    ) async -> Int {
        orphanedRecordingRecoveryRequestGeneration &+= 1
        if let activeRecovery = orphanedRecordingRecoveryTask {
            return await activeRecovery.value
        }

        // One monotonic deadline belongs to the single-flight owner. Joined
        // requests can ask it to rescan, but cannot extend its lifetime.
        let maximumWaitInterval = max(0.02, (livenessWindow * 2) + 0.02)
        let recoveryTask = Task { [weak self] in
            guard let self else { return 0 }
            // Start the budget when the stored owner actually begins running.
            // A busy MainActor must not consume the entire recovery window
            // before the first directory scan has even started.
            let waitDeadline = ContinuousClock.now.advanced(
                by: .seconds(maximumWaitInterval)
            )
            var totalRecovered = 0
            while ContinuousClock.now < waitDeadline {
                let ownerRequestGeneration = self.orphanedRecordingRecoveryRequestGeneration
                totalRecovered += await self.performOrphanedRecordingRecovery(
                    in: scratchDirectory,
                    livenessWindow: livenessWindow,
                    waitForRecentJournals: waitForRecentJournals,
                    waitDeadline: waitDeadline
                )
                if self.orphanedRecordingRecoveryRequestGeneration == ownerRequestGeneration {
                    break
                }
            }
            self.orphanedRecordingRecoveryTask = nil
            return totalRecovered
        }
        orphanedRecordingRecoveryTask = recoveryTask
        orphanedRecordingRecoveryTaskCreatedObserver?()
        return await recoveryTask.value
    }

    private func performOrphanedRecordingRecovery(
        in scratchDirectory: URL,
        livenessWindow: TimeInterval,
        waitForRecentJournals: Bool,
        waitDeadline: ContinuousClock.Instant
    ) async -> Int {
        let canonicalScratchDirectory = Self.canonicalDirectoryURL(scratchDirectory)
        guard cleanupDirectories.contains(where: { root in
            canonicalScratchDirectory == root
                || Self.isFile(canonicalScratchDirectory, containedIn: root)
        }) else {
            AppLogger.pipeline.warning("Refused recording journal recovery outside managed storage")
            return 0
        }
        var totalRecovered = 0
        while !Task.isCancelled {
            let passRequestGeneration = orphanedRecordingRecoveryRequestGeneration
            let candidates = await Task.detached(priority: .utility) {
                Self.collectOrphanedRecordingCandidates(
                    in: canonicalScratchDirectory,
                    now: Date(),
                    livenessWindow: livenessWindow
                )
            }.value
            orphanedRecordingRecoveryPassObserver?()
            await Task.yield()

            var passRecovered = 0
            var retryAfter: TimeInterval?
            for candidate in candidates {
                switch candidate.disposition {
                case .skip(let reason, let candidateRetryAfter):
                    if let candidateRetryAfter {
                        retryAfter = min(retryAfter ?? candidateRetryAfter, candidateRetryAfter)
                    }
                    AppLogger.pipeline.info("Left recording journal in place", [
                        "file": candidate.journalURL.lastPathComponent,
                        "reason": reason
                    ])
                case .stale(let reason):
                    let didRemoveJournal = MeetingRecordingJournalStore.removeJournalArtifact(
                        at: candidate.journalURL,
                        allowedRoots: [canonicalScratchDirectory]
                    )
                    AppLogger.pipeline.info(didRemoveJournal
                        ? "Removed stale recording journal"
                        : "Left stale recording journal in place", [
                        "file": candidate.journalURL.lastPathComponent,
                        "reason": reason
                    ])
                case .recover(let micURL, let systemURL, let originalMicURL, let startedAt):
                    let existingFailure = failedTranscriptionManager.failedTranscriptions.first { failure in
                        failure.micAudioURL.standardizedFileURL == originalMicURL?.standardizedFileURL
                            || failure.micAudioURL.standardizedFileURL == micURL?.standardizedFileURL
                            || (systemURL.map {
                                failure.systemAudioURL?.standardizedFileURL == $0.standardizedFileURL
                            } == true)
                    }
                    let didPersist: Bool
                    if let existingFailure {
                        let recoveredMicURL = micURL ?? existingFailure.micAudioURL
                        didPersist = promoteFinalizedFailedTranscriptionAudio(
                            id: existingFailure.id,
                            micAudioURL: recoveredMicURL,
                            systemAudioURL: systemURL ?? existingFailure.systemAudioURL
                        )
                    } else {
                        let availableAudioURLs = [micURL, systemURL].compactMap { $0 }
                        guard MeetingRecordingJournalStore.load(at: candidate.journalURL) != nil,
                              availableAudioURLs.contains(where: {
                                  FileManager.default.fileExists(atPath: $0.path)
                              }) else {
                            AppLogger.pipeline.info("Skipped stale recording recovery candidate after ownership changed", [
                                "journal": candidate.journalURL.lastPathComponent
                            ])
                            continue
                        }
                        // Persist the new owner before starting any detached
                        // archive work. A user deletion can run while archive
                        // copying is suspended; updateFailedTranscriptionAudio
                        // then rolls that copy back instead of resurrecting the row.
                        didPersist = addFailedTranscriptionRetainingAvailableAudio(
                            micAudioURL: micURL,
                            systemAudioURL: systemURL,
                            errorMessage: "Recording was interrupted before it could be saved. The recovered audio is ready to transcribe.",
                            recordingDate: startedAt,
                            archiveAudio: true,
                            clearRecordingJournalAfterPersistence: false
                        )
                    }
                    if didPersist {
                        _ = MeetingRecordingJournalStore.removeJournalArtifact(
                            at: candidate.journalURL,
                            allowedRoots: [canonicalScratchDirectory]
                        )
                        passRecovered += 1
                        AppLogger.pipeline.info("Recovered orphaned recording into failed queue", [
                            "journal": candidate.journalURL.lastPathComponent,
                            "hasMic": "\(micURL != nil)",
                            "hasSystem": "\(systemURL != nil)"
                        ])
                    }
                }
            }
            totalRecovered += passRecovered
            if !candidates.isEmpty {
                AppLogger.pipeline.info("Recording journal scan finished", [
                    "journals": "\(candidates.count)",
                    "recovered": "\(passRecovered)"
                ])
            }

            if orphanedRecordingRecoveryRequestGeneration != passRequestGeneration {
                guard ContinuousClock.now < waitDeadline else { return totalRecovered }
                continue
            }

            guard waitForRecentJournals, let retryAfter else {
                return totalRecovered
            }
            do {
                // A restored or tampered file can carry an mtime far in the
                // future. Keep that candidate deferred, but never let it pin
                // the single recovery owner (and every joined request) for an
                // unbounded interval before the next scan.
                let maximumRetryInterval = max(0.01, livenessWindow + 0.01)
                let boundedRetryInterval = min(
                    max(0.01, retryAfter + 0.01),
                    maximumRetryInterval
                )
                let now = ContinuousClock.now
                guard now < waitDeadline else { return totalRecovered }
                try await Task.sleep(for: min(
                    .seconds(boundedRetryInterval),
                    now.duration(to: waitDeadline)
                ))
            } catch {
                return totalRecovered
            }
        }
        return totalRecovered
    }

    nonisolated private static func collectOrphanedRecordingCandidates(
        in directory: URL,
        now: Date,
        livenessWindow: TimeInterval
    ) -> [OrphanedRecordingCandidate] {
        let canonicalDirectory = canonicalDirectoryURL(directory)
        return MeetingRecordingJournalStore.journalURLs(in: canonicalDirectory).compactMap {
            guard !isSymbolicLink($0),
                  isFile($0, containedIn: canonicalDirectory) else { return nil }
            return inspectOrphanedRecordingJournal(
                at: $0,
                directory: canonicalDirectory,
                now: now,
                livenessWindow: livenessWindow
            )
        }
    }

    nonisolated private static func inspectOrphanedRecordingJournal(
        at journalURL: URL,
        directory: URL,
        now: Date,
        livenessWindow: TimeInterval
    ) -> OrphanedRecordingCandidate? {
        guard !MeetingRecordingJournalStore.isOwnedByLiveFinalizer(at: journalURL) else {
            return OrphanedRecordingCandidate(
                journalURL: journalURL,
                disposition: .skip(
                    reason: "owned by live finalizer",
                    retryAfter: max(0.01, min(1, livenessWindow))
                )
            )
        }
        guard let journal = MeetingRecordingJournalStore.load(at: journalURL) else {
            // An unreadable journal may still be the only inventory of mic
            // segments absent from a system-only failed row. Preserve it as
            // durable ownership evidence; deleting it could let a later
            // pending-deletion replay report success while private audio stays.
            return OrphanedRecordingCandidate(
                journalURL: journalURL,
                disposition: .skip(reason: "unreadable journal", retryAfter: nil)
            )
        }

        // Journals store bare filenames; resolve them inside the scratch
        // directory only so a tampered journal cannot point recovery at
        // arbitrary files.
        func resolve(_ filename: String?) -> URL? {
            guard let filename, !filename.isEmpty,
                  !filename.contains("/"), !filename.contains("..") else { return nil }
            let candidate = directory.appendingPathComponent(filename)
            guard !isSymbolicLink(candidate) else { return nil }
            let url = canonicalURL(candidate)
            guard isFile(url, containedIn: directory) else { return nil }
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }

        func identityURL(_ filename: String?) -> URL? {
            guard let filename, !filename.isEmpty,
                  !filename.contains("/"), !filename.contains("..") else { return nil }
            let candidate = directory.appendingPathComponent(filename)
            guard !isSymbolicLink(candidate) else { return nil }
            let url = canonicalURL(candidate)
            return isFile(url, containedIn: directory) ? url : nil
        }

        let originalMicURL = identityURL(journal.primaryMicFilename)
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
        if systemURL == nil,
           allAudio.allSatisfy({ $0.lastPathComponent.contains("microphone_placeholder") }) {
            return OrphanedRecordingCandidate(
                journalURL: journalURL,
                disposition: .stale(reason: "only a silent placeholder remains")
            )
        }

        let liveCutoff = now.addingTimeInterval(-livenessWindow)
        let recentModification = allAudio.compactMap { url -> Date? in
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            return attributes?[.modificationDate] as? Date
        }.filter { $0 > liveCutoff }.max()
        if let recentModification {
            return OrphanedRecordingCandidate(
                journalURL: journalURL,
                disposition: .skip(
                    reason: "audio recently written",
                    retryAfter: max(
                        0,
                        recentModification.addingTimeInterval(livenessWindow).timeIntervalSince(now)
                    )
                )
            )
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
            disposition: .recover(
                micURL: micURL,
                systemURL: systemURL,
                originalMicURL: originalMicURL,
                startedAt: journal.startedAt
            )
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

        guard var failed = failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == failedId }) else {
            AppLogger.pipeline.error("Failed transcription not found", ["failedId": "\(failedId)"])
            return false
        }

        guard !failedTranscriptionManager.hasPendingDeletion(id: failedId) else {
            AppLogger.pipeline.info("Skipping retry — deletion is pending", [
                "failedId": failedId.uuidString
            ])
            return false
        }

        guard failed.isRetryable else {
            AppLogger.pipeline.info("Skipping retry — failure is permanent", ["failedId": "\(failedId)", "error": failed.errorMessage])
            return false
        }

        if hasRecordingJournal(
            micAudioURL: failed.micAudioURL,
            systemAudioURL: failed.systemAudioURL
        ) {
            AppLogger.pipeline.info("Deferring retry while recording journal still owns recovery segments", [
                "failedId": failedId.uuidString
            ])
            return false
        }

        if !failed.audioFilesExist() {
            do {
                if let reconciled = try failedTranscriptionManager.healMissingAudioReferencesForRetry(id: failedId) {
                    failed = reconciled
                }
            } catch {
                AppLogger.pipeline.error("Failed to persist healed audio references before retry", [
                    "failedId": "\(failedId)",
                    "errorType": "\(type(of: error))"
                ])
                return false
            }
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
        // Retries reuse the failed-queue row's already-retained audio, not scratch
        // audio, so — matching startSavedAudioRetranscription — this carries no audio.
        tasks[failedId] = .active(audio: nil)
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
                // NOTE: also clears `tasks[failedId]` here — a real behavior fix, not just
                // internal bookkeeping. When `waitingForSpeakerNames` is true above, the failed
                // row for `failedId` is deliberately kept, so the *same* `failedId` can be
                // retried again later. On the pre-refactor code, this success path never cleared
                // `committedTranscriptTaskIds` for `failedId` — if THIS retry had already been
                // marked committed before reaching here, that stale membership would survive
                // into a later retry of the same id. If that later retry was then cancelled via
                // `cancelAll()` before it ever committed, `finishCancelledTaskIfNeeded` would
                // still see the stale committed marker and give it precedence over the later
                // retry's own `CancellationError` — incorrectly publishing "Retry failed" for a
                // retry that was actually just cleanly cancelled. Clearing `tasks[failedId]` here
                // closes that: each retry of the same id now starts from a clean
                // `.active(audio: nil)` state (set in `retryFailedTranscription`), so a stale
                // commit from an earlier retry of the same id can never leak into a later one.
                // See `testSecondRetryOfTheSameFailedIdIsCleanlySuppressedWhenCancelledBeforeCommit`.
                self.tasks.removeValue(forKey: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.publishTranscriptSaved(from: transcriptURL, taskId: failedId)
                return true
            }

            return didPublishRetry

        } catch {
            AppLogger.pipeline.error("Retry failed", ["error": "\(error.localizedDescription)"])
            let errorKind = Self.failureKind(for: error)
            let diagnosticMessage = "Retry failed: \(Self.safeFailureDiagnosticMessage(for: error))"
            await MainActor.run {
                guard !self.finishCancelledTaskIfNeeded(taskId: failedId, error: error) else { return }

                self.activeTasks.removeValue(forKey: failedId)
                // See the matching NOTE in the success branch above: clears `tasks[failedId]`
                // here too, so a failed retry of `failedId` also can't leave behind a stale
                // commit marker for a later retry of the same id to trip over.
                self.tasks.removeValue(forKey: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                failedTranscriptionManager.updateFailedTranscriptionError(
                    id: failedId,
                    errorMessage: diagnosticMessage,
                    errorKind: errorKind
                )
                self.removeSupersededRetrySourceAudioIfNeeded(
                    failedId: failedId,
                    micURL: failed.micAudioURL,
                    systemURL: failed.systemAudioURL
                )
                self.publishFailure(
                    displayMessage: "Retry failed",
                    diagnosticMessage: diagnosticMessage,
                    errorKind: errorKind
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
        tasks.removeValue(forKey: taskId)
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
        activeTasks[taskId] != nil && !(tasks[taskId]?.isCancelling ?? false)
    }

    func markTaskTranscriptCommitted(taskId: UUID) {
        let audio = tasks[taskId]?.audio
        tasks[taskId] = .committed(audio: audio)
        audio?.importedRecoverySession?.transcriptCommitConfirmed()
        // The imported journal remains through scratch cleanup. The separate
        // live-recording journal can retire once the transcript is durable.
        if let audio {
            MeetingRecordingJournalStore.removeJournal(
                micAudioURL: audio.micURL,
                systemAudioURL: audio.systemURL,
                allowedRoots: cleanupDirectories
            )
        }
    }

    /// `preserveActiveTranscriptionsForShutdown()` already synchronously handled this
    /// task's outcome and evicted it from `activeTasks`/counters — only the
    /// `.preservedForShutdown` marker remains. Consuming it (checking membership and
    /// removing in one step, mirroring the old `Set.remove(_:) != nil`) must happen
    /// before `finishCancelledTaskIfNeeded`, which has no special case for this marker.
    private func consumePreservedForShutdownMarker(taskId: UUID) -> Bool {
        guard case .preservedForShutdown = tasks[taskId] else { return false }
        tasks.removeValue(forKey: taskId)
        return true
    }

    private func finishCancelledTaskIfNeeded(taskId: UUID, error: Error? = nil) -> Bool {
        if tasks[taskId]?.isCommitted ?? false {
            // Committed wins over a later cancel-request: drop the transient
            // cancel marker (a `.cancellingCommitted` collapses back to plain
            // `.committed`) and let the caller's normal success path run.
            if case .cancellingCommitted = tasks[taskId] {
                tasks[taskId] = .committed(audio: nil)
            }
            AppLogger.pipeline.info("Preserving committed transcription task outcome after cancellation", [
                "taskId": "\(taskId)"
            ])
            return false
        }

        guard (tasks[taskId]?.isCancelling ?? false) || error is CancellationError else {
            return false
        }

        let hadActiveTask = activeTasks.removeValue(forKey: taskId) != nil
        tasks.removeValue(forKey: taskId)
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
            // Read commit state before overwriting it below: `cancelAll()` unconditionally
            // marks every occupied task cancelled, even one that already committed its
            // transcript — that combination is real (see `.cancellingCommitted`), not a bug.
            let wasCommitted = tasks[taskId]?.isCommitted ?? false
            task.cancel()
            if let audio = tasks[taskId]?.audio {
                if audio.importedRecoverySession?.prepareForScratchCleanup() != false {
                    let removedMic = removeManagedCleanupFile(audio.micURL, label: "cancelled live mic scratch")
                    let removedSystem = removeManagedCleanupFile(audio.systemURL, label: "cancelled live system scratch")
                    if removedMic && removedSystem {
                        audio.importedRecoverySession?.scratchCleanupConfirmed()
                    }
                }
            }
            tasks[taskId] = wasCommitted ? .cancellingCommitted : .cancelling
            AppLogger.pipeline.info("Cancelled task", ["taskId": "\(taskId)"])
        }
        // Keep cancelled tasks in the occupancy map and counters until their task bodies exit.
        // CoreML calls are not guaranteed to observe cancellation immediately; clearing
        // these signals here would let a new pipeline enter the same single-instance models.
        // Audio ownership is cleared above because cancellation deliberately discarded it;
        // finishCancelledTaskIfNeeded removes each task from the occupancy map on exit.
        //
        // Also drop any detached `.preservedForShutdown` markers left over from a previous
        // preserveActiveTranscriptionsForShutdown() call whose task still hasn't returned —
        // mirrors the old unconditional `preservedTaskIdsForShutdown.removeAll()`. But the old
        // code's `committedTranscriptTaskIds` was a *separate* Set that this blanket clear never
        // touched, so a task that had already committed before it was preserved must keep that
        // fact alive here too (downgrading to plain `.committed`) instead of disappearing —
        // otherwise a later `CancellationError` from its still-running body would incorrectly
        // suppress an outcome that already committed for real. See `.preservedForShutdown`'s doc.
        let preservedShutdownMarkers = tasks.compactMap { taskId, state -> (UUID, Bool)? in
            guard case .preservedForShutdown(let wasCommitted) = state else { return nil }
            return (taskId, wasCommitted)
        }
        for (taskId, wasCommitted) in preservedShutdownMarkers {
            tasks[taskId] = wasCommitted ? .committed(audio: nil) : nil
        }
        publishNonFailureStatus(.idle)
    }

    @discardableResult
    public func preserveActiveTranscriptionsForShutdown(errorMessage: String) -> Int {
        let activeAudio: [UUID: ActiveTaskAudio] = tasks.reduce(into: [:]) { result, entry in
            if let audio = entry.value.audio {
                result[entry.key] = audio
            }
        }
        guard !activeAudio.isEmpty else { return 0 }

        for (taskId, task) in activeTasks {
            task.cancel()
            AppLogger.pipeline.warning("Preserving active transcription audio during shutdown", [
                "taskId": taskId.uuidString
            ])
        }

        activeTasks.removeAll()
        // Only the audio-bearing entries get a `.preservedForShutdown` marker (matching
        // the old code, which only ever inserted `activeTaskAudio` keys into
        // `preservedTaskIdsForShutdown`). Audio-less retranscription/retry entries are left
        // untouched here — their task bodies will notice `task.cancel()` above via
        // `error is CancellationError` in `finishCancelledTaskIfNeeded` once they return,
        // exactly as before. Capture whether each task had already committed *before*
        // overwriting its state — the old code's `committedTranscriptTaskIds` was a separate
        // Set that this transition never touched, so that fact must ride along explicitly now.
        for taskId in activeAudio.keys {
            let wasCommitted = tasks[taskId]?.isCommitted ?? false
            tasks[taskId] = .preservedForShutdown(wasCommitted: wasCommitted)
        }
        activeCount = 0
        backgroundTaskCount = 0
        publishNonFailureStatus(.idle)

        var preservedCount = 0
        for (taskId, audio) in activeAudio {
            let didPersist = addFailedTranscriptionRetainingAvailableAudio(
                micAudioURL: audio.micURL,
                systemAudioURL: audio.systemURL,
                errorMessage: errorMessage,
                taskId: taskId,
                meetingTitle: audio.meetingTitle,
                recordingDate: audio.recordingDate
            )
            if didPersist {
                preservedCount += 1
                audio.importedRecoverySession?.failedQueueHandoffConfirmed()
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

    @discardableResult
    nonisolated private func removeRecordingFile(_ url: URL, label: String) -> Bool {
        // Security: only delete scratch files inside Transcripted-managed cleanup roots.
        // `startImportedTranscription` accepts a URL from the caller, so without a containment
        // check a misuse or tampered in-memory request could unlink arbitrary user files.
        guard isSafeCleanupURL(url) else {
            AppLogger.pipeline.error("Refused to delete out-of-sandbox recording file", [
                "label": label,
                "file": url.lastPathComponent
            ])
            return false
        }

        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            if (error as NSError).code == NSFileNoSuchFileError {
                return true
            }
            AppLogger.pipeline.warning("Failed to remove recording file", [
                "label": label,
                "file": url.lastPathComponent,
                "error": error.localizedDescription
            ])
            return false
        }
    }

    @discardableResult
    nonisolated private func removeImportedRecordingFile(
        _ url: URL,
        recoverySession: (any ImportedTranscriptionRecoverySession)?,
        label: String
    ) -> Bool {
        guard recoverySession?.prepareForScratchCleanup() != false else { return false }
        return removeRecordingFile(url, label: label)
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

    @discardableResult
    nonisolated func removeManagedCleanupFile(_ url: URL?, label: String) -> Bool {
        guard let url else { return true }
        return removeRecordingFile(url, label: label)
    }

    func confirmImportedTranscriptionScratchCleanup(taskId: UUID) {
        tasks[taskId]?.audio?.importedRecoverySession?.scratchCleanupConfirmed()
    }

    func prepareImportedTranscriptionScratchCleanup(taskId: UUID) -> Bool {
        tasks[taskId]?.audio?.importedRecoverySession?.prepareForScratchCleanup() ?? true
    }

    func importedRecoverySession(taskId: UUID) -> (any ImportedTranscriptionRecoverySession)? {
        tasks[taskId]?.audio?.importedRecoverySession
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

    nonisolated private static func isSymbolicLink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
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
        let retainedMicURL = existingAudioURL(retainedAudio.micURL)
        let retainedSystemURL = existingAudioURL(retainedAudio.systemURL)
        let originalMicURLForRetry = existingAudioURL(micURL)
        let originalSystemURLForRetry = existingAudioURL(systemURL)
        let placeholderMicURL = makeSilentMicPlaceholderIfNeeded(
            retainedAudio: retainedAudio,
            hasOriginalMic: originalMicURLForRetry != nil,
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
