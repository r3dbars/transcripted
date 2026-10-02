import Foundation

// MARK: - Retry: re-running a failed-queue row

extension TranscriptionTaskManager {
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
        beginTaskLifecycle(taskId: failedId, audio: nil)
        activeTasks[failedId] = retryTask
        await retryTask.value
        return outcome.didPublish
    }

    /// Mutable box that hands the retry's published result across the stored
    /// `Task<Void, Never>` boundary. Main-actor confined like the manager.
    private final class RetryOutcome {
        var didPublish = false
    }

    /// A retry has no live capture health, so it saves none, except that a
    /// "Record Just My Mic" row keeps its mic-only marker (with no grade) and
    /// is not graded degraded for the system track the user chose not to
    /// record.
    nonisolated static func retryHealthInfo(for failed: FailedTranscription) -> RecordingHealthInfo? {
        failed.micOnlyByChoice ? RecordingHealthInfo.micOnlyByChoiceMarker : nil
    }

    private func performRetry(
        failed originalFailed: FailedTranscription,
        failedId: UUID,
        outputFolder: URL
    ) async -> Bool {
        await MainActor.run {
            failedTranscriptionManager.incrementRetryCount(id: failedId)
            self.activeCount += 1
            self.backgroundTaskCount += 1
            self.publishNonFailureStatus(.gettingReady)
        }

        // A "Record Just My Mic" row that never got its silent stand-in track
        // (a quit, timed-out, unexpected or crashed stop) gets one now, so the
        // retry keeps speaker review and Home re-transcribe like a normal stop.
        // Written off the main thread: off APFS the zeros are real bytes.
        var failed = originalFailed
        if failed.micOnlyByChoice, failed.systemAudioURL == nil {
            let micURL = failed.micAudioURL
            let silentURL = await Task.detached(priority: .userInitiated) {
                MicOnlySilentSystemTrack.writeIfPossible(matching: micURL)
            }.value
            if let silentURL {
                if failedTranscriptionManager.updateFailedTranscriptionAudio(
                    id: failedId,
                    micAudioURL: micURL,
                    systemAudioURL: silentURL
                ) {
                    failed.systemAudioURL = silentURL
                } else {
                    try? FileManager.default.removeItem(at: silentURL)
                }
            }
        }

        do {
            let timings = MeetingPipelineTimings()
            let transcriptURL = try await TranscriptionJobActivity.keepingMacAwake {
                try await MeetingPipelineTimings.$current.withValue(timings) {
                    try await transcribeWithSpeakerIdentification(
                        micURL: failed.micAudioURL,
                        systemURL: failed.systemAudioURL,
                        outputFolder: outputFolder,
                        taskId: failedId,
                        healthInfo: Self.retryHealthInfo(for: failed),
                        splitLocalSpeakers: failed.splitLocalSpeakers,
                        meetingTitle: failed.meetingTitle,
                        recordingDate: failed.recordingDate ?? failed.timestamp,
                        sourceFailedTranscriptionId: failedId,
                        languageSelection: failed.languageSelection
                    )
                }
            }

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
                self.forgetTaskLifecycle(taskId: failedId)
                // Publish the success BEFORE decrementing the occupancy
                // counters. `MeetingSessionController` subscribes to
                // `$activeCount` with no scheduler hop, so the decrement
                // synchronously drives `transcriptionQueueSettled()` — and if
                // `lastTerminalTranscriptionOutcome` still holds the previous
                // attempt's `.failed`, the session settles straight back to
                // `.error(oldMessage)` on top of a retry that just succeeded.
                // Every other success path already publishes before it
                // decrements; this was the sole inversion.
                self.publishTranscriptSaved(from: transcriptURL, taskId: failedId, timings: timings.snapshot())
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
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
                self.forgetTaskLifecycle(taskId: failedId)
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
}
