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
        var usableAudio: FailedMeetingUsableAudio = .unknown
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

    /// Cached `FailedRecordingSignalProbe` verdicts, keyed by the audio file
    /// itself. Keying on the URL rather than the row means WAV→M4A compression
    /// (which rewrites the path) invalidates the entry for free. Storing the
    /// full tri-state (rather than a Bool) is what keeps an `.inconclusive`
    /// file from being re-probed on every single refresh.
    private var usableAudioVerdicts: [URL: FailedRecordingSignalProbe.Result] = [:]
    private var usableAudioProbeTask: Task<Void, Never>?
    private var usableAudioProbeNeedsReschedule = false

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
        recordingDate: Date? = nil,
        splitLocalSpeakers: Bool = false
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
            clearRecordingJournalAfterPersistence: false,
            splitLocalSpeakers: splitLocalSpeakers
        )
        guard preserved else {
            timedOutFinalizationHandoff.markPersistenceFailed(id: taskId)
            if let ownedAudioURL = persistenceAudio.micURL ?? persistenceAudio.systemURL {
                scheduleTimedOutJournalRecovery(in: ownedAudioURL.deletingLastPathComponent())
            }
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
        archiveAudio: Bool = true,
        splitLocalSpeakers: Bool = false
    ) -> Bool {
        let preserved = persistFailedMeetingForRetry(
            taskId: taskId,
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio,
            splitLocalSpeakers: splitLocalSpeakers
        )
        if preserved {
            publishRefresh()
        }
        return preserved
    }

    func refreshTimedOutFailedMeetingAudio(id: UUID, result: CaptureStopResult) {
        let failedMeetingIsPersisted = failedManager.failedTranscriptions
            .contains(where: { $0.id == id })
        if !failedMeetingIsPersisted,
           !timedOutFinalizationHandoff.hasOwnership(of: id),
           result.finalizationOwner != .recordingJournalRecovery,
           result.micURL != nil || result.systemURL != nil,
           !taskManager.hasRecordingJournal(
               micAudioURL: result.micURL,
               systemAudioURL: result.systemURL
           ) {
            // Both bounded owner tables may have evicted this ID. With no
            // durable row or journal, a terminal delete/discard owns the late
            // callback only for cleanup; treating it as callback-first would
            // orphan merger output that appeared after deletion.
            discardFinalizedTimedOutAudio(result)
            return
        }
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
            let persistedFailure = failedManager.failedTranscriptions
                .first(where: { $0.id == id })
            if let ownedAudioURL = result.micURL
                ?? result.systemURL
                ?? persistedFailure?.micAudioURL
                ?? persistedFailure?.systemAudioURL {
                scheduleTimedOutJournalRecovery(in: ownedAudioURL.deletingLastPathComponent())
            }
            return
        }
    }

    /// The bridge intentionally releases each per-meeting late callback after
    /// a bounded grace. A completion after that boundary can still recover its
    /// finalized journal through this value-only, ID-independent seam.
    func recoverExpiredTimedOutMeetingAudio(_ result: CaptureStopResult) {
        let matchingFailures = failedManager.failedTranscriptions.filter {
            failedMeeting($0, owns: result)
        }
        if matchingFailures.count == 1, let failedMeetingID = matchingFailures.first?.id {
            refreshTimedOutFailedMeetingAudio(id: failedMeetingID, result: result)
            return
        }
        guard let ownedAudioURL = result.micURL ?? result.systemURL else { return }
        let scratchDirectory = ownedAudioURL.deletingLastPathComponent()
        let hasMatchingJournal = taskManager.hasRecordingJournal(
            micAudioURL: result.micURL,
            systemAudioURL: result.systemURL
        )
        if matchingFailures.count > 1 {
            // Ambiguous live ownership fails closed: keep the finalized file
            // and let canonical journal recovery reconcile what it can.
            scheduleTimedOutJournalRecovery(in: scratchDirectory)
            return
        }
        switch ExpiredTimedOutCompletionFallback.action(
            hasMatchingJournal: hasMatchingJournal
        ) {
        case .recoverJournal:
            scheduleTimedOutJournalRecovery(in: scratchDirectory)
        case .discardFinalizedAudio:
            discardFinalizedTimedOutAudio(result)
        }
    }

    private func failedMeeting(
        _ failure: FailedTranscription,
        owns result: CaptureStopResult
    ) -> Bool {
        if let failedSystemURL = failure.systemAudioURL,
           let systemURL = result.systemURL,
           canonicalURL(failedSystemURL) == canonicalURL(systemURL) {
            return true
        }
        guard let micURL = result.micURL else { return false }
        let failedMicURL = canonicalURL(failure.micAudioURL)
        let finalizedMicURL = canonicalURL(micURL)
        guard failedMicURL.deletingLastPathComponent() == finalizedMicURL.deletingLastPathComponent() else {
            return false
        }
        return recordingStem(failedMicURL) == recordingStem(finalizedMicURL)
    }

    private func recordingStem(_ url: URL) -> String {
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.hasSuffix("_merged")
            ? String(stem.dropLast("_merged".count))
            : stem
    }

    private func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func persistFailedMeetingForRetry(
        taskId: UUID,
        micAudioURL: URL?,
        systemAudioURL: URL?,
        errorMessage: String,
        meetingTitle: String?,
        recordingDate: Date?,
        archiveAudio: Bool,
        clearRecordingJournalAfterPersistence: Bool = true,
        splitLocalSpeakers: Bool = false
    ) -> Bool {
        taskManager.addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micAudioURL,
            systemAudioURL: systemAudioURL,
            errorMessage: errorMessage,
            taskId: taskId,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            archiveAudio: archiveAudio,
            clearRecordingJournalAfterPersistence: clearRecordingJournalAfterPersistence,
            splitLocalSpeakers: splitLocalSpeakers
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
        let taskManager = self.taskManager
        Task {
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
                    isRetrying: retryingFailedMeetingIDs.contains(failed.id),
                    usableAudio: usableAudioVerdict(for: failed)
                )
            }
        scheduleFailedAudioCompression(for: failedTranscriptions)
        scheduleUsableAudioProbe(for: failedTranscriptions)
        return items
    }

    /// Resolves a row's verdict from the cache without touching disk beyond an
    /// existence check. Any one usable file is enough, because the pipeline
    /// transcribes whichever sources survived — a broken mic beside good system
    /// audio is a perfectly transcribable meeting.
    ///
    /// `.absent` requires every surviving file to have been examined in full and
    /// found silent. Anything less stays `.unknown`, which keeps retry offered:
    /// wrongly hiding the action is the failure mode this whole change exists to
    /// remove, so it must not come back through the probe.
    private func usableAudioVerdict(for failed: FailedTranscription) -> FailedMeetingUsableAudio {
        let urls = existingAudioURLs(for: failed)
        guard !urls.isEmpty else { return .absent }

        var everyFileProvenSilent = true
        for url in urls {
            switch usableAudioVerdicts[url] {
            case .present:
                return .present
            case .absent:
                continue
            case .inconclusive, nil:
                everyFileProvenSilent = false
            }
        }
        return everyFileProvenSilent ? .absent : .unknown
    }

    private func existingAudioURLs(for failed: FailedTranscription) -> [URL] {
        let fileManager = FileManager.default
        return [failed.systemAudioURL, failed.micAudioURL]
            .compactMap { $0?.standardizedFileURL }
            .filter { fileManager.fileExists(atPath: $0.path) }
    }

    /// Probes any audio file with no cached verdict. Retries in flight are
    /// skipped so the probe never contends with the pipeline for the same file.
    private func scheduleUsableAudioProbe(for failedTranscriptions: [FailedTranscription]) {
        guard usableAudioProbeTask == nil else {
            usableAudioProbeNeedsReschedule = true
            return
        }

        let pending = failedTranscriptions
            .filter { !retryingFailedMeetingIDs.contains($0.id) }
            .flatMap { existingAudioURLs(for: $0) }
            .filter { usableAudioVerdicts[$0] == nil }
        guard !pending.isEmpty else { return }

        let uniquePending = Array(Set(pending))
        usableAudioProbeNeedsReschedule = false
        usableAudioProbeTask = Task { [weak self] in
            let probed = await Task.detached(priority: .utility) { () -> [URL: FailedRecordingSignalProbe.Result] in
                var results: [URL: FailedRecordingSignalProbe.Result] = [:]
                for url in uniquePending {
                    results[url] = FailedRecordingSignalProbe.probe(url: url)
                }
                return results
            }.value

            await MainActor.run {
                guard let self else { return }
                self.usableAudioVerdicts.merge(probed) { _, new in new }
                // Clear ownership before republishing: `publishRefresh` reenters
                // `refreshFailedMeetings`, and a non-nil task there would defer
                // the very pass that has just been satisfied.
                self.usableAudioProbeTask = nil
                let shouldReschedule = self.usableAudioProbeNeedsReschedule
                self.usableAudioProbeNeedsReschedule = false
                self.publishRefresh()
                if shouldReschedule {
                    self.scheduleUsableAudioProbe(for: self.failedManager.failedTranscriptions)
                }
            }
        }
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
