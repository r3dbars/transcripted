import Foundation

// MARK: - Speaker Naming Request Queue

extension TranscriptionTaskManager {

    /// Clean up any tasks stuck in pendingNaming state.
    /// Called from applicationWillTerminate to prevent orphaned audio files.
    public func cleanupPendingNaming() {
        let requests = [speakerNamingRequest].compactMap { $0 }
            + pendingSpeakerNamingRequests
            + Array(deferredSpeakerNamingRequests.values)
        guard !requests.isEmpty else { return }

        TranscriptSaver.serializeTranscriptFileUpdate {
            for request in requests {
                speakerNamingRequestOwnership.invalidate(
                    transcriptId: request.transcriptId,
                    requestId: request.id
                )
            }
        }
        for request in requests {
            cleanupSpeakerNamingRequest(request)
        }
        speakerNamingRequest = nil
        pendingSpeakerNamingRequests.removeAll()
        deferredSpeakerNamingRequests.removeAll()
        speakerReviewProfileProtection.releaseAll()
        AppLogger.pipeline.info("Cleaned up pending naming on shutdown", [
            "count": "\(requests.count)"
        ])
    }

    func enqueueSpeakerNamingRequest(_ request: SpeakerNamingRequest) {
        let duplicateRequests = [speakerNamingRequest].compactMap { $0 }
            .filter { $0.transcriptId == request.transcriptId }
            + pendingSpeakerNamingRequests.filter { $0.transcriptId == request.transcriptId }
            + deferredSpeakerNamingRequests.values.filter {
                $0.transcriptId == request.transcriptId
            }
        if !duplicateRequests.isEmpty {
            let isReplacementGeneration = TranscriptSaver.hasReplacementReservation(
                at: request.transcriptURL
            ) || TranscriptSaver.hasReplacementReservation(
                transcriptId: request.transcriptId
            )
            guard isReplacementGeneration else {
                AppLogger.pipeline.warning("Ignoring duplicate speaker naming request", [
                    "transcriptId": request.transcriptId.uuidString
                ])
                return
            }

            // Keep the previous generation until the replacement task commits.
            // This request becomes the current owner immediately, so an old
            // callback cannot edit the replacement file. If the task rolls back,
            // removing this request reveals the prior owner and review.
        }

        speakerNamingRequestOwnership.install(
            requestId: request.id,
            transcriptId: request.transcriptId,
            transcriptURL: request.transcriptURL
        )
        speakerReviewProfileProtection.protect(request)

        if !duplicateRequests.isEmpty {
            AppLogger.pipeline.info("Superseded speaker review with replacement generation", [
                "transcriptId": request.transcriptId.uuidString
            ])
        }

        guard speakerNamingRequest != nil else {
            speakerNamingRequest = request
            return
        }

        pendingSpeakerNamingRequests.append(request)
        AppLogger.pipeline.info("Queued speaker naming request behind active review", [
            "pending": "\(pendingSpeakerNamingRequests.count)"
        ])
    }

    @discardableResult
    public func deferPendingSpeakerNamingReview(reason: String) -> Bool {
        guard let request = speakerNamingRequest else { return false }
        speakerNamingRequest = nil
        deferredSpeakerNamingRequests[request.id] = request

        AppLogger.pipeline.info("Deferring pending speaker review", [
            "reason": reason,
            "speakers": "\(request.speakers.count)"
        ])
        request.onComplete([])
        return true
    }

    public func hasPendingSpeakerNamingReviewForLastSavedTranscript() -> Bool {
        if let transcriptId = lastSavedTranscriptId,
           hasPendingSpeakerNamingReview(transcriptId: transcriptId) {
            return true
        }

        guard let transcriptURL = lastSavedTranscriptURL else { return false }
        return hasPendingSpeakerNamingReview(transcriptURL: transcriptURL)
    }

    /// A review that still needs answers is on screen or queued. A review
    /// that only lists recognized voices (the island's "who was on the call")
    /// doesn't count: nothing in it needs an answer, so it must not hold back
    /// a failed-meeting retry or an update install.
    public var hasSpeakerReviewAwaitingAnswers: Bool {
        speakerNamingRequest?.asksAboutVoices == true
            || pendingSpeakerNamingRequests.contains { $0.asksAboutVoices }
    }

    public func hasPendingSpeakerNamingReview(transcriptId: UUID) -> Bool {
        speakerNamingRequest?.transcriptId == transcriptId
            || pendingSpeakerNamingRequests.contains { $0.transcriptId == transcriptId }
    }

    public func hasPendingSpeakerNamingReview(transcriptURL: URL) -> Bool {
        let standardizedURL = transcriptURL.standardizedFileURL
        return speakerNamingRequest?.transcriptURL.standardizedFileURL == standardizedURL
            || pendingSpeakerNamingRequests.contains { request in
                request.transcriptURL.standardizedFileURL == standardizedURL
            }
    }

    private func cleanupSpeakerNamingRequest(
        _ request: SpeakerNamingRequest,
        preservingSourceAudio: Bool = false
    ) {
        if !preservingSourceAudio
            && (request.shouldRemoveMicAudioOnCleanup || request.shouldRemoveSystemAudioOnCleanup) {
            if request.importedRecoverySession?.prepareForScratchCleanup() != false {
                let removedMic = !request.shouldRemoveMicAudioOnCleanup
                    || removeManagedCleanupFile(request.micAudioURL, label: "pending mic audio")
                let removedSystem = !request.shouldRemoveSystemAudioOnCleanup
                    || removeManagedCleanupFile(request.systemAudioURL, label: "pending system audio")
                if removedMic && removedSystem {
                    request.importedRecoverySession?.scratchCleanupConfirmed()
                }
            }
        }
        cleanupSpeakerClips(request.speakers + request.recognizedSpeakers)
    }

    func clearCompletedSpeakerNamingRequest(
        transcriptId: UUID,
        requestId: UUID? = nil
    ) {
        TranscriptSaver.serializeTranscriptFileUpdate {
            speakerNamingRequestOwnership.invalidate(
                transcriptId: transcriptId,
                requestId: requestId
            )
        }
        if let requestId {
            speakerReviewProfileProtection.release(requestId: requestId)
        } else {
            speakerReviewProfileProtection.release(transcriptId: transcriptId)
        }
        if speakerNamingRequest?.transcriptId == transcriptId
            && (requestId == nil || speakerNamingRequest?.id == requestId) {
            speakerNamingRequest = nil
        }
        pendingSpeakerNamingRequests.removeAll {
            $0.transcriptId == transcriptId && (requestId == nil || $0.id == requestId)
        }
        if let requestId {
            deferredSpeakerNamingRequests.removeValue(forKey: requestId)
        } else {
            deferredSpeakerNamingRequests = deferredSpeakerNamingRequests.filter {
                $0.value.transcriptId != transcriptId
            }
        }
        promoteNextSpeakerNamingRequestIfNeeded()
    }

    func cancelSpeakerNamingRequest(transcriptId: UUID) {
        removeSpeakerNamingRequests(
            transcriptId: transcriptId,
            requestIds: nil,
            preservingSourceAudio: false
        )
    }

    func cancelSpeakerNamingRequest(transcriptId: UUID, requestId: UUID) {
        removeSpeakerNamingRequests(
            transcriptId: transcriptId,
            requestIds: [requestId],
            preservingSourceAudio: false
        )
    }

    func speakerNamingRequestIds(transcriptId: UUID) -> Set<UUID> {
        var requestIds = Set(([speakerNamingRequest].compactMap { $0 } + pendingSpeakerNamingRequests)
            .filter { $0.transcriptId == transcriptId }
            .map(\.id))
        if let ownedRequestId = speakerNamingRequestOwnership.requestId(transcriptId: transcriptId) {
            requestIds.insert(ownedRequestId)
        }
        return requestIds
    }

    func speakerNamingRequestIds(transcriptURL: URL) -> [UUID: Set<UUID>] {
        let targetURL = transcriptURL.standardizedFileURL
        let matching = ([speakerNamingRequest].compactMap { $0 } + pendingSpeakerNamingRequests)
            .filter { $0.transcriptURL.standardizedFileURL == targetURL }
        var requestIds = Dictionary(grouping: matching, by: \.transcriptId)
            .mapValues { Set($0.map(\.id)) }
        for (transcriptId, ownedRequestIds) in speakerNamingRequestOwnership.requests(
            transcriptURL: transcriptURL
        ) {
            requestIds[transcriptId, default: []].formUnion(ownedRequestIds)
        }
        return requestIds
    }

    func supersedeSpeakerNamingRequests(
        transcriptId: UUID,
        requestIds: Set<UUID>
    ) {
        guard !requestIds.isEmpty else { return }
        removeSpeakerNamingRequests(
            transcriptId: transcriptId,
            requestIds: requestIds,
            preservingSourceAudio: false
        )
    }

    private func removeSpeakerNamingRequests(
        transcriptId: UUID,
        requestIds: Set<UUID>?,
        preservingSourceAudio: Bool
    ) {
        let matchesTarget: (SpeakerNamingRequest) -> Bool = { request in
            request.transcriptId == transcriptId
                && (requestIds.map { $0.contains(request.id) } ?? true)
        }
        let cancelledRequests = [speakerNamingRequest].compactMap { $0 }
            .filter(matchesTarget)
            + pendingSpeakerNamingRequests.filter(matchesTarget)
            + deferredSpeakerNamingRequests.values.filter(matchesTarget)

        TranscriptSaver.serializeTranscriptFileUpdate {
            if let requestIds {
                for requestId in requestIds {
                    speakerNamingRequestOwnership.invalidate(
                        transcriptId: transcriptId,
                        requestId: requestId
                    )
                }
            } else {
                speakerNamingRequestOwnership.invalidate(transcriptId: transcriptId)
            }
        }
        if let requestIds {
            for requestId in requestIds {
                speakerReviewProfileProtection.release(requestId: requestId)
            }
        } else {
            speakerReviewProfileProtection.release(transcriptId: transcriptId)
        }
        if let activeRequest = speakerNamingRequest,
           matchesTarget(activeRequest) {
            speakerNamingRequest = nil
        }
        pendingSpeakerNamingRequests.removeAll(where: matchesTarget)
        deferredSpeakerNamingRequests = deferredSpeakerNamingRequests.filter {
            !matchesTarget($0.value)
        }
        for request in cancelledRequests {
            cleanupSpeakerNamingRequest(
                request,
                preservingSourceAudio: preservingSourceAudio
            )
        }
        promoteNextSpeakerNamingRequestIfNeeded()
    }

    private func promoteNextSpeakerNamingRequestIfNeeded() {
        guard speakerNamingRequest == nil, !pendingSpeakerNamingRequests.isEmpty else { return }
        speakerNamingRequest = pendingSpeakerNamingRequests.removeFirst()
    }

    /// Internal (not private) only so the naming flow can span files.
    nonisolated func cleanupNamingArtifacts(
        clips: [SpeakerNamingEntry],
        micURL: URL?,
        systemURL: URL,
        shouldRemoveMicAudio: Bool,
        shouldRemoveSystemAudio: Bool,
        importedRecoverySession: (any ImportedTranscriptionRecoverySession)? = nil
    ) {
        cleanupSpeakerClips(clips)
        guard shouldRemoveMicAudio || shouldRemoveSystemAudio else { return }
        guard importedRecoverySession?.prepareForScratchCleanup() != false else { return }
        let removedMic = !shouldRemoveMicAudio
            || removeManagedCleanupFile(micURL, label: "mic audio")
        let removedSystem = !shouldRemoveSystemAudio
            || removeManagedCleanupFile(systemURL, label: "system audio")
        if removedMic && removedSystem {
            importedRecoverySession?.scratchCleanupConfirmed()
        }
    }

    nonisolated private func cleanupSpeakerClips(_ clips: [SpeakerNamingEntry]) {
        for clip in clips {
            removeManagedCleanupFile(clip.clipURL, label: "speaker naming clip")
        }
    }
}
