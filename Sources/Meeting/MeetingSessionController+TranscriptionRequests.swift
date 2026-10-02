// MeetingSessionController+TranscriptionRequests.swift
// Imported audio, cancelling transcription, saved-meeting retranscription, and
// the replacement-commit legacy summary cleanup.

import AppKit
import Combine
import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
@MainActor
extension MeetingSessionController {
    @discardableResult
    func importAudioFile(from sourceURL: URL) async -> Bool {
        let importModel = sttRouter.selectedModel
        let importLanguage = TranscriptionLanguageSelection(
            rawValue: TranscriptionLanguagePreferences.effectiveLanguageCode(for: importModel)
        ) ?? .automatic
        guard !isCaptureSessionActive else {
            // A meeting is actively capturing (starting/recording/stopping).
            // Rejecting the import must not force `state` to `.error` — that
            // would silently clear the capture-active gates (quit-confirm,
            // dictation-block, mic-share, menubar) for a recording that is
            // still physically running; see
            // MeetingSessionStateMachine.mayReportUnrelatedFailureAsError.
            // The recording lifecycle keeps driving `state` normally; this
            // is only traceable via diagnostics, not a visible session error.
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_file_import_blocked_capture_active",
                message: "Imported meeting transcription request rejected because a meeting capture is active",
                context: baseDiagnosticsContext(extra: ["trigger": StartTrigger.fileImport.rawValue])
            )
            return false
        }

        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_file_import_requested",
            message: "Imported meeting transcription requested",
            context: baseDiagnosticsContext(extra: ["trigger": StartTrigger.fileImport.rawValue])
        )
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "file_import_requested")

        if case .idle = state {
            await prepareModels()
        } else if case .loadingModels = state {
            await prepareModels()
        } else if case .error = state {
            await prepareModels()
        }
        if case .ready = state, !isSpeechModelPreparedForSelection {
            await prepareModels()
        }

        switch state {
        case .ready, .transcribing:
            break
        default:
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "models_unavailable")
            return false
        }

        // Surface a cancellable "preparing" card while the source file is copied
        // into scratch. Large imports can take a while; the user can cancel here
        // and the partial copy is cleaned up before any job is enqueued. Only
        // drive the card when no other transcription is already owning it, so we
        // don't stomp an active job's real progress with this prep state.
        let drivesActivityDisplay = !hasBackgroundTranscriptionWork
        if drivesActivityDisplay {
            updateDisplayStatus(.gettingReady, source: .controllerPhase)
        }
        let preparationTask = Task.detached(priority: .utility) {
            try await MeetingImportedAudioPreparer.prepareImportedAudio(from: sourceURL)
        }
        let preparationToken = UUID()
        importPreparationTask = preparationTask
        importPreparationToken = preparationToken
        defer {
            // Only clear if a later import hasn't already replaced this one.
            if importPreparationToken == preparationToken {
                importPreparationTask = nil
                importPreparationToken = nil
            }
        }

        let preparedAudio: PreparedImportedMeetingAudio
        do {
            preparedAudio = try await preparationTask.value
        } catch is CancellationError {
            // The user cancelled mid-import. The preparer already removed the
            // partial scratch copy, so just reset the visible state.
            if drivesActivityDisplay, case .gettingReady = displayStatus {
                updateDisplayStatus(.idle, source: .controllerPhase)
            }
            // A different recording can be actively capturing by now (this
            // await spans the whole scratch-copy cancellation) — only
            // .transcribing was ever exempted here, but .startingRecording/
            // .recording/.stoppingRecording must be exempted too, or this
            // cleanup would leave the mic physically running while every
            // isCaptureSessionActive-derived gate reads false.
            if case .transcribing = state {
                // Leave as-is: a background job is actively transcribing.
            } else if !isCaptureSessionActive {
                transition(to: .ready, reason: "import_cancelled")
            }
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_file_import_cancelled",
                message: "Imported meeting audio preparation cancelled before transcription",
                context: baseDiagnosticsContext(
                    extra: ["trigger": StartTrigger.fileImport.rawValue]
                )
            )
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "file_import_cancelled")
            return false
        } catch {
            if drivesActivityDisplay, case .gettingReady = displayStatus {
                updateDisplayStatus(.idle, source: .controllerPhase)
            }
            let failureKind = importPreparationFailureKind(for: error)
            let displayMessage = importPreparationFailureMessage(for: error)
            DiagnosticsTrail.record(
                level: .error,
                engine: "meeting",
                event: "meeting_file_import_failed",
                message: "Imported meeting audio could not be prepared",
                context: baseDiagnosticsContext(
                    extra: [
                        "failure_kind": failureKind,
                        "import_stage": "preparation",
                        "trigger": StartTrigger.fileImport.rawValue
                    ]
                )
            )
            AnalyticsReporter.track(
                "meeting_file_import_failed",
                properties: [
                    "failure_kind": failureKind,
                    "import_stage": "preparation",
                ]
            )
            ProductFrictionTelemetry.track(
                surface: .meeting,
                stage: "imported_audio_prepare",
                result: .failed,
                failureKind: failureKind,
                modelState: state.diagnosticName
            )
            // A separate recording can be actively capturing by the time
            // this detached preparation task finishes (this call is not
            // gated the way the entry guard above is) — do not stomp it.
            reportUnrelatedFailure(displayMessage, reason: "import_preparation_failed")
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "file_import_failed")
            return false
        }

        let stoppedAudioRecovery = DictationStoppedAudioRecoveryStore
            .pendingRecoveries(limit: Int.max)
            .first { $0.url.standardizedFileURL == sourceURL.standardizedFileURL }
        let outcome: TranscriptionQueueCoordinator.QueueInsertionOutcome
        do {
            outcome = try transcriptionQueue.enqueueImportedAudioJob(
                audioURL: preparedAudio.copiedAudioURL,
                suggestedTitle: preparedAudio.suggestedTitle,
                recordingDate: preparedAudio.recordingDate,
                startTrigger: .fileImport,
                languageSelection: importLanguage,
                sttModel: importModel,
                stoppedAudioRecovery: stoppedAudioRecovery
            )
        } catch {
            let preservedForRelaunch = failedMeetingStore.preserveFailedMeetingForRetry(
                micAudioURL: nil,
                systemAudioURL: preparedAudio.copiedAudioURL,
                errorMessage: ImportedAudioQueuePersistenceFailureCopy.retryEntryMessage,
                meetingTitle: preparedAudio.suggestedTitle,
                recordingDate: preparedAudio.recordingDate,
                languageSelection: importLanguage
            )
            if !preservedForRelaunch {
                try? FileManager.default.removeItem(at: preparedAudio.copiedAudioURL)
            }
            let message = ImportedAudioQueuePersistenceFailureCopy.displayMessage(
                preservedForRelaunch: preservedForRelaunch
            )
            reportUnrelatedFailure(message, reason: "import_queue_persist_failed")
            updateDisplayStatus(.failed(message: message), source: .controllerPhase)
            Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "import_queue_persist_failed")
            return false
        }

        DiagnosticsTrail.record(
            engine: "meeting",
            event: outcome == .startedImmediately
                ? "meeting_file_import_started"
                : "meeting_file_import_queued",
            message: outcome == .startedImmediately
                ? "Imported meeting transcription started"
                : "Imported meeting transcription queued",
            context: baseDiagnosticsContext(
                extra: [
                    "queue_depth": "\(transcriptionQueue.queuedTranscriptionJobs.count)",
                    "trigger": StartTrigger.fileImport.rawValue
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_file_imported",
            properties: [
                "queue_depth_bucket": AnalyticsReporter.queueDepthBucket(transcriptionQueue.queuedTranscriptionJobs.count),
            ]
        )
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "transcribing")
        return true
    }

    private func importPreparationFailureKind(for error: Error) -> String {
        MeetingImportPreparationFailureCopy.kind(for: error)
    }

    private func importPreparationFailureMessage(for error: Error) -> String {
        MeetingImportPreparationFailureCopy.message(for: error)
    }

    /// Cancel any in-progress pipeline. Does not cancel an active recording —
    /// use stopRecording() for that.
    func cancelActiveTranscription(reason: TranscriptionCancelReason = .unknown) {
        // An in-flight imported-audio copy is cancellable too. Cancelling the
        // task makes the preparer interrupt the copy and remove the partial
        // scratch file; importAudioFile() then resets the visible state.
        importPreparationTask?.cancel()
        importPreparationTask = nil
        importPreparationToken = nil

        let queuedJobs = transcriptionQueue.queuedTranscriptionJobs
        transcriptionQueue.queuedTranscriptionJobs.removeAll()
        let preparingJob = transcriptionQueue.preparingQueuedTranscriptionJob
        transcriptionQueue.queuedTranscriptionStartTask?.cancel()
        transcriptionQueue.queuedTranscriptionStartTask = nil
        transcriptionQueue.preparingQueuedTranscriptionJob = nil
        sttAdapter.discardPreparedModel()
        lastTerminalTranscriptionOutcome = nil
        activeTranscriptionTrigger = .unknown
        activeTranscriptionCaptureDiagnostics = nil

        for job in queuedJobs + [preparingJob].compactMap({ $0 }) {
            switch job.kind {
            case .recorded(let micURL, let systemURL, let healthInfo, _, let meetingTitle, let recordingDate, let splitLocalSpeakers):
                failedMeetingStore.preserveFailedMeetingForRetry(
                    micAudioURL: micURL,
                    systemAudioURL: systemURL,
                    errorMessage: "Transcription cancelled",
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    splitLocalSpeakers: splitLocalSpeakers,
                    languageSelection: job.languageSelection,
                    micOnlyByChoice: healthInfo.systemAudioSkippedByChoice == true
                )
            case .imported(let audioURL, let suggestedTitle, let recordingDate):
                if reason == .userRequested {
                    guard transcriptionQueue.prepareImportedScratchCleanup(for: job) else {
                        continue
                    }
                    do {
                        try FileManager.default.removeItem(at: audioURL)
                        transcriptionQueue.confirmImportedScratchCleanup(for: job)
                    } catch where (error as NSError).code == NSFileNoSuchFileError {
                        transcriptionQueue.confirmImportedScratchCleanup(for: job)
                    } catch {
                        AppLogger.pipeline.warning("Failed to discard queued imported scratch audio", [
                            "file": audioURL.lastPathComponent,
                            "errorType": String(describing: type(of: error))
                        ])
                    }
                } else {
                    if failedMeetingStore.preserveFailedMeetingForRetry(
                        micAudioURL: nil,
                        systemAudioURL: audioURL,
                        errorMessage: "Imported audio saved before cancellation. Audio is safe; finish the transcript from the Meetings page.",
                        meetingTitle: suggestedTitle,
                        recordingDate: recordingDate,
                        languageSelection: job.languageSelection
                    ) {
                        transcriptionQueue.confirmImportedFailedQueueHandoff(for: job)
                    }
                }
            }
        }

        taskManager.cancelAll()
        activeQueuedTranscriptionJobID = nil
        activeStoppedAudioRecovery = nil
        // The cancelled work is background transcription (queued/importing
        // audio), not necessarily this recording — the Home "cancel current
        // activity" button is gated on `displayStatus`, which reflects
        // background work that can be visible while a different meeting is
        // actively recording live. Must not stomp that capture's `state`.
        if !isCaptureSessionActive {
            transition(to: .ready, reason: "transcription_cancelled")
        }
        DiagnosticsTrail.record(
            level: .warning,
            engine: "meeting",
            event: "meeting_transcription_cancelled",
            message: "Meeting transcription cancelled",
            context: baseDiagnosticsContext(extra: ["reason": reason.rawValue])
        )
        Self.runtimeDiagnosticsRecorder?.clearSession(kind: "meeting", outcome: "transcription_cancelled")
    }

    @discardableResult
    func retranscribeSavedMeeting(
        micAudioURL: URL?,
        systemAudioURL: URL,
        title: String?,
        transcriptURL: URL? = nil,
        recordingDate: Date? = nil
    ) async -> Bool {
        // None of these rejections are about THIS controller's own capture
        // lifecycle, and a completely different meeting can be actively
        // recording while any of them fires — route the message-bearing
        // ones through reportUnrelatedFailure so they never stomp a live
        // capture's `state` (see that function's doc comment).
        guard !(sttRouter.isRecording || sttRouter.isTranscribing) else {
            reportUnrelatedFailure("Wait for the current dictation to finish before re-transcribing saved audio.", reason: "retranscribe_blocked_dictation")
            return false
        }
        guard !isCaptureSessionActive else {
            // Capture being active is itself why we're rejecting, so there
            // is no safe message to show without stomping the very capture
            // this guard exists to protect — see importAudioFile's
            // equivalent entry guard for the same reasoning.
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_saved_audio_retranscription_blocked_capture_active",
                message: "Saved meeting audio retranscription request rejected because a meeting capture is active",
                context: baseDiagnosticsContext(extra: ["trigger": StartTrigger.savedMeetingRetranscription.rawValue])
            )
            return false
        }
        guard !hasBackgroundTranscriptionWork else {
            reportUnrelatedFailure("Wait for the current meeting to finish saving or transcribing before re-transcribing saved audio.", reason: "retranscribe_blocked_background_work")
            return false
        }
        if !voiceprintMigrationGate.isOpen {
            // Saved people are still moving to the new voiceprint model. Hold,
            // then check everything again: other work may have started since.
            await voiceprintMigrationGate.waitUntilOpen()
            return await retranscribeSavedMeeting(
                micAudioURL: micAudioURL,
                systemAudioURL: systemAudioURL,
                title: title,
                transcriptURL: transcriptURL,
                recordingDate: recordingDate
            )
        }
        DiagnosticsTrail.record(
            engine: "meeting",
            event: "meeting_saved_audio_retranscription_requested",
            message: "Saved meeting audio retranscription requested",
            context: baseDiagnosticsContext(
                extra: [
                    "mic_stream_present": boolString(micAudioURL != nil),
                    "trigger": StartTrigger.savedMeetingRetranscription.rawValue
                ]
            )
        )
        AnalyticsReporter.track(
            "meeting_saved_audio_retranscription_requested",
            properties: [
                "mic_stream_present": boolString(micAudioURL != nil),
                "trigger": StartTrigger.savedMeetingRetranscription.rawValue
            ]
        )
        ProductFrictionTelemetry.track(
            surface: .meeting,
            stage: "meeting_retry",
            result: .started,
            modelState: state.diagnosticName
        )

        if case .idle = state {
            await prepareModels()
        } else if case .loadingModels = state {
            await prepareModels()
        } else if case .error = state {
            await prepareModels()
        }
        if case .ready = state, !isSpeechModelPreparedForSelection {
            await prepareModels()
        }

        guard case .ready = state else {
            return false
        }

        activeTranscriptionTrigger = .savedMeetingRetranscription
        transition(to: .transcribing, reason: "retranscribe_started")
        Self.runtimeDiagnosticsRecorder?.recordSession(kind: "meeting", stage: "saved_audio_retranscribing")
        taskManager.startSavedAudioRetranscription(
            micURL: micAudioURL,
            systemURL: systemAudioURL,
            outputFolder: MeetingStoragePaths.transcriptsFolder,
            meetingTitle: title,
            splitLocalSpeakers: LocalSpeakerPreferences.isEnabled(),
            replacementTranscriptURL: transcriptURL,
            recordingDate: recordingDate,
            onReplacementTranscriptCommitted: { [weak self] committedTranscriptURL in
                self?.handleReplacementTranscriptCommitted(for: committedTranscriptURL)
            }
        )
        return true
    }

    private func handleReplacementTranscriptCommitted(for transcriptURL: URL) {
        clearGeneratedSummaryAfterReplacementRetranscription(for: transcriptURL)
        savedMeetingReplacementCommitCount &+= 1
    }

    /// Legacy artifact hygiene: a retranscription rewrites the saved meeting's
    /// content, so an existing `<stem>.summary.md` sidecar from the (now-removed)
    /// local AI summarizer no longer describes this transcript. Remove it rather
    /// than leave a stale, now-mismatched summary on disk.
    private func clearGeneratedSummaryAfterReplacementRetranscription(for transcriptURL: URL) {
        let summaryURL = MeetingArtifactRenamer.legacySummarySidecarURL(for: transcriptURL)
        do {
            guard try MeetingTranscriptFileUpdateSerializer.sync({ () throws -> Bool in
                guard FileManager.default.fileExists(atPath: summaryURL.path),
                      let values = try TranscriptFrontmatter.readValues(from: summaryURL),
                      values["capture_type"] == "meeting_summary",
                      values["source_transcript"] == transcriptURL.lastPathComponent else {
                    return false
                }
                try FileManager.default.removeItem(at: summaryURL)
                return true
            }) else {
                return
            }
            DiagnosticsTrail.record(
                engine: "meeting",
                event: "meeting_retranscription_summary_invalidated",
                message: "Removed stale local summary after saved meeting retranscription",
                context: baseDiagnosticsContext()
            )
        } catch {
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "meeting_retranscription_summary_invalidation_failed",
                message: "Failed to remove stale local summary after saved meeting retranscription",
                context: baseDiagnosticsContext(extra: [
                    "error_type": "\(type(of: error))"
                ])
            )
        }
    }
}
