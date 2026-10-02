import Foundation

// MARK: - Speaker Naming Finish

extension TranscriptionTaskManager {

    @MainActor func finishNamingFlow(
        didFinalizeTranscript: Bool,
        failure: SpeakerFinalizationFailure? = nil,
        updatesCount: Int,
        transcriptId: UUID,
        resolvedURL: URL,
        micURL: URL?,
        systemURL: URL,
        sourceFailedTranscriptionId: UUID? = nil,
        splitLocalSpeakers: Bool = false,
        importedRecoverySession: (any ImportedTranscriptionRecoverySession)? = nil,
        shouldDeleteSourceFailedAudio: Bool = true,
        requestId: UUID? = nil
    ) -> NamingFlowFinishOutcome {
        // Failure publication also belongs to the request generation. A replacement
        // can finish between the background attempt and this MainActor handoff.
        if let requestId, !speakerNamingRequestOwnership.isCurrent(
            requestId: requestId, transcriptId: transcriptId
        ) {
            return .superseded
        }
        if didFinalizeTranscript {
            // A title/style rename can queue behind transcript finalization and move the file
            // before this MainActor handoff runs. Resolve and consume metadata in one serialized
            // transaction so UI bookkeeping never publishes the stale pre-rename URL.
            let publicationAttempt = TranscriptSaver.serializeTranscriptFileUpdate {
                    if let requestId,
                       !speakerNamingRequestOwnership.isCurrent(
                        requestId: requestId,
                        transcriptId: transcriptId
                       ) {
                        return (
                            metadata: Optional<(resolvedURL: URL, didAlreadyPublish: Bool)>.none,
                            superseded: true
                        )
                    }
                    guard let currentURL = TranscriptSaver.resolveTranscriptURL(
                        resolvedURL,
                        transcriptId: transcriptId
                    ) else {
                        return (
                            metadata: Optional<(resolvedURL: URL, didAlreadyPublish: Bool)>.none,
                            superseded: false
                        )
                    }

                    let didAlreadyPublish = lastSavedTranscriptId == transcriptId
                        || lastSavedTranscriptURL == currentURL
                    populateSavedMetadata(from: currentURL)
                    return (
                        metadata: Optional.some((
                            resolvedURL: currentURL,
                            didAlreadyPublish: didAlreadyPublish
                        )),
                        superseded: false
                    )
                }

            guard !publicationAttempt.superseded else { return .superseded }
            let metadataPublication = publicationAttempt.metadata

            guard let metadataPublication else {
                AppLogger.pipeline.error("Speaker naming metadata publication failed", [
                    "transcriptId": transcriptId.uuidString,
                    "transcript": resolvedURL.lastPathComponent
                ])
                let retryError = "Speaker names were saved, but the finalized transcript could not be found. Retry audio was preserved."
                let retryId = sourceFailedTranscriptionId ?? transcriptId
                let didPersistRetry = persistNamingFailureRetry(
                    id: retryId,
                    transcriptURL: resolvedURL,
                    micURL: micURL,
                    systemURL: systemURL,
                    splitLocalSpeakers: splitLocalSpeakers,
                    errorMessage: retryError
                )
                if didPersistRetry {
                    importedRecoverySession?.failedQueueHandoffConfirmed()
                    publishSpeakerFinalizationFailure(
                        displayMessage: "Final transcript could not be found. Retry audio was kept.",
                        failure: nil
                    )
                } else {
                    AppLogger.pipeline.error("Speaker naming retry queue persistence failed", [
                        "transcriptId": transcriptId.uuidString,
                        "retryId": retryId.uuidString
                    ])
                    publishSpeakerFinalizationFailure(
                        displayMessage: "Final transcript could not be found. Retry could not be saved; audio was left in place.",
                        failure: nil
                    )
                }
                scheduleStatusReset(delay: 8)
                return .metadataPublicationFailed
            }

            AppLogger.pipeline.info("Speaker naming complete", [
                "named": "\(updatesCount)",
                "transcript": metadataPublication.resolvedURL.lastPathComponent
            ])
            if let sourceFailedTranscriptionId {
                if shouldDeleteSourceFailedAudio {
                    failedTranscriptionManager.deleteFailedTranscription(id: sourceFailedTranscriptionId)
                } else {
                    failedTranscriptionManager.removeFailedTranscription(id: sourceFailedTranscriptionId)
                }
            }
            if !metadataPublication.didAlreadyPublish {
                publishSpeakerNamesSaved()
                scheduleStatusReset(delay: 8)
            } else {
                clearSpeakerFinalizationFailure()
            }
            return .completed
        } else {
            AppLogger.pipeline.error("Speaker naming finalization failed", [
                "transcriptId": transcriptId.uuidString,
                "transcript": resolvedURL.lastPathComponent,
                "reason": failure?.reason.rawValue ?? "unknown"
            ])
            let didPersistRetry = persistNamingFailureRetry(
                id: sourceFailedTranscriptionId ?? transcriptId,
                transcriptURL: resolvedURL,
                micURL: micURL,
                systemURL: systemURL,
                splitLocalSpeakers: splitLocalSpeakers,
                errorMessage: "Speaker names could not be saved. Retry to rebuild the meeting and save the names."
            )
            if didPersistRetry {
                importedRecoverySession?.failedQueueHandoffConfirmed()
            }
            publishSpeakerFinalizationFailure(
                displayMessage: didPersistRetry
                    ? "Failed to finalize speaker names"
                    : "Speaker names could not be saved. Retry could not be saved; audio was left in place.",
                failure: failure
            )
            scheduleStatusReset(delay: 8)
            return .transcriptFinalizationFailed
        }
    }

    @MainActor private func persistNamingFailureRetry(
        id: UUID,
        transcriptURL: URL,
        micURL: URL?,
        systemURL: URL,
        splitLocalSpeakers: Bool,
        errorMessage: String
    ) -> Bool {
        if failedTranscriptionManager.failedTranscriptions.contains(where: { $0.id == id }) {
            let didUpdate = failedTranscriptionManager.updateFailedTranscriptionError(
                id: id,
                errorMessage: errorMessage
            )
            if !didUpdate {
                // The pre-existing durable row remains actionable even if its diagnostic
                // could not be refreshed. Treating it as absent would create duplicates.
                AppLogger.pipeline.warning("Speaker naming retry diagnostic update failed", [
                    "retryId": id.uuidString
                ])
            }
            return true
        }

        let values = TranscriptSaver.serializeTranscriptFileUpdate {
            let currentURL = TranscriptSaver.resolveTranscriptURL(transcriptURL, transcriptId: id)
                ?? transcriptURL
            return (try? TranscriptFrontmatter.readValues(from: currentURL)) ?? [:]
        }
        return addFailedTranscriptionRetainingAvailableAudio(
            micAudioURL: micURL,
            systemAudioURL: systemURL,
            errorMessage: errorMessage,
            taskId: id,
            meetingTitle: values["title"],
            recordingDate: TranscriptFrontmatter.recordedAt(values: values),
            archiveAudio: false,
            splitLocalSpeakers: splitLocalSpeakers,
            micOnlyByChoice: values["mic_only"] == "true"
        )
    }
}
