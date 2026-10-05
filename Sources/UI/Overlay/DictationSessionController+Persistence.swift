// DictationSessionController+Persistence.swift
// Saving dictation transcripts, the session-cap save, and stopped-audio cleanup.

import AppKit

extension DictationSessionController {
    /// Finalize a dictation by saving it to the daily Markdown file without
    /// pasting into the focused app or auto-sending. Used by the 5-minute
    /// session cap so a walked-away session is recovered instead of discarded.
    func finalizeWithoutPaste(
        text: String,
        appState: TranscriptedAppState,
        overlayController: FloatingOverlayController,
        sessionID: UUID
    ) async {
        lastCompletedText = text
        let recovery = stoppedAudioRecovery
        let saveContext = dictationSaveContext(text: text)
        let delivery = DictationSessionCapSavePolicy.delivery
        let saveTask = startPersistingDictationTranscript(text: text, delivery: delivery, recovery: recovery)
        let saveResult = await saveTask.value
        publishDictationTranscriptPersistence(saveResult, delivery: delivery, context: saveContext)
        guard DictationSessionCompletionPolicy.canPublish(
            sessionID: sessionID, currentSessionID: currentDictationSessionID,
            isDictating: isDictating, cancelled: Task.isCancelled
        ) else { return }
        if saveResult.saved != nil, stoppedAudioRecovery == recovery {
            stoppedAudioRecovery = nil
        }
        let saveFailureMessage = saveResult.failureMessage
        let wordCount = text.split(whereSeparator: \.isWhitespace).count
        let durationSeconds = CFAbsoluteTimeGetCurrent() - sessionStartTime
        appState.logger.log("DICTATION | session cap reached, saved \(text.count) chars without pasting")
        DiagnosticsTrail.record(
            logger: appState.logger,
            level: saveFailureMessage == nil ? .info : .warning,
            engine: "dictation",
            event: "dictation_session_cap_saved",
            message: saveFailureMessage == nil
                ? "Dictation auto-saved at session cap without pasting"
                : "Dictation session cap save failed",
            context: dictationContext(
                extra: [
                    "dictation_session_id": sessionID.uuidString,
                    "trigger": currentDictationTrigger.rawValue,
                    "chars": "\(text.count)",
                    "words": "\(wordCount)",
                    "duration_ms": "\(Int(durationSeconds * 1000))",
                    "save_failed": "\(saveFailureMessage != nil)"
                ]
            )
        )
        let completionProperties = DictationSessionCapCompletionTelemetryPolicy.completionProperties(
            saveSucceeded: saveResult.saved != nil,
            durationBucket: AnalyticsReporter.durationBucket(seconds: durationSeconds),
            trigger: currentDictationTrigger.rawValue,
            wordCountBucket: AnalyticsReporter.wordCountBucket(wordCount)
        )
        AnalyticsReporter.track(
            "dictation_completed",
            properties: dictationAnalyticsProperties(extra: completionProperties)
        )
        // Hitting the 5-minute cap still saved the text: a notice, not an
        // error with a warning triangle and a shake.
        let pasteLastShortcut = PhysicalDictationTriggerPreferences.displayString(
            for: PhysicalDictationTriggerPreferences.pasteLastDictationBinding()
        )
        switch DictationSessionCapSavePolicy.presentation(
            saveFailureMessage: saveFailureMessage,
            pasteLastShortcut: pasteLastShortcut
        ) {
        case .error(let message):
            overlayController.showError(message)
        case .savedNotice(let message, let actionTitle):
            overlayController.showSavedNotice(
                message,
                actionTitle: actionTitle,
                action: { [weak self] in
                    guard let self else { return }
                    switch DictationSessionCapSavePolicy.pasteItResult(self.pasteWithClipboardRestore(text)) {
                    case .pasted:
                        overlayController.showSuccessAndDismiss(title: "Pasted")
                    case .error(let message):
                        overlayController.showError(message)
                    }
                }
            )
        }
        isDictating = false
        appState.runtimeDiagnostics.clearSession(
            kind: "dictation",
            outcome: saveFailureMessage == nil ? "session_cap_saved" : "session_cap_save_failed"
        )
    }

    @discardableResult
    func persistDictationTranscript(
        text: String,
        delivery: DictationDelivery,
        context: [String: String]
    ) -> DictationTranscriptPersistenceResult {
        let result = DictationTranscriptPersistenceResult.measure {
            try DictationTranscriptWriter.save(
                text: text, sourceAppName: sessionSourceApp?.localizedName ?? "Unknown",
                sourceBundleID: sessionSourceApp?.bundleIdentifier, delivery: delivery
            )
        }
        publishDictationTranscriptPersistence(result, delivery: delivery, context: context)
        return result
    }

    func discardStoppedAudioRecovery(
        transcriptPersisted: Bool = false,
        explicitDiscard: Bool = false
    ) {
        guard DictationStoppedAudioRecoveryStore.cleanup(
            stoppedAudioRecovery,
            transcriptPersisted: transcriptPersisted,
            explicitDiscard: explicitDiscard
        ) else { return }
        stoppedAudioRecovery = nil
    }

    func startPersistingDictationTranscript(
        text: String,
        delivery: DictationDelivery,
        recovery: DictationStoppedAudioRecovery?
    ) -> Task<DictationTranscriptPersistenceResult, Never> {
        let sourceAppName = sessionSourceApp?.localizedName ?? "Unknown"
        let sourceBundleID = sessionSourceApp?.bundleIdentifier

        return Task.detached(priority: .utility) {
            let result = DictationTranscriptPersistenceResult.measure {
                try DictationTranscriptWriter.save(
                    text: text,
                    sourceAppName: sourceAppName,
                    sourceBundleID: sourceBundleID,
                    delivery: delivery
                )
            }
            // Clean only this writer's checkpoint, even if a new session has started.
            DictationStoppedAudioRecoveryStore.retire(recovery, afterSaving: result)
            return result
        }
    }

    func publishDictationTranscriptPersistence(
        _ result: DictationTranscriptPersistenceResult,
        delivery: DictationDelivery,
        context: [String: String]
    ) {
        // Artifact notifications are global; diagnostics must retain the saving session's context.
        if let saved = result.saved {
            recordDictationTranscriptSaved(saved, delivery: delivery, context: context)
            // A committed artifact is useful even after cancellation or a new take.
            // Read the saving session's snapshot, never the controller's current session.
            let durationBucket = context["duration_bucket"] ?? "unknown"
            let wordCountBucket = context["word_count_bucket"] ?? "unknown"
            let trigger = context["trigger"] ?? DictationTrigger.unknown.rawValue
            let correlationID = context["correlation_id"]
            let artifactExists = ActivationTelemetry.trackDictationArtifactSaved(
                saved: saved,
                delivery: delivery.rawValue,
                durationBucket: durationBucket,
                trigger: trigger,
                wordCountBucket: wordCountBucket,
                correlationID: correlationID
            )
            if artifactExists {
                ActivationTelemetry.trackFirstArtifactSavedIfNeeded(
                    artifactKind: .dictation,
                    surface: .dictationSave,
                    trigger: trigger,
                    wordCountBucket: wordCountBucket,
                    durationBucket: durationBucket,
                    correlationID: correlationID,
                    savedAt: Date(timeIntervalSinceReferenceDate: result.finishedAt)
                )
                trackOnboardingFirstDictationSavedIfNeeded(delivery: delivery, wordCountBucket: wordCountBucket)
            }
            NotificationCenter.default.post(name: .dictationTranscriptDidSave, object: saved.url)
        } else if let error = result.failureError {
            recordDictationTranscriptSaveFailed(error, context: context)
        }
    }

    func dictationSaveContext(text: String) -> [String: String] {
        dictationContext(extra: [
            "duration_bucket": AnalyticsReporter.durationBucket(seconds: CFAbsoluteTimeGetCurrent() - sessionStartTime),
            "word_count_bucket": AnalyticsReporter.wordCountBucket(text.split(whereSeparator: \.isWhitespace).count),
        ])
    }

    private func recordDictationTranscriptSaved(
        _ saved: SavedDictationTranscript,
        delivery: DictationDelivery,
        context: [String: String]
    ) {
        appState?.logger.log("DICTATION | saved markdown export at \(saved.url.lastPathComponent)")
        DiagnosticsTrail.record(
            logger: appState?.logger,
            engine: "dictation",
            event: "dictation_export_saved",
            message: "Saved dictation markdown export",
            context: context.merging(["delivery": delivery.rawValue]) { _, new in new }
        )
    }

    func trackOnboardingFirstDictationSavedIfNeeded(
        delivery: DictationDelivery,
        wordCountBucket: String
    ) {
        guard PermissionsOnboardingPreferences.markFirstDictationSavedTrackedIfNeeded() else { return }

        AnalyticsReporter.track(
            "onboarding_first_dictation_saved",
            properties: [
                "delivery": delivery.rawValue,
                // The 3-step onboarding (2026-08) has no dictation-test step;
                // "done" is the stable stage a first dictation follows.
                "step_id": "done",
                "word_count_bucket": wordCountBucket,
            ]
        )
    }

    private func recordDictationTranscriptSaveFailed(_ error: Error, context: [String: String]) {
        appState?.logger.log("DICTATION | failed to save markdown export: \(error.localizedDescription)")
        DiagnosticsTrail.record(
            logger: appState?.logger,
            level: .warning,
            engine: "dictation",
            event: "dictation_export_failed",
            message: "Failed to save dictation markdown export",
            context: context.merging(["error": error.localizedDescription]) { _, new in new }
        )
    }
}
