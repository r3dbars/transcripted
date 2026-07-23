// FailedMeetingStore.swift
// Failed-meeting queue/persistence/retry bookkeeping extracted from
// MeetingSessionController (audit 2026-07-08 wave 2, W2-B). This is a plain
// owned object (not an ObservableObject); runtime behavior stays unchanged.
// MeetingSessionController still owns the `@Published var failedMeetings`
// surface and supplies narrow callbacks for the state transitions it owns.
//
// MeetingSessionController.FailedMeetingItem stays resolvable via a typealias
// on the controller so every existing call site (Settings/Home UI,
// FailedMeetingPresentation) keeps compiling unchanged.

import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
final class FailedMeetingStore {
    struct FailedMeetingItem: Identifiable, Equatable {
        let id: UUID
        let timestamp: Date
        let title: String
        let detail: String
        let meta: String
        let failureKind: MeetingFailureKind
        let isRetryable: Bool
        let isRetrying: Bool
        let hasAudioFiles: Bool
        let audioURLs: [URL]
    }

    private let taskManager: TranscriptionTaskManager
    private let failedManager: FailedTranscriptionManager
    private let canRetry: () -> Bool
    private let prepareModelsForRetry: () async -> Bool
    private let markRetryStarted: () -> Void
    private let prepareStoppedAudioRecoveryForRetry: (UUID) -> Void
    private let discardStoppedAudioRecoveryForRetry: (UUID) -> Void
    private let publishRefresh: () -> Void
    private let diagnosticsContext: ([String: String]) -> [String: String]

    private var retryingFailedMeetingIDs: Set<UUID> = []
    private var timedOutFinalizationHandoff = TimedOutFailedMeetingFinalizationHandoff()
    private var failedAudioCompressionTask: Task<Void, Never>?
    private var failedAudioCompressionNeedsReschedule = false
    private var timedOutJournalRecoveryTask: Task<Void, Never>?

    init(
        taskManager: TranscriptionTaskManager,
        failedManager: FailedTranscriptionManager,
        canRetry: @escaping () -> Bool,
        prepareModelsForRetry: @escaping () async -> Bool,
        markRetryStarted: @escaping () -> Void,
        prepareStoppedAudioRecoveryForRetry: @escaping (UUID) -> Void,
        discardStoppedAudioRecoveryForRetry: @escaping (UUID) -> Void,
        publishRefresh: @escaping () -> Void,
        diagnosticsContext: @escaping ([String: String]) -> [String: String]
    ) {
        self.taskManager = taskManager
        self.failedManager = failedManager
        self.canRetry = canRetry
        self.prepareModelsForRetry = prepareModelsForRetry
        self.markRetryStarted = markRetryStarted
        self.prepareStoppedAudioRecoveryForRetry = prepareStoppedAudioRecoveryForRetry
        self.discardStoppedAudioRecoveryForRetry = discardStoppedAudioRecoveryForRetry
        self.publishRefresh = publishRefresh
        self.diagnosticsContext = diagnosticsContext
    }

    var failedAudioURLs: Set<URL> {
        Set(
            failedManager.failedTranscriptions.flatMap { failure in
                [failure.micAudioURL, failure.systemAudioURL]
                    .compactMap { $0?.standardizedFileURL }
            }
        )
    }

    @discardableResult
    func retryFailedMeeting(id: UUID) -> Bool {
        guard canRetry() else { return false }
        guard !retryingFailedMeetingIDs.contains(id) else { return false }
        guard failedManager.failedTranscriptions.contains(where: { $0.id == id }) else {
            publishRefresh()
            return false
        }

        failedAudioCompressionTask?.cancel()
        retryingFailedMeetingIDs.insert(id)
        markRetryStarted()
        prepareStoppedAudioRecoveryForRetry(id)
        publishRefresh()
        let retryStartedAt = CFAbsoluteTimeGetCurrent()
        WorkflowRecoveryTelemetry.attempted(
            workflowKind: "meeting_transcription",
            failureKind: "failed_meeting",
            retrySource: "failed_meeting_retry",
            surface: "home",
            artifactRetained: true
        )

        Task { [weak self] in
            guard let self else { return }
            guard await self.prepareModelsForRetry() else {
                DiagnosticsTrail.record(
                    level: .warning,
                    engine: "meeting",
                    event: "meeting_failed_retry_blocked_models",
                    message: "Failed meeting retry blocked because models were not ready",
                    context: self.diagnosticsContext(["failed_id": id.uuidString])
                )
                self.retryingFailedMeetingIDs.remove(id)
                self.publishRefresh()
                WorkflowRecoveryTelemetry.finished(
                    workflowKind: "meeting_transcription",
                    failureKind: "failed_meeting",
                    retrySource: "failed_meeting_retry",
                    result: "failed",
                    elapsedSeconds: CFAbsoluteTimeGetCurrent() - retryStartedAt,
                    surface: "home",
                    artifactRetained: true
                )
                return
            }

            let retryPublished = await self.taskManager.retryFailedTranscription(
                failedId: id,
                outputFolder: MeetingStoragePaths.transcriptsFolder
            )
            self.retryingFailedMeetingIDs.remove(id)
            if !self.failedManager.failedTranscriptions.contains(where: { $0.id == id }) {
                self.finishTimedOutFinalizationWithDiscard(id: id)
            }
            self.publishRefresh()
            WorkflowRecoveryTelemetry.finished(
                workflowKind: "meeting_transcription",
                failureKind: "failed_meeting",
                retrySource: "failed_meeting_retry",
                result: retryPublished ? "success" : "failed",
                elapsedSeconds: CFAbsoluteTimeGetCurrent() - retryStartedAt,
                surface: "home",
                artifactRetained: true
            )
        }
        return true
    }

    @discardableResult
    func dismissFailedMeeting(id: UUID) -> Bool {
        retryingFailedMeetingIDs.remove(id)
        let dismissedFailure = failedManager.failedTranscriptions.first(where: { $0.id == id })
        let didDismiss = failedManager.removeFailedTranscription(id: id)
        let isAbsent = !failedManager.failedTranscriptions.contains(where: { $0.id == id })
        if didDismiss || isAbsent {
            if let dismissedFailure {
                taskManager.discardFinalizedFailedTranscriptionAudio(
                    micAudioURL: dismissedFailure.micAudioURL,
                    systemAudioURL: dismissedFailure.systemAudioURL
                )
            }
            finishTimedOutFinalizationWithDiscard(id: id)
        }
        publishRefresh()
        return didDismiss || isAbsent
    }

    @discardableResult
    func deleteFailedMeeting(id: UUID) -> Bool {
        retryingFailedMeetingIDs.remove(id)
        let didDelete = failedManager.deleteFailedTranscription(id: id)
        let isAbsent = !failedManager.failedTranscriptions.contains(where: { $0.id == id })
        if didDelete || isAbsent {
            finishTimedOutFinalizationWithDiscard(id: id)
        }
        if didDelete {
            discardStoppedAudioRecoveryForRetry(id)
        }
        publishRefresh()
        return didDelete || isAbsent
    }

    @discardableResult
    func preserveTimedOutFailedMeetingForRetry(
        taskId: UUID,
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String?,
        recordingDate: Date? = nil
    ) -> Bool {
        // A completion can win the main-actor race and be buffered before the
        // timeout continuation resumes. Use those finalized URLs as fallbacks
        // so an empty timeout snapshot cannot suppress the durable failed row.
        let persistenceAudio = timedOutFinalizationHandoff.audioForPersistence(
            id: taskId,
            provisionalMicURL: micAudioURL,
            provisionalSystemURL: systemAudioURL
        )
        let preserved = persistFailedMeetingForRetry(
            taskId: taskId,
            micAudioURL: persistenceAudio.micURL,
            systemAudioURL: persistenceAudio.systemURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: false,
            clearRecordingJournalAfterPersistence: false
        )
        guard preserved else {
            timedOutFinalizationHandoff.markPersistenceFailed(id: taskId)
            return false
        }

        if let finalizedResult = timedOutFinalizationHandoff.failedMeetingDidPersist(id: taskId) {
            promoteTimedOutFailedMeetingAudio(id: taskId, result: finalizedResult)
        } else {
            publishRefresh()
        }
        if let ownedAudioURL = persistenceAudio.micURL ?? persistenceAudio.systemURL {
            scheduleTimedOutJournalRecovery(in: ownedAudioURL.deletingLastPathComponent())
        }
        return true
    }

    @discardableResult
    func preserveFailedMeetingForRetry(
        taskId: UUID = UUID(),
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String?,
        recordingDate: Date? = nil,
        archiveAudio: Bool = true
    ) -> Bool {
        let preserved = persistFailedMeetingForRetry(
            taskId: taskId,
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio
        )
        if preserved {
            publishRefresh()
        }
        return preserved
    }

    func refreshTimedOutFailedMeetingAudio(id: UUID, result: CaptureStopResult) {
        let failedMeetingIsPersisted = failedManager.failedTranscriptions
            .contains(where: { $0.id == id })
        let action = timedOutFinalizationHandoff.receive(
            result,
            for: id,
            failedMeetingIsPersisted: failedMeetingIsPersisted
        )
        switch action {
        case .buffered:
            DiagnosticsTrail.record(
                level: .info,
                engine: "meeting",
                event: "meeting_recording_stop_timeout_audio_buffered",
                message: "Timed-out meeting audio finalized before its failed queue entry was persisted",
                context: diagnosticsContext([
                    "failed_id": id.uuidString,
                    "mic_file_present": boolString(result.micURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false),
                    "system_file_present": boolString(result.systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
                ])
            )
            return
        case .promote(let deliverableResult):
            promoteTimedOutFailedMeetingAudio(id: id, result: deliverableResult)
        case .discard(let terminalResult):
            discardFinalizedTimedOutAudio(terminalResult)
        case .journalOwned:
            return
        }
    }

    private func persistFailedMeetingForRetry(
        taskId: UUID,
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String?,
        recordingDate: Date?,
        archiveAudio: Bool,
        clearRecordingJournalAfterPersistence: Bool = true
    ) -> Bool {
        taskManager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            taskId: taskId,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio,
            clearRecordingJournalAfterPersistence: clearRecordingJournalAfterPersistence
        )
    }

    private func promoteTimedOutFailedMeetingAudio(id: UUID, result: CaptureStopResult) {
        let existingFailure = failedManager.failedTranscriptions
            .first(where: { $0.id == id })
        let existingMicURL = existingFailure?.micAudioURL
        let existingSystemURL = existingFailure?.systemAudioURL
        guard let micURL = result.micURL ?? existingMicURL else { return }
        let systemURL = result.systemURL ?? existingSystemURL

        let updated = taskManager.promoteFinalizedFailedTranscriptionAudio(
            id: id,
            micAudioURL: micURL,
            systemAudioURL: systemURL
        )
        DiagnosticsTrail.record(
            level: updated ? .info : .warning,
            engine: "meeting",
            event: "meeting_recording_stop_timeout_audio_finalized",
            message: updated
                ? "Timed-out meeting audio finalized and failed queue was refreshed"
                : "Timed-out meeting audio finalized but failed queue entry was not found",
            context: diagnosticsContext([
                "failed_id": id.uuidString,
                "mic_file_present": boolString(FileManager.default.fileExists(atPath: micURL.path)),
                "system_file_present": boolString(systemURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
            ])
        )
        if updated {
            timedOutFinalizationHandoff.markDeliverySucceeded(id: id)
            publishRefresh()
        }
    }

    private func finishTimedOutFinalizationWithDiscard(id: UUID) {
        guard let bufferedResult = timedOutFinalizationHandoff.markTerminalDiscard(id: id) else {
            return
        }
        discardFinalizedTimedOutAudio(bufferedResult)
    }

    private func discardFinalizedTimedOutAudio(_ result: CaptureStopResult) {
        taskManager.discardFinalizedFailedTranscriptionAudio(
            micAudioURL: result.micURL,
            systemAudioURL: result.systemURL
        )
    }

    private func scheduleTimedOutJournalRecovery(in scratchDirectory: URL) {
        timedOutJournalRecoveryTask?.cancel()
        let taskManager = self.taskManager
        timedOutJournalRecoveryTask = Task {
            _ = await taskManager.recoverOrphanedRecordings(in: scratchDirectory)
        }
    }

    /// Recomputes the presented failed-meeting list. Called from the
    /// controller's `refreshFailedMeetings(_:)`, which assigns the result to
    /// its own `@Published var failedMeetings` (kept on the controller —
    /// this store never touches the published surface directly).
    func refreshFailedMeetings(_ updatedFailedTranscriptions: [FailedTranscription]? = nil) -> [FailedMeetingItem] {
        let failedTranscriptions = updatedFailedTranscriptions ?? failedManager.failedTranscriptions
        let persistedIDs = Set(failedTranscriptions.map(\.id))
        let removedTimedOutIDs = timedOutFinalizationHandoff.persistedOwnershipIDs
            .subtracting(persistedIDs)
        for id in removedTimedOutIDs {
            finishTimedOutFinalizationWithDiscard(id: id)
        }
        retryingFailedMeetingIDs.formIntersection(persistedIDs)

        let items = failedTranscriptions
            .sorted(by: { $0.timestamp > $1.timestamp })
            .map { failed in
                FailedMeetingPresentation.item(
                    from: failed,
                    isRetrying: retryingFailedMeetingIDs.contains(failed.id)
                )
            }
        scheduleFailedAudioCompression(for: failedTranscriptions)
        return items
    }

    private func scheduleFailedAudioCompression(for failedTranscriptions: [FailedTranscription]) {
        guard failedAudioCompressionTask == nil else {
            failedAudioCompressionNeedsReschedule = true
            return
        }

        let candidates = failedTranscriptions.compactMap { failed -> FailedMeetingAudioCompressionCandidate? in
            guard !retryingFailedMeetingIDs.contains(failed.id) else { return nil }
            var urls = [failed.micAudioURL]
            if let systemAudioURL = failed.systemAudioURL {
                urls.append(systemAudioURL)
            }
            guard urls.contains(where: { $0.pathExtension.localizedCaseInsensitiveCompare("wav") == .orderedSame }) else {
                return nil
            }
            return FailedMeetingAudioCompressionCandidate(
                id: failed.id,
                micAudioURL: failed.micAudioURL,
                systemAudioURL: failed.systemAudioURL
            )
        }
        guard !candidates.isEmpty else { return }

        failedAudioCompressionNeedsReschedule = false
        let audioArchiveRoot = MeetingStoragePaths.audioArchiveFolder
        failedAudioCompressionTask = Task { [weak self] in
            _ = await MeetingAudioStorageManager.compressFailedTranscriptionAudio(
                candidates: candidates,
                audioArchiveRoot: audioArchiveRoot,
                persistUpdate: { [weak self] update in
                    await MainActor.run {
                        guard let self,
                              !self.retryingFailedMeetingIDs.contains(update.id) else {
                            return false
                        }
                        return self.failedManager.updateFailedTranscriptionAudio(
                            id: update.id,
                            micAudioURL: update.micAudioURL,
                            systemAudioURL: update.systemAudioURL
                        )
                    }
                }
            )
            await MainActor.run { [weak self] in
                let shouldReschedule = self?.failedAudioCompressionNeedsReschedule == true
                self?.failedAudioCompressionTask = nil
                self?.failedAudioCompressionNeedsReschedule = false
                if shouldReschedule, let self {
                    self.scheduleFailedAudioCompression(for: self.failedManager.failedTranscriptions)
                }
            }
        }
    }

    private func boolString(_ value: Bool) -> String {
        value ? "true" : "false"
    }
}
