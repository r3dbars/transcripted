// TranscriptionQueueCoordinator.swift
// Background-transcription queue/dispatch bookkeeping extracted from
// MeetingSessionController (audit 2026-07-08 wave 2, W2-B). Pure code motion —
// no behavior change. This is a plain owned object (not an ObservableObject);
// MeetingSessionController still owns the state machine and @Published
// surface. Job dispatch reaches back into the controller (`state`,
// `displayStatus`, `taskManager`, live-sidecar bookkeeping, etc.) via
// `controller`, using the `setState`/`setDisplayStatus` callbacks for the
// two @Published transitions this subsystem drives.
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
                micURL: URL,
                systemURL: URL?,
                healthInfo: RecordingHealthInfo,
                captureDiagnostics: [String: String],
                meetingTitle: String?,
                recordingDate: Date
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
        let promptTelemetryProperties: [String: String]?
        let promptRecordingStartedAt: Date?

        var captureDiagnostics: [String: String]? {
            switch kind {
            case .recorded(_, _, _, let captureDiagnostics, _, _):
                return captureDiagnostics
            case .imported:
                return nil
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
        micURL: URL,
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
                recordingDate: recordingDate
            ),
            startTrigger: startTrigger,
            sttModel: controller.sttRouter.selectedModel,
            promptTelemetryProperties: promptTelemetryProperties,
            promptRecordingStartedAt: promptRecordingStartedAt
        )

        if controller.liveCodexFinalTranscriptNeedsQueuedJobID && controller.liveCodexSessionAwaitingFinalTranscript {
            controller.liveCodexAwaitedTranscriptionJobID = job.id
            controller.liveCodexFinalTranscriptNeedsQueuedJobID = false
        }
        return enqueue(job)
    }

    func enqueueImportedAudioJob(
        audioURL: URL,
        suggestedTitle: String,
        recordingDate: Date,
        startTrigger: MeetingSessionController.StartTrigger
    ) throws -> QueueInsertionOutcome {
        let job = QueuedTranscriptionJob(
            id: UUID(),
            kind: .imported(
                audioURL: audioURL,
                suggestedTitle: suggestedTitle,
                recordingDate: recordingDate
            ),
            startTrigger: startTrigger,
            sttModel: controller.sttRouter.selectedModel,
            promptTelemetryProperties: nil,
            promptRecordingStartedAt: nil
        )

        if canStartQueuedTranscriptionImmediately {
            startQueuedTranscription(job)
            return .startedImmediately
        }

        try persistImportedJournal(for: job)
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

        if !controller.isCaptureSessionActive {
            controller.setState(.transcribing)
        }
        recordQueuedTranscriptionRuntimeDiagnosticsIfSafe(for: job)

        controller.setDisplayStatus(.gettingReady)
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
        guard !Task.isCancelled else { return }
        guard preparingQueuedTranscriptionJob?.id == job.id else { return }

        queuedTranscriptionStartTask = nil
        preparingQueuedTranscriptionJob = nil

        guard modelsReady else {
            failQueuedTranscriptionJobAfterModelRecovery(job)
            handleBackgroundTranscriptionWorkChanged()
            return
        }

        runPreparedQueuedTranscription(job)
    }

    private func ensureModelsReadyForQueuedTranscription(_ job: QueuedTranscriptionJob) async -> Bool {
        controller.sttAdapter.selectPreparedModel(job.sttModel)

        if controller.sttAdapter.isReady && controller.diarization.isReady {
            return true
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
                try await self.controller.downloader.ensureModelsReady(sttModel: job.sttModel)
            }
            controller.sttAdapter.selectPreparedModel(job.sttModel)
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
        controller.sttAdapter.selectPreparedModel(job.sttModel)
        queuedRuntimeDiagnosticsJobIDs.remove(job.id)
        controller.activeQueuedTranscriptionJobID = job.id

        switch job.kind {
        case .recorded(let micURL, let systemURL, let healthInfo, _, let meetingTitle, let recordingDate):
            controller.taskManager.startTranscription(
                taskId: job.id,
                micURL: micURL,
                systemURL: systemURL,
                outputFolder: MeetingStoragePaths.transcriptsFolder,
                healthInfo: healthInfo,
                meetingTitle: meetingTitle,
                splitLocalSpeakers: LocalSpeakerPreferences.isEnabled(),
                recordingDate: recordingDate
            )
        case .imported(let audioURL, let suggestedTitle, let recordingDate):
            controller.taskManager.startImportedTranscription(
                audioURL: audioURL,
                outputFolder: MeetingStoragePaths.transcriptsFolder,
                meetingTitle: suggestedTitle,
                recordingDate: recordingDate
            )
            removeImportedJournal(for: job)
        }
    }

    private func failQueuedTranscriptionJobAfterModelRecovery(_ job: QueuedTranscriptionJob) {
        let message = "Meeting transcription models were not ready. Try again after models finish loading."
        controller.lastTerminalTranscriptionOutcome = .failed(message)
        controller.setState(.error(message))
        controller.setDisplayStatus(.failed(message: message))
        if controller.liveCodexAwaitedTranscriptionJobID == job.id {
            controller.finishLiveCodexSession(status: .failed, shouldAwaitFinalTranscript: false)
        }
        if controller.activeQueuedTranscriptionJobID == job.id {
            controller.activeQueuedTranscriptionJobID = nil
        }

        var preserved = false
        switch job.kind {
        case .recorded(let micURL, let systemURL, _, _, let meetingTitle, let recordingDate):
            preserved = controller.failedMeetingStore.preserveFailedMeetingForRetry(
                micAudioURL: micURL,
                systemAudioURL: systemURL,
                errorMessage: message,
                meetingTitle: meetingTitle,
                recordingDate: recordingDate
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
            removeImportedJournal(for: job)
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

        if !controller.isCaptureSessionActive {
            controller.setState(.transcribing)
        }
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
        let failedQueueAudioURLs = Set(
            controller.failedManager.failedTranscriptions.flatMap { failure in
                [failure.micAudioURL, failure.systemAudioURL].compactMap { $0?.standardizedFileURL }
            }
        )
        var recovered = 0
        for record in records {
            guard let audioURL = ImportedTranscriptionQueueJournal.audioURL(
                for: record,
                scratchDirectory: importedAudioScratchDirectory
            ) else {
                ImportedTranscriptionQueueJournal.remove(
                    id: record.id,
                    journalDirectory: importedQueueJournalDirectory
                )
                continue
            }
            if failedQueueAudioURLs.contains(audioURL.standardizedFileURL) {
                ImportedTranscriptionQueueJournal.remove(
                    id: record.id,
                    journalDirectory: importedQueueJournalDirectory
                )
                continue
            }
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                ImportedTranscriptionQueueJournal.remove(
                    id: record.id,
                    journalDirectory: importedQueueJournalDirectory
                )
                continue
            }
            let model = TranscriptionModelChoice(rawValue: record.sttModelRawValue)
                ?? controller.sttRouter.selectedModel
            queuedTranscriptionJobs.append(
                QueuedTranscriptionJob(
                    id: record.id,
                    kind: .imported(
                        audioURL: audioURL,
                        suggestedTitle: record.suggestedTitle,
                        recordingDate: record.recordingDate
                    ),
                    startTrigger: .fileImport,
                    sttModel: model,
                    promptTelemetryProperties: nil,
                    promptRecordingStartedAt: nil
                )
            )
            recovered += 1
        }
        if recovered > 0 {
            handleBackgroundTranscriptionWorkChanged()
        }
        return recovered
    }

    func removeImportedJournal(for job: QueuedTranscriptionJob) {
        guard case .imported = job.kind else { return }
        ImportedTranscriptionQueueJournal.remove(
            id: job.id,
            journalDirectory: importedQueueJournalDirectory
        )
    }

    private func persistImportedJournal(for job: QueuedTranscriptionJob) throws {
        guard case .imported(let audioURL, let suggestedTitle, let recordingDate) = job.kind else {
            return
        }
        try ImportedTranscriptionQueueJournal.persist(
            id: job.id,
            audioURL: audioURL,
            suggestedTitle: suggestedTitle,
            recordingDate: recordingDate,
            sttModelRawValue: job.sttModel.rawValue,
            journalDirectory: importedQueueJournalDirectory,
            scratchDirectory: importedAudioScratchDirectory
        )
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

        switch controller.lastTerminalTranscriptionOutcome {
        case .failed(let message):
            controller.setState(.error(message))
        case .transcriptSaved:
            controller.setState(.ready)
        case .none:
            if case .transcribing = controller.state {
                controller.setState(.ready)
            }
        }
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

        var preservedCount = 0
        for job in jobs {
            switch job.kind {
            case .recorded(let micURL, let systemURL, _, _, let meetingTitle, let recordingDate):
                if controller.failedMeetingStore.preserveFailedMeetingForRetry(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: errorMessage,
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate
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
                    removeImportedJournal(for: job)
                }
            }
        }
        return preservedCount
    }
}
