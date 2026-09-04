// TranscriptionQueueCoordinator.swift
// Background-transcription queue/dispatch bookkeeping extracted from
// MeetingSessionController (audit 2026-07-08 wave 2, W2-B). Pure code motion —
// no behavior change. This is a plain owned object (not an ObservableObject);
// MeetingSessionController still owns the state machine and @Published
// surface. Job dispatch reaches back into the controller (`state`,
// `displayStatus`, `taskManager`, and related meeting bookkeeping) via
// `controller`. As of the 2026-08 state-collapse audit, this coordinator no
// longer drives `state`/`displayStatus` directly — it reports outcomes
// through narrow controller methods (`transcriptionJobDidStart()`,
// `transcriptionJobFailedToPrepare(message:)`, `transcriptionWorkContinues()`,
// `transcriptionQueueSettled()`) and the controller's `transition(to:reason:)`
// owns the actual transition. The old `setState`/`setDisplayStatus` seam is
// gone.
//
// MeetingSessionController.QueuedTranscriptionJob and
// MeetingSessionController.BackgroundTranscriptionWorkSnapshot stay
// resolvable via typealiases on the controller so every existing reference
// keeps compiling unchanged.

import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class TranscriptionQueueCoordinator {
    struct QueuedTranscriptionJob {
        enum Kind {
            case recorded(
                micURL: URL?,
                systemURL: URL?,
                healthInfo: RecordingHealthInfo,
                captureDiagnostics: [String: String],
                meetingTitle: String?,
                recordingDate: Date,
                splitLocalSpeakers: Bool
            )
            case imported(
                audioURL: URL,
                suggestedTitle: String,
                recordingDate: Date
            )
        }

        let id: UUID
        let kind: Kind
        let startTrigger: MeetingSessionController.StartTrigger
        let sttModel: TranscriptionModelChoice
        let stoppedAudioRecovery: DictationStoppedAudioRecovery?
        let promptTelemetryProperties: [String: String]?
        let promptRecordingStartedAt: Date?
        var importedRecoverySession: ImportedTranscriptionQueueJournalSession?

        /// Snapshot of People-in-the-room at enqueue for recorded jobs.
        /// Imports stay `false` (system-channel).
        var splitLocalSpeakers: Bool {
            switch kind {
            case .recorded(_, _, _, _, _, _, let splitLocalSpeakers):
                return splitLocalSpeakers
            case .imported:
                return false
            }
        }

        var captureDiagnostics: [String: String]? {
            switch kind {
            case .recorded(_, _, _, let captureDiagnostics, _, _, _):
                return captureDiagnostics
            case .imported:
                return nil
            }
        }

        /// Audio this job will open when it starts. Core's orphaned-recording
        /// recovery has no other way to see a job that is queued but not yet
        /// running, and would otherwise archive and unlink this audio out from
        /// under it.
        var reservedAudioURLs: [URL] {
            switch kind {
            case .recorded(let micURL, let systemURL, _, _, _, _, _):
                return [micURL, systemURL].compactMap { $0 }
            case .imported(let audioURL, _, _):
                return [audioURL]
            }
        }

        var artifactRetained: Bool {
            switch kind {
            case .recorded:
                return true
            case .imported:
                return true
            }
        }
    }

    struct BackgroundTranscriptionWorkSnapshot {
        let activeCount: Int
        let speakerNamingRequest: SpeakerNamingRequest?
    }

    enum QueueInsertionOutcome: Equatable {
        case startedImmediately
        case queued(position: Int)
    }

    unowned let controller: MeetingSessionController

    var queuedTranscriptionJobs: [QueuedTranscriptionJob] = []
    var preparingQueuedTranscriptionJob: QueuedTranscriptionJob?
    var queuedTranscriptionStartTask: Task<Void, Never>?
    private var queuedRuntimeDiagnosticsJobIDs: Set<UUID> = []
    private let importedQueueJournalDirectory: URL
    private let importedAudioScratchDirectory: URL

    var isPreparingQueuedTranscriptionStart: Bool {
        preparingQueuedTranscriptionJob != nil || queuedTranscriptionStartTask != nil
    }

    /// Every audio file spoken for by a job that is queued or mid-handoff.
    /// Handed to Core so orphaned-recording recovery leaves it alone.
    var reservedAudioURLs: [URL] {
        (queuedTranscriptionJobs + [preparingQueuedTranscriptionJob].compactMap { $0 })
            .flatMap(\.reservedAudioURLs)
    }

    var currentBackgroundTranscriptionWorkSnapshot: BackgroundTranscriptionWorkSnapshot {
        BackgroundTranscriptionWorkSnapshot(
            activeCount: controller.taskManager.activeCount,
            speakerNamingRequest: controller.taskManager.speakerNamingRequest
        )
    }

    private var canStartQueuedTranscriptionImmediately: Bool {
        canStartQueuedTranscriptionImmediately(snapshot: currentBackgroundTranscriptionWorkSnapshot)
    }

    init(
        controller: MeetingSessionController,
        importedQueueJournalDirectory: URL = MeetingStoragePaths.importedTranscriptionQueueFolder,
        importedAudioScratchDirectory: URL = MeetingStoragePaths.recordingsScratch
    ) {
        self.controller = controller
        self.importedQueueJournalDirectory = importedQueueJournalDirectory
        self.importedAudioScratchDirectory = importedAudioScratchDirectory
    }

    func enqueueTranscriptionJob(
        micURL: URL?,
        systemURL: URL?,
        healthInfo: RecordingHealthInfo,
        captureDiagnostics: [String: String],
        meetingTitle: String?,
        recordingDate: Date,
        startTrigger: MeetingSessionController.StartTrigger,
        promptTelemetryProperties: [String: String]? = nil,
        promptRecordingStartedAt: Date? = nil
    ) -> QueueInsertionOutcome {
        let job = QueuedTranscriptionJob(
            id: UUID(),
            kind: .recorded(
                micURL: micURL,
                systemURL: systemURL,
                healthInfo: healthInfo,
                captureDiagnostics: captureDiagnostics,
                meetingTitle: meetingTitle,
                recordingDate: recordingDate,
                splitLocalSpeakers: LocalSpeakerPreferences.isEnabled()
            ),
            startTrigger: startTrigger,
            sttModel: controller.sttRouter.selectedModel,
            stoppedAudioRecovery: nil,
            promptTelemetryProperties: promptTelemetryProperties,
            promptRecordingStartedAt: promptRecordingStartedAt,
            importedRecoverySession: nil
        )

        return enqueue(job)
    }

    func enqueueImportedAudioJob(
        audioURL: URL,
        suggestedTitle: String,
        recordingDate: Date,
        startTrigger: MeetingSessionController.StartTrigger,
        stoppedAudioRecovery: DictationStoppedAudioRecovery? = nil
    ) throws -> QueueInsertionOutcome {
        var job = QueuedTranscriptionJob(
            id: UUID(),
            kind: .imported(
                audioURL: audioURL,
                suggestedTitle: suggestedTitle,
                recordingDate: recordingDate
            ),
            startTrigger: startTrigger,
            sttModel: controller.sttRouter.selectedModel,
            stoppedAudioRecovery: stoppedAudioRecovery,
            promptTelemetryProperties: nil,
            promptRecordingStartedAt: nil,
            importedRecoverySession: nil
        )

        // Take the lease before publishing recoverable work, then keep it
        // through every asynchronous queue and pipeline transition.
        let session = try ImportedTranscriptionQueueJournal.createClaimed(
            id: job.id,
            audioURL: audioURL,
            recordingDate: recordingDate,
            sttModelRawValue: job.sttModel.rawValue,
            journalDirectory: importedQueueJournalDirectory,
            scratchDirectory: importedAudioScratchDirectory
        )
        job.importedRecoverySession = session

        if canStartQueuedTranscriptionImmediately {
            startQueuedTranscription(job)
            return .startedImmediately
        }

        queuedTranscriptionJobs.append(job)
        return .queued(position: queuedTranscriptionJobs.count)
    }

    private func enqueue(_ job: QueuedTranscriptionJob) -> QueueInsertionOutcome {
        if canStartQueuedTranscriptionImmediately {
            startQueuedTranscription(job)
            return .startedImmediately
        }

        queuedTranscriptionJobs.append(job)
        return .queued(position: queuedTranscriptionJobs.count)
    }

    private func startQueuedTranscription(_ job: QueuedTranscriptionJob) {
        controller.lastTerminalTranscriptionOutcome = nil
        controller.activeTranscriptionTrigger = job.startTrigger
        controller.activeTranscriptionCaptureDiagnostics = job.captureDiagnostics
        controller.activeDetectedPromptTranscriptionTelemetryProperties = job.promptTelemetryProperties
        controller.activeDetectedPromptTranscriptionRecordingStartedAt = job.promptRecordingStartedAt
        controller.sttAdapter.selectPreparedModel(job.sttModel)
        preparingQueuedTranscriptionJob = job

        controller.transcriptionJobDidStart()
        recordQueuedTranscriptionRuntimeDiagnosticsIfSafe(for: job)

        queuedTranscriptionStartTask?.cancel()
        queuedTranscriptionStartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.prepareAndStartQueuedTranscription(job)
        }
    }

    private func prepareAndStartQueuedTranscription(_ job: QueuedTranscriptionJob) async {
        let modelsReady = await ensureModelsReadyForQueuedTranscription(job)

        // A cancelled task must not touch shared state: a newer
        // startQueuedTranscription has already taken ownership of
        // queuedTranscriptionStartTask / preparingQueuedTranscriptionJob.
        guard !Task.isCancelled else {
            if preparingQueuedTranscriptionJob?.id == job.id {
                controller.sttAdapter.discardPreparedModel()
            }
            return
        }
        guard preparingQueuedTranscriptionJob?.id == job.id else { return }

        queuedTranscriptionStartTask = nil
        preparingQueuedTranscriptionJob = nil

        guard modelsReady else {
            controller.sttAdapter.discardPreparedModel()
            failQueuedTranscriptionJobAfterModelRecovery(job)
            handleBackgroundTranscriptionWorkChanged()
            return
        }

        runPreparedQueuedTranscription(job)
    }

    private func ensureModelsReadyForQueuedTranscription(_ job: QueuedTranscriptionJob) async -> Bool {
        controller.sttAdapter.selectPreparedModel(job.sttModel)

        if controller.sttAdapter.isReady && controller.diarization.isReady {
            do {
                try await controller.downloader.ensureModelsReady(
                    sttModel: job.sttModel,
                    retainForNextJob: true
                )
                if controller.sttAdapter.hasPreparedLease(for: job.sttModel) {
                    return true
                }
            } catch {
                // Fall through to the bounded recovery path so the failure is
                // recorded consistently and gets one clean retry.
            }
        }

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_transcription_model_recovery_started",
            message: "Meeting transcription is loading models before starting queued audio",
            context: controller.baseDiagnosticsContext(
                extra: [
                    "trigger": job.startTrigger.rawValue,
                    "queued_stt_model": job.sttModel.rawValue
                ]
            )
        )
        let modelRecoveryStartedAt = CFAbsoluteTimeGetCurrent()
        WorkflowRecoveryTelemetry.attempted(
            workflowKind: "model_preparation",
            failureKind: "models_not_ready",
            retrySource: "queued_transcription",
            surface: "meeting",
            artifactRetained: job.artifactRetained
        )

        do {
            try await TranscriptedConstants.withDetachedTimeout(
                seconds: TranscriptedConstants.modelLoadWaitBudget
            ) {
                try await self.controller.downloader.ensureModelsReady(
                    sttModel: job.sttModel,
                    retainForNextJob: true
                )
            }
        } catch {
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcription_model_recovery_failed",
                message: "Meeting transcription models could not be loaded before queued audio started",
                context: controller.baseDiagnosticsContext(
                    extra: [
                        "error": error.localizedDescription,
                        "trigger": job.startTrigger.rawValue,
                        "queued_stt_model": job.sttModel.rawValue
                    ]
                )
            )
            WorkflowRecoveryTelemetry.finished(
                workflowKind: "model_preparation",
                failureKind: "models_not_ready",
                retrySource: "queued_transcription",
                result: "failed",
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - modelRecoveryStartedAt,
                surface: "meeting",
                artifactRetained: job.artifactRetained
            )
            return false
        }

        let ready = controller.sttAdapter.isReady && controller.diarization.isReady
        if !ready {
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_transcription_model_recovery_failed",
                message: "Meeting transcription models were still unavailable after reload",
                context: controller.baseDiagnosticsContext(
                    extra: [
                        "trigger": job.startTrigger.rawValue,
                        "queued_stt_model": job.sttModel.rawValue
                    ]
                )
            )
        }

        WorkflowRecoveryTelemetry.finished(
            workflowKind: "model_preparation",
            failureKind: "models_not_ready",
            retrySource: "queued_transcription",
            result: ready ? "success" : "failed",
            elapsedSeconds: CFAbsoluteTimeGetCurrent() - modelRecoveryStartedAt,
            surface: "meeting",
            artifactRetained: job.artifactRetained
        )

        return ready
    }

    private func runPreparedQueuedTranscription(_ job: QueuedTranscriptionJob) {
        queuedRuntimeDiagnosticsJobIDs.remove(job.id)
        controller.activeQueuedTranscriptionJobID = job.id
        controller.activeStoppedAudioRecovery = job.stoppedAudioRecovery

        switch job.kind {
        case .recorded(let micURL, let systemURL, let healthInfo, _, let meetingTitle, let recordingDate, let splitLocalSpeakers):
            controller.taskManager.startTranscription(
                taskId: job.id,
                micURL: micURL,
                systemURL: systemURL,
                outputFolder: MeetingStoragePaths.transcriptsFolder,
                healthInfo: healthInfo,
                meetingTitle: meetingTitle,
                splitLocalSpeakers: splitLocalSpeakers,
                recordingDate: recordingDate
            )
        case .imported(let audioURL, let suggestedTitle, let recordingDate):
            controller.taskManager.startImportedTranscription(
                taskId: job.id,
                audioURL: audioURL,
                outputFolder: MeetingStoragePaths.transcriptsFolder,
                meetingTitle: suggestedTitle,
                recordingDate: recordingDate,
                recoverySession: job.importedRecoverySession
            )
        }

        // Task-manager gates reject synchronously before incrementing
        // activeCount. Do not retain a prepared non-selected model when no
        // transcription job took ownership of it.
        if controller.taskManager.activeCount == 0 {
            controller.sttAdapter.discardPreparedModel()
        }
    }

    private func failQueuedTranscriptionJobAfterModelRecovery(_ job: QueuedTranscriptionJob) {
        let message = "Meeting transcription models were not ready. Try again after models finish loading."
        controller.lastTerminalTranscriptionOutcome = .failed(message)
        controller.transcriptionJobFailedToPrepare(message: message)
        if controller.activeQueuedTranscriptionJobID == job.id {
            controller.activeQueuedTranscriptionJobID = nil
        }

        var preserved = false
        switch job.kind {
        case .recorded(let micURL, let systemURL, _, _, let meetingTitle, let recordingDate, let splitLocalSpeakers):
            preserved = controller.failedMeetingStore.preserveFailedMeetingForRetry(
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                errorMessage: message,
                meetingTitle: meetingTitle,
                recordingDate: recordingDate,
                splitLocalSpeakers: splitLocalSpeakers
            )
        case .imported(let audioURL, let suggestedTitle, let recordingDate):
            preserved = controller.failedMeetingStore.preserveFailedMeetingForRetry(
                micAudioURL: nil,
                systemAudioURL: audioURL,
                errorMessage: message,
                meetingTitle: suggestedTitle,
                recordingDate: recordingDate
            )
        }
        if preserved {
            job.importedRecoverySession?.failedQueueHandoffConfirmed()
        }
        clearQueuedTranscriptionRuntimeDiagnosticsIfOwned(for: job, outcome: "model_recovery_failed")
    }

    private func recordQueuedTranscriptionRuntimeDiagnosticsIfSafe(for job: QueuedTranscriptionJob) {
        guard !controller.isCaptureSessionActive else { return }
        guard !(controller.sttRouter.isRecording || controller.sttRouter.isTranscribing) else { return }
        queuedRuntimeDiagnosticsJobIDs.insert(job.id)
        MeetingSessionController.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "transcribing")
    }

    private func clearQueuedTranscriptionRuntimeDiagnosticsIfOwned(
        for job: QueuedTranscriptionJob,
        outcome: String
    ) {
        guard queuedRuntimeDiagnosticsJobIDs.remove(job.id) != nil else { return }
        guard !controller.isCaptureSessionActive else { return }
        guard !(controller.sttRouter.isRecording || controller.sttRouter.isTranscribing) else { return }
        MeetingSessionController.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: outcome)
    }

    private func canStartQueuedTranscriptionImmediately(
        snapshot: BackgroundTranscriptionWorkSnapshot
    ) -> Bool {
        MeetingSessionUIPolicy.canStartQueuedTranscription(
            activeTranscriptions: snapshot.activeCount,
            isPreparingQueuedTranscriptionStart: isPreparingQueuedTranscriptionStart
        )
    }

    func hasVisibleBackgroundTranscriptionWork(
        snapshot: BackgroundTranscriptionWorkSnapshot
    ) -> Bool {
        MeetingSessionUIPolicy.shouldShowTranscribing(
            activeTranscriptions: snapshot.activeCount + (isPreparingQueuedTranscriptionStart ? 1 : 0),
            queuedTranscriptions: queuedTranscriptionJobs.count
        )
    }

    func handleBackgroundTranscriptionWorkChanged() {
        handleBackgroundTranscriptionWorkChanged(snapshot: currentBackgroundTranscriptionWorkSnapshot)
    }

    func handleBackgroundTranscriptionWorkChanged(
        snapshot: BackgroundTranscriptionWorkSnapshot
    ) {
        if canStartQueuedTranscriptionImmediately(snapshot: snapshot) {
            if let nextJob = popNextQueuedTranscriptionJob() {
                startQueuedTranscription(nextJob)
                return
            }

            finalizeBackgroundTranscriptionStateIfNeeded(snapshot: snapshot)
            return
        }

        if !hasVisibleBackgroundTranscriptionWork(snapshot: snapshot) {
            finalizeBackgroundTranscriptionStateIfNeeded(snapshot: snapshot)
            return
        }

        controller.transcriptionWorkContinues()
    }

    private func popNextQueuedTranscriptionJob() -> QueuedTranscriptionJob? {
        guard !queuedTranscriptionJobs.isEmpty else { return nil }
        return queuedTranscriptionJobs.removeFirst()
    }

    @discardableResult
    func recoverImportedAudioJobs() -> Int {
        let records = ImportedTranscriptionQueueJournal.load(
            journalDirectory: importedQueueJournalDirectory
        )
        let failedQueueAudioURLs = controller.failedMeetingStore.failedAudioURLs
        let claimedRecords = records.compactMap { record -> (
            ImportedTranscriptionQueueJournalRecord,
            ImportedTranscriptionQueueJournalSession
        )? in
            guard let recoverySession = try? ImportedTranscriptionQueueJournal.claim(
                id: record.id,
                journalDirectory: importedQueueJournalDirectory
            ) else {
                return nil
            }
            return (record, recoverySession)
        }
        // The journal alone decides recovery for phases that already record a
        // definitive outcome (`ImportedTranscriptionQueueJournal.recoveryAction`).
        // The filesystem is only ever consulted through the legacy/crash-window
        // fallback (`legacyRecoveryAction`), and only for the subset of claimed
        // records whose phase does not yet claim a committed transcript — so a
        // normal relaunch, where every in-flight journal already reflects its
        // outcome, does no directory scan at all. Scan only after every
        // available lease is held: a prior owner can no longer publish a
        // stable transcript after this snapshot and leave us with stale
        // evidence that would replay the same job.
        let ambiguousRecordIDs = Set(
            claimedRecords
                .filter { ImportedTranscriptionQueueJournal.recoveryAction(phase: $0.1.phase) == .replayTranscription }
                .map { $0.0.id }
        )
        let existingTranscriptsByID = TranscriptSaver.existingTranscriptURLs(
            in: MeetingStoragePaths.transcriptsFolder,
            transcriptIds: ambiguousRecordIDs
        )
        var recoveredJobIDs = Set(queuedTranscriptionJobs.map(\.id))
        var recoveredAudioURLs = Set(
            queuedTranscriptionJobs.compactMap { job -> URL? in
                guard case .imported(let audioURL, _, _) = job.kind else { return nil }
                return audioURL.standardizedFileURL
            }
        )
        if let preparingQueuedTranscriptionJob {
            recoveredJobIDs.insert(preparingQueuedTranscriptionJob.id)
            if case .imported(let audioURL, _, _) = preparingQueuedTranscriptionJob.kind {
                recoveredAudioURLs.insert(audioURL.standardizedFileURL)
            }
        }
        var recovered = 0
        for (record, recoverySession) in claimedRecords {
            guard let audioURL = ImportedTranscriptionQueueJournal.audioURL(
                for: record,
                scratchDirectory: importedAudioScratchDirectory
            ) else {
                continue
            }
            if failedQueueAudioURLs.contains(audioURL.standardizedFileURL) {
                recoverySession.failedQueueHandoffConfirmed()
                continue
            }
            if ImportedTranscriptionQueueJournal.isDuplicate(
                record: record,
                audioURL: audioURL,
                existingJobIDs: recoveredJobIDs,
                existingAudioURLs: recoveredAudioURLs
            ) {
                recoverySession.supersededRecoveryConfirmed()
                continue
            }

            let audioStatus = ImportedTranscriptionQueueJournal.recoveryAudioStatus(
                at: audioURL,
                scratchDirectory: importedAudioScratchDirectory
            )
            if audioStatus == .missing {
                recoverySession.scratchCleanupConfirmed()
                continue
            }
            guard audioStatus == .regularFile else {
                AppLogger.pipeline.warning("Rejected unsafe imported recovery scratch entry", [
                    "jobId": record.id.uuidString
                ])
                continue
            }

            let baseAction = ImportedTranscriptionQueueJournal.recoveryAction(phase: recoverySession.phase)
            // Only ambiguous journals (no commit marker yet) consult the
            // legacy/crash-window filesystem fallback; a journal that already
            // claims an outcome never touches `existingTranscriptsByID`.
            let stableTranscriptExists = baseAction == .replayTranscription
                && existingTranscriptsByID[record.id] != nil
            let action = baseAction == .replayTranscription
                ? ImportedTranscriptionQueueJournal.legacyRecoveryAction(
                    phase: recoverySession.phase,
                    stableTranscriptExists: stableTranscriptExists
                )
                : baseAction
            switch action {
            case .replayTranscription:
                break
            case .cleanScratch:
                if removeRecoveredImportedScratchFile(audioURL) {
                    recoverySession.scratchCleanupConfirmed()
                }
                continue
            case .handOffScratch:
                if stableTranscriptExists {
                    recoverySession.transcriptCommitConfirmed()
                }
                if controller.failedMeetingStore.preserveFailedMeetingForRetry(
                    micAudioURL: nil,
                    systemAudioURL: audioURL,
                    errorMessage: "The transcript was saved. Imported audio was preserved because recovery could not confirm scratch cleanup.",
                    meetingTitle: "Imported audio",
                    recordingDate: record.recordingDate
                ) {
                    recoverySession.failedQueueHandoffConfirmed()
                }
                continue
            }

            let model = TranscriptionModelChoice(rawValue: record.sttModelRawValue)
                ?? controller.sttRouter.selectedModel
            queuedTranscriptionJobs.append(
                QueuedTranscriptionJob(
                    id: record.id,
                    kind: .imported(
                        audioURL: audioURL,
                        suggestedTitle: "Imported audio",
                        recordingDate: record.recordingDate
                    ),
                    startTrigger: .fileImport,
                    sttModel: model,
                    stoppedAudioRecovery: nil,
                    promptTelemetryProperties: nil,
                    promptRecordingStartedAt: nil,
                    importedRecoverySession: recoverySession
                )
            )
            recoveredJobIDs.insert(record.id)
            recoveredAudioURLs.insert(audioURL.standardizedFileURL)
            recovered += 1
        }
        if recovered > 0 {
            handleBackgroundTranscriptionWorkChanged()
        }
        return recovered
    }

    func prepareImportedScratchCleanup(for job: QueuedTranscriptionJob) -> Bool {
        job.importedRecoverySession?.prepareForScratchCleanup() ?? true
    }

    func confirmImportedScratchCleanup(for job: QueuedTranscriptionJob) {
        job.importedRecoverySession?.scratchCleanupConfirmed()
    }

    func confirmImportedFailedQueueHandoff(for job: QueuedTranscriptionJob) {
        job.importedRecoverySession?.failedQueueHandoffConfirmed()
    }

    private func removeRecoveredImportedScratchFile(_ audioURL: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: audioURL)
            return true
        } catch {
            if (error as NSError).code == NSFileNoSuchFileError {
                return true
            }
            AppLogger.pipeline.warning("Failed to clean committed imported scratch audio", [
                "file": audioURL.lastPathComponent,
                "errorType": String(describing: type(of: error))
            ])
            return false
        }
    }

    private func finalizeBackgroundTranscriptionStateIfNeeded() {
        finalizeBackgroundTranscriptionStateIfNeeded(snapshot: currentBackgroundTranscriptionWorkSnapshot)
    }

    private func finalizeBackgroundTranscriptionStateIfNeeded(
        snapshot: BackgroundTranscriptionWorkSnapshot
    ) {
        guard !hasVisibleBackgroundTranscriptionWork(snapshot: snapshot) else { return }
        guard !controller.isCaptureSessionActive else { return }
        if MeetingSessionUIPolicy.shouldClearTranscriptionTriggerAfterBackgroundWork(
            hasTerminalOutcome: controller.lastTerminalTranscriptionOutcome != nil,
            hasSpeakerReviewWork: snapshot.speakerNamingRequest != nil
        ) {
            controller.activeTranscriptionTrigger = .unknown
        }

        controller.transcriptionQueueSettled()
    }

    /// Drains the queue (including any job mid-model-recovery) during app
    /// shutdown, preserving each job's audio as a retryable failed meeting.
    @discardableResult
    func preserveQueuedTranscriptionJobsForShutdown(errorMessage: String) -> Int {
        let preparingJob = preparingQueuedTranscriptionJob
        let jobs = queuedTranscriptionJobs + [preparingJob].compactMap { $0 }
        guard !jobs.isEmpty else { return 0 }

        queuedTranscriptionStartTask?.cancel()
        queuedTranscriptionStartTask = nil
        preparingQueuedTranscriptionJob = nil
        queuedTranscriptionJobs.removeAll()
        controller.sttAdapter.discardPreparedModel()

        var preservedCount = 0
        for job in jobs {
            switch job.kind {
            case .recorded(let micURL, let systemURL, _, _, let meetingTitle, let recordingDate, let splitLocalSpeakers):
                if controller.failedMeetingStore.preserveFailedMeetingForRetry(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: errorMessage,
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    splitLocalSpeakers: splitLocalSpeakers
                ) {
                    preservedCount += 1
                }
            case .imported(let audioURL, let suggestedTitle, let recordingDate):
                if controller.failedMeetingStore.preserveFailedMeetingForRetry(
                    micAudioURL: nil,
                    systemAudioURL: audioURL,
                    errorMessage: errorMessage,
                    meetingTitle: suggestedTitle,
                    recordingDate: recordingDate
                ) {
                    preservedCount += 1
                    job.importedRecoverySession?.failedQueueHandoffConfirmed()
                }
            }
        }
        return preservedCount
    }
}
