import Foundation

// MARK: - Start flows: live, imported, and saved-audio retranscription jobs, plus the accidental-start gate

extension TranscriptionTaskManager {
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
        recordingDate: Date? = nil,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        sessionLength: TimeInterval? = nil
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
                recordingDate: recordingDate,
                splitLocalSpeakers: splitLocalSpeakers,
                languageSelection: languageSelection,
                micOnlyByChoice: healthInfo?.systemAudioSkippedByChoice == true
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
        let (micDuration, systemDuration, hasUsableMicAudio, hasUsableSystemAudio, hasUnknownDuration) =
            audioUsability(micURL: micURL, systemURL: systemURL)

        guard hasUsableMicAudio || hasUsableSystemAudio || hasUnknownDuration else {
            AppLogger.pipeline.info("Recording too short, skipping transcription", [
                "micDuration": micDuration.map { String(format: "%.1fs", $0) } ?? (micURL == nil ? "none" : "unknown"),
                "systemDuration": systemDuration.map { String(format: "%.1fs", $0) } ?? "none"
            ])

            // Deliberate: this gate deletes live-capture scratch outright instead of
            // archiving it into the failed queue the way the transcription failure paths
            // below do — do not "fix" it to retain the audio.
            // `testStartTranscriptionRejectsTooShortLiveAudioWithoutQueueingRetry` pins
            // both halves (scratch removed, failed queue left empty).
            //
            // This gate means the whole capture *file* is under 2s, which in practice is
            // an accidental hotkey bump. `recordingTooShort` is non-retryable, so a failed
            // row here would be a dead entry the user can only dismiss — junk in the
            // failed-meetings list for every mis-trigger.
            //
            // The same-named error thrown deeper (`PipelineError.recordingTooShort` in
            // TranscriptionPipeline) IS retained by the catch block, and that is not an
            // inconsistency: it fires on decoded *sample* count after a full-length
            // recording turned out to be empty, which is a real capture failure worth
            // keeping. Same name, different situation.
            //
            // It is reported as a discarded accidental start, not a failure (no
            // error in the overlay, no failed row, and hosts log it as a cancel),
            // but only when the host's session clock was short too and capture
            // reported nothing wrong. Short files from a longer session, or from
            // a session with gaps or device trouble, mean capture broke, and that
            // must stay a visible failure rather than look like the user cancelled.
            if Self.isAccidentalStartUnderMinimumLength(sessionLength: sessionLength, healthInfo: healthInfo) {
                discardAccidentalStart(micURL: micURL, systemURL: systemURL, reason: "under_minimum_length")
                return
            }
            if let micURL {
                removeRecordingFile(micURL, label: "short mic recording")
            }
            if let systemURL {
                removeRecordingFile(systemURL, label: "short system recording")
            }
            self.publishFailure(
                displayMessage: sessionLength == nil
                    ? "Recording too short"
                    : Self.recordingTooShortCaptureStoppedEarlyMessage,
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

        // Only a duration verified from both present files can mark a later
        // no-speech result as an accidental start; an unreadable length never
        // throws audio away.
        let verifiedRecordingLength: TimeInterval? = hasUnknownDuration
            ? nil
            : [micDuration, systemDuration].compactMap { $0 }.max()

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
            recordingDate: recordingDate,
            languageSelection: languageSelection
        )

        activeCount += 1
        backgroundTaskCount += 1
        beginTaskLifecycle(taskId: task.id, audio: ActiveTaskAudio(
            micURL: micURL,
            systemURL: systemURL,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            importedRecoverySession: nil,
            splitLocalSpeakers: splitLocalSpeakers,
            languageSelection: languageSelection,
            micOnlyByChoice: healthInfo?.systemAudioSkippedByChoice == true
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

                let timings = MeetingPipelineTimings()
                let transcriptURL = try await TranscriptionJobActivity.keepingMacAwake {
                    try await MeetingPipelineTimings.$current.withValue(timings) {
                        try await self.transcribeWithSpeakerIdentification(
                            micURL: micURL,
                            systemURL: systemURL,
                            outputFolder: outputFolder,
                            taskId: task.id,
                            healthInfo: task.healthInfo,
                            splitLocalSpeakers: task.splitLocalSpeakers,
                            meetingTitle: task.meetingTitle,
                            recordingDate: task.recordingDate,
                            languageSelection: task.languageSelection
                        )
                    }
                }

                await MainActor.run {
                    guard !self.finishCancelledTaskIfNeeded(taskId: task.id) else { return }
                    self.publishTranscriptSaved(from: transcriptURL, taskId: task.id, timings: timings.snapshot())
                    self.handleTaskCompletion(taskId: task.id)
                }

            } catch {
                // Only a short, healthy session whose files hold no sound that
                // rises and falls like a voice is thrown away. Anything that
                // might hold a missed word, or any sign capture broke, falls
                // through to the retained, retryable failure below.
                if Self.isAccidentalStart(
                    error: error,
                    recordingLength: verifiedRecordingLength,
                    sessionLength: sessionLength,
                    healthInfo: task.healthInfo
                ), !Self.tracksHaveSpeechLikeSignal([micURL, systemURL].compactMap { $0 }) {
                    await MainActor.run {
                        // Same ownership checks as the failure path below: a
                        // shutdown that already preserved this audio, or a
                        // cancellation, wins over the discard.
                        if self.consumePreservedForShutdownMarker(taskId: task.id) {
                            self.handleTaskCompletion(taskId: task.id)
                            return
                        }
                        guard !self.finishCancelledTaskIfNeeded(taskId: task.id, error: error) else { return }
                        self.discardAccidentalStart(micURL: micURL, systemURL: systemURL, reason: "short_no_speech")
                        self.handleTaskCompletion(taskId: task.id)
                    }
                    return
                }

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
                    errorKind: errorKind,
                    splitLocalSpeakers: task.splitLocalSpeakers,
                    languageSelection: task.languageSelection,
                    micOnlyByChoice: task.healthInfo?.systemAudioSkippedByChoice == true
                )

                await MainActor.run {
                    self.sendFailureNotification(errorMessage: error.localizedDescription)
                    self.handleTaskCompletion(taskId: task.id)
                }
            }
        }

        activeTasks[task.id] = asyncTask
    }

    // MARK: - Accidental starts

    /// Longest live recording that is dropped quietly when it turns out to hold
    /// no speech. A tap on the hotkey or overlay that is stopped a few seconds
    /// later is almost never a meeting, and reporting it as "No speech found"
    /// (with a failed row to clean up) counted every mis-tap as a failure.
    nonisolated public static let accidentalStartMaximumLength: TimeInterval = 10

    /// Whether a live recording that failed with `error` may be an accidental
    /// start. All of these must hold:
    /// - the error is "no speech" (a short recording that failed for any other
    ///   reason, a broken track or a model error, keeps its audio for retry);
    /// - both the saved files and the host's own session clock are short, so
    ///   a long meeting whose capture died early is never mistaken for a tap;
    /// - the recording reported no gaps, device switches, missing or unusable
    ///   tracks, or degraded capture.
    /// `tracksHaveSpeechLikeSignal` is the last check, done by the caller.
    nonisolated static func isAccidentalStart(
        error: Error,
        recordingLength: TimeInterval?,
        sessionLength: TimeInterval?,
        healthInfo: RecordingHealthInfo?
    ) -> Bool {
        guard let recordingLength, recordingLength < accidentalStartMaximumLength,
              let sessionLength, sessionLength < accidentalStartMaximumLength else { return false }
        guard let pipelineError = error as? PipelineError,
              case .noSpeechDetected = pipelineError else { return false }
        return hasCleanCaptureHealth(healthInfo)
    }

    /// Longest session clock at which files under the 2 s minimum still count
    /// as a tap rather than broken capture. The clock runs from Record until
    /// the stop has finished, so it is always a little longer than the audio;
    /// this leaves room for that without hiding a session that really ran.
    nonisolated public static let accidentalStartMaximumSessionForShortFiles: TimeInterval = 4

    /// Shown when every file is under the 2 s minimum but the session ran
    /// longer than a tap, or capture reported trouble. Keeps the
    /// "recording too short" wording so hosts classify it the same way.
    nonisolated public static let recordingTooShortCaptureStoppedEarlyMessage =
        "Recording too short because audio capture stopped early"

    /// Whether files under the 2 s minimum came from an accidental start:
    /// the host's session clock is known and short, and capture reported
    /// nothing wrong. A missing session clock keeps the visible failure.
    nonisolated static func isAccidentalStartUnderMinimumLength(
        sessionLength: TimeInterval?,
        healthInfo: RecordingHealthInfo?
    ) -> Bool {
        guard let sessionLength,
              sessionLength < accidentalStartMaximumSessionForShortFiles else { return false }
        return hasCleanCaptureHealth(healthInfo)
    }

    /// No gaps, device switches, missing or unusable track, or degraded
    /// capture. A recording with no health report counts as clean.
    nonisolated static func hasCleanCaptureHealth(_ healthInfo: RecordingHealthInfo?) -> Bool {
        guard let healthInfo else { return true }
        return healthInfo.audioGaps == 0
            && healthInfo.deviceSwitches == 0
            && healthInfo.captureQuality != .degraded
            && healthInfo.systemAudioMissing != true
            && healthInfo.microphoneAudioUnusable != true
    }

    /// Whether any of these short files holds sound that rises and falls like
    /// a voice. Unreadable files count as "maybe", so they are never deleted.
    nonisolated static func tracksHaveSpeechLikeSignal(_ urls: [URL]) -> Bool {
        urls.contains { url in
            guard let samples = try? AudioResampler.loadAndResample(url: url, targetRate: 16000) else {
                return true
            }
            return AudioSignalRecovery.hasSpeechLikeModulation(samples: samples, sampleRate: 16000)
        }
    }

    /// Drops a live recording that was started by accident: deletes its
    /// scratch audio and journal, keeps no failed row, and publishes
    /// `.discardedAccidentalStart` so hosts show a cancel instead of an error.
    private func discardAccidentalStart(micURL: URL?, systemURL: URL?, reason: String) {
        if let micURL {
            removeRecordingFile(micURL, label: "accidental-start mic recording")
        }
        if let systemURL {
            removeRecordingFile(systemURL, label: "accidental-start system recording")
        }
        MeetingRecordingJournalStore.removeJournal(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            allowedRoots: cleanupDirectories
        )
        AppLogger.pipeline.info("Discarded an accidental meeting start", ["reason": reason])
        publishNonFailureStatus(.discardedAccidentalStart)
        scheduleStatusReset(delay: 3)
    }

    /// Start a new transcription task for an imported audio file.
    /// Imported files reuse the system-audio speaker path. Early reject gates
    /// (busy / too-short) delete the scratch copy without queueing. Mid-pipeline
    /// failures archive that copy into the failed queue first, then delete scratch.
    public func startImportedTranscription(
        taskId: UUID = UUID(),
        audioURL: URL,
        outputFolder: URL,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        recoverySession: (any ImportedTranscriptionRecoverySession)? = nil,
        languageSelection: TranscriptionLanguageSelection = .automatic
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
        beginTaskLifecycle(taskId: taskId, audio: ActiveTaskAudio(
            micURL: nil,
            systemURL: audioURL,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            importedRecoverySession: recoverySession,
            splitLocalSpeakers: false,
            languageSelection: languageSelection,
            micOnlyByChoice: false
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

                let timings = MeetingPipelineTimings()
                let transcriptURL = try await TranscriptionJobActivity.keepingMacAwake {
                    try await MeetingPipelineTimings.$current.withValue(timings) {
                        try await self.transcribeImportedAudio(
                            audioURL: audioURL,
                            outputFolder: outputFolder,
                            taskId: taskId,
                            meetingTitle: meetingTitle,
                            recordingDate: recordingDate,
                            languageSelection: languageSelection
                        )
                    }
                }

                await MainActor.run {
                    guard !self.finishCancelledTaskIfNeeded(taskId: taskId) else { return }
                    self.publishTranscriptSaved(from: transcriptURL, taskId: taskId, timings: timings.snapshot())
                    self.handleTaskCompletion(taskId: taskId)
                }
            } catch {
                AppLogger.pipeline.error("Imported transcription task failed", [
                    "taskId": taskId.uuidString,
                    "error": error.localizedDescription
                ])

                let errorKind = Self.failureKind(for: error)

                let shouldPreserveFailedAudio = await MainActor.run { () -> Bool in
                    if self.consumePreservedForShutdownMarker(taskId: taskId) {
                        self.handleTaskCompletion(taskId: taskId)
                        return false
                    }
                    if self.finishCancelledTaskIfNeeded(taskId: taskId, error: error) {
                        if self.removeImportedRecordingFile(
                            audioURL,
                            recoverySession: recoverySession,
                            label: "cancelled imported recording"
                        ) {
                            recoverySession?.scratchCleanupConfirmed()
                        }
                        return false
                    }

                    self.publishFailure(Self.failurePresentation(for: error, flow: .importedAudio))
                    return true
                }

                guard shouldPreserveFailedAudio else { return }

                // Archive the imported scratch copy into the failed queue first
                // (system slot + placeholder mic), matching coordinator-preserved
                // imports. AfterArchive deletes the scratch original only after
                // the row is durable. Early-reject gates above still delete
                // without queueing.
                let didPersist = await self.addFailedTranscriptionRetainingAvailableAudioAfterArchive(
                    micAudioURL: nil,
                    systemAudioURL: audioURL,
                    errorMessage: error.localizedDescription,
                    taskId: taskId,
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    errorKind: errorKind,
                    splitLocalSpeakers: false,
                    languageSelection: languageSelection
                )

                await MainActor.run {
                    if didPersist {
                        recoverySession?.failedQueueHandoffConfirmed()
                    }
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
        onReplacementTranscriptCommitted: (@MainActor @Sendable (URL) -> Void)? = nil,
        languageSelection: TranscriptionLanguageSelection? = nil
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

        let (micDuration, systemDuration, hasUsableMicAudio, hasUsableSystemAudio, hasUnknownDuration) =
            audioUsability(micURL: micURL, systemURL: systemURL)

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
        // Saved-audio retranscriptions and failed-row retries reuse already-retained
        // source files, so — like the old `activeTaskAudio` map — this intentionally
        // carries no audio: there is nothing to preserve on shutdown or discard on cancel.
        beginTaskLifecycle(taskId: taskId, audio: nil)
        publishNonFailureStatus(.gettingReady)

        AppLogger.pipeline.info("Starting saved-audio retranscription task", [
            "taskId": taskId.uuidString,
            "activeCount": "\(activeCount)",
            "hasMic": "\(micURL != nil)",
            "splitLocalSpeakers": "\(splitLocalSpeakers)"
        ])

        let asyncTask = Task {
            // Reserve off the main actor. `beginReplacingTranscript` blocks on the shared
            // transcript-file serializer, which a library-wide speaker rename can hold for
            // as long as it takes to rewrite every referencing transcript. Taking that wait
            // on the main actor froze the whole UI until the rename finished. The reservation
            // still lands before any transcript write, so the replacement-vs-speaker-edit
            // barrier is unchanged — only the thread that waits for it moved.
            //
            // Deliberate trade-off: reserving later means a speaker edit submitted in the
            // meantime can now win the queue where the old synchronous call would have
            // beaten it. That is safe — the serializer admits one side or the other, never
            // an interleaved write — and it fails closed with the "already being
            // re-transcribed" message below. A responsive window plus a retryable error
            // beats a frozen window, so do not "fix" this by reserving on the main actor.
            var heldReplacementReservation: ReplacementTranscriptReservationToken?
            var priorSpeakerReviewRequestIds: [UUID: Set<UUID>] = [:]
            defer {
                if let heldReplacementReservation {
                    TranscriptSaver.finishReplacingTranscript(heldReplacementReservation)
                }
            }

            if let replacementTranscriptURL {
                let reservation = await Task.detached(priority: .userInitiated) {
                    TranscriptSaver.beginReplacingTranscript(at: replacementTranscriptURL)
                }.value

                guard let reservation else {
                    // Cancellation is checked first, same as the success and catch exits
                    // below: a cancel landing while the reservation was in flight must
                    // resolve as a cancel, not as a misleading "meeting moved" failure.
                    guard !self.finishCancelledTaskIfNeeded(taskId: taskId) else { return }
                    self.publishFailure(
                        displayMessage: "That meeting moved or is already being re-transcribed. Refresh and try again.",
                        diagnosticMessage: "Replacement transcript unavailable"
                    )
                    self.handleTaskCompletion(taskId: taskId)
                    self.scheduleStatusReset(delay: 4)
                    return
                }
                heldReplacementReservation = reservation
                if let replacementTranscriptId = TranscriptSaver.transcriptIdentity(
                    at: replacementTranscriptURL
                ) {
                    priorSpeakerReviewRequestIds[replacementTranscriptId] =
                        speakerNamingRequestIds(transcriptId: replacementTranscriptId)
                } else {
                    priorSpeakerReviewRequestIds = speakerNamingRequestIds(
                        transcriptURL: replacementTranscriptURL
                    )
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
                    healthInfo: Self.savedMicOnlyHealthInfo(from: replacementTranscriptURL),
                    splitLocalSpeakers: splitLocalSpeakers,
                    meetingTitle: meetingTitle,
                    recordingDate: recordingDate,
                    removeSourceAudioAfterArchive: false,
                    targetTranscriptURL: replacementTranscriptURL,
                    archiveRecordingAudio: replacementTranscriptURL == nil,
                    languageSelection: languageSelection ?? Self.savedLanguageSelection(from: replacementTranscriptURL)
                )

                if replacementTranscriptURL != nil {
                    // Retire only review generations that existed before the
                    // successful replacement. A fresh request enqueued by this
                    // pipeline has a different ID and stays active. On failure or
                    // cancellation this line is never reached, so the old review
                    // remains recoverable.
                    for (transcriptId, requestIds) in priorSpeakerReviewRequestIds {
                        supersedeSpeakerNamingRequests(
                            transcriptId: transcriptId,
                            requestIds: requestIds
                        )
                    }
                }

                // The replacement file is fully committed. Release its writer
                // barrier before publishing the save, because that publication
                // intentionally starts the normal post-save restyle/rename path.
                if let reservation = heldReplacementReservation {
                    TranscriptSaver.finishReplacingTranscript(reservation)
                    heldReplacementReservation = nil
                }

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

    /// A re-transcribed "Record Just My Mic" meeting keeps its `mic_only`
    /// marker; anything else saves no health, as before.
    nonisolated static func savedMicOnlyHealthInfo(from url: URL?) -> RecordingHealthInfo? {
        guard let url,
              let values = try? TranscriptFrontmatter.readValues(from: url),
              values["mic_only"] == "true" else { return nil }
        return .micOnlyByChoiceMarker
    }

    nonisolated static func savedLanguageSelection(from url: URL?) -> TranscriptionLanguageSelection {
        guard let url,
              let values = try? TranscriptFrontmatter.readValues(from: url),
              let rawValue = values["transcription_language"],
              let selection = TranscriptionLanguageSelection(rawValue: rawValue) else { return .automatic }
        return selection
    }
}
