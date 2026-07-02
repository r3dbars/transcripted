import Foundation
import AVFoundation

// MARK: - Pipeline Execution (Multichannel Transcription + Speaker Identification)

extension TranscriptionTaskManager {

    struct SpeakerClassificationKnowledge: Sendable {
        let speakerId: String
        let profile: SpeakerProfile
        let similarity: Double
        /// Runner-up similarity for the auto-accept margin guard; nil when unknown (the
        /// utterance fallback path), which `shouldAutoAccept` treats as "confirm, don't auto".
        let secondSimilarity: Double?
    }

    nonisolated static func speakerClassificationKnowledge(
        speakerIds: [String],
        utterances: [TranscriptionUtterance],
        contexts: [String: ChannelSpeakerContext],
        speakerDB: any SpeakerStore
    ) -> [SpeakerClassificationKnowledge] {
        var knowledge: [SpeakerClassificationKnowledge] = []
        var seenIds: Set<String> = []

        for sid in speakerIds where seenIds.insert(sid).inserted {
            if let context = contexts[sid],
               let snapshot = context.matchedProfileSnapshot,
               let similarity = context.matchSimilarity {
                knowledge.append(SpeakerClassificationKnowledge(
                    speakerId: sid,
                    profile: snapshot,
                    similarity: similarity,
                    secondSimilarity: context.matchSecondSimilarity
                ))
                continue
            }

            if let utterance = utterances.first(where: { String($0.speakerId) == sid }),
               let persistentId = utterance.persistentSpeakerId,
               let similarity = utterance.matchSimilarity,
               let profile = speakerDB.getSpeaker(id: persistentId) {
                knowledge.append(SpeakerClassificationKnowledge(
                    speakerId: sid,
                    profile: profile,
                    similarity: similarity,
                    secondSimilarity: nil   // runner-up not carried on the utterance fallback
                ))
            }
        }

        return knowledge
    }

    nonisolated static func pendingReviewProfileIds(
        systemUtterances: [TranscriptionUtterance],
        micUtterances: [TranscriptionUtterance],
        systemNeedsActionIds: Set<String>,
        micQueuedReviewIds: Set<String>
    ) -> Set<UUID> {
        let systemIds = systemUtterances.compactMap { utterance -> UUID? in
            guard systemNeedsActionIds.contains(String(utterance.speakerId)) else { return nil }
            return utterance.persistentSpeakerId
        }
        let micIds = micUtterances.compactMap { utterance -> UUID? in
            guard micQueuedReviewIds.contains(String(utterance.speakerId)) else { return nil }
            return utterance.persistentSpeakerId
        }
        return Set(systemIds + micIds)
    }

    /// Transcribe a captured meeting using system audio plus optional mic audio.
    /// - Returns: URL of saved transcript with speaker attribution
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated func transcribeWithSpeakerIdentification(
        micURL: URL,
        systemURL: URL?,
        outputFolder: URL,
        taskId: UUID,
        healthInfo: RecordingHealthInfo?,
        splitLocalSpeakers: Bool = false,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        sourceFailedTranscriptionId: UUID? = nil,
        removeSourceAudioAfterArchive: Bool = true
    ) async throws -> URL {

        // Require system audio for multichannel transcription
        guard let systemURL = systemURL else {
            throw PipelineError.missingSystemAudio
        }

        return try await transcribeMultichannelPipeline(
            micURL: micURL,
            systemURL: systemURL,
            outputFolder: outputFolder,
            taskId: taskId,
            healthInfo: healthInfo,
            splitLocalSpeakers: splitLocalSpeakers,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate,
            sourceFailedTranscriptionId: sourceFailedTranscriptionId,
            removeSourceAudioAfterArchive: removeSourceAudioAfterArchive
        )
    }

    /// Transcribe an imported audio file through the system-audio speaker path.
    nonisolated func transcribeImportedAudio(
        audioURL: URL,
        outputFolder: URL,
        taskId: UUID,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil
    ) async throws -> URL {
        try await transcribeMultichannelPipeline(
            micURL: nil,
            systemURL: audioURL,
            outputFolder: outputFolder,
            taskId: taskId,
            healthInfo: nil,
            splitLocalSpeakers: false,
            meetingTitle: meetingTitle,
            recordingDate: recordingDate
        )
    }

    /// Local pipeline: selected STT + PyAnnote diarization → Speaker identification → Save.
    /// When `splitLocalSpeakers` is true, mic-channel diarization runs too, and local
    /// speakers thread through the same classification + naming flow as remote speakers.
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated func transcribeMultichannelPipeline(
        micURL: URL?,
        systemURL: URL,
        outputFolder: URL,
        taskId: UUID,
        healthInfo: RecordingHealthInfo?,
        splitLocalSpeakers: Bool = false,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        sourceFailedTranscriptionId: UUID? = nil,
        removeSourceAudioAfterArchive: Bool = true,
        targetTranscriptURL: URL? = nil,
        archiveRecordingAudio: Bool = true
    ) async throws -> URL {

        let transcription = await MainActor.run { self.transcription }
        try await transcription.ensureModelsReadyForPipeline()

        let speechEngine = await MainActor.run {
            transcription.parakeet.transcriptionEngineDescriptor
        }

        AppLogger.pipeline.info("Using local \(speechEngine.displayName) + PyAnnote pipeline", [
            "splitLocalSpeakers": "\(splitLocalSpeakers)",
            "transcription_engine": speechEngine.identifier
        ])

        // Phase 1: Transcribe with local models
        let result = try await transcription.transcribeMultichannel(
            micURL: micURL,
            systemURL: systemURL,
            splitLocalSpeakers: splitLocalSpeakers,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.displayStatus = .transcribing(progress: progress)
                }
            }
        )

        AppLogger.pipeline.info("Phase 1 complete: Local transcription done", ["micUtterances": "\(result.micUtteranceCount)", "systemUtterances": "\(result.systemUtteranceCount)"])

        // Phase 1.5: Identify speakers from DB knowledge
        var speakerMappings: [String: SpeakerMapping] = [:]
        var speakerSources: [String: String] = [:]  // "db" per speaker ID
        // Build DB knowledge snapshot: what do we already know about these speakers?
        let speakerIds = Array(result.systemSpeakerIds).sorted()
        let speakerDB = await MainActor.run { transcription.speakerDB }
        let dbKnowledge = Self.speakerClassificationKnowledge(
            speakerIds: speakerIds,
            utterances: result.systemUtterances,
            contexts: result.systemSpeakerContexts,
            speakerDB: speakerDB
        )

        // Per-speaker classification: auto-accept high-confidence known speakers,
        // track which ones need naming or confirmation. Recent lifeline outcomes
        // feed the health demotion — a profile with fresh corrections is routed
        // back to confirm even if similarity clears the auto-accept bar.
        var autoAcceptedIds: Set<String> = []
        var needsActionIds: Set<String> = []
        // One indexed LIMIT-N query per profile per run, shared across the
        // system and mic classification passes (the same person can appear on
        // both channels under different diarizer ids).
        var recentOutcomesByProfile: [UUID: [SpeakerMatchOutcomeKind]] = [:]
        func cachedRecentOutcomes(_ profile: SpeakerProfile) -> [SpeakerMatchOutcomeKind] {
            if let cached = recentOutcomesByProfile[profile.id] { return cached }
            let recent = speakerDB.recentMatchOutcomes(
                profileId: profile.id,
                limit: SpeakerProfileHealth.recentOutcomeWindow
            ).map(\.kind)
            recentOutcomesByProfile[profile.id] = recent
            return recent
        }
        // Auto-accepts collected here are written to the lifeline store only
        // after the saved-transcript side effects commit, so a cancelled run
        // (whose transcript gets rolled back) leaves no orphan outcome rows.
        var pendingAutoAccepts: [(knowledge: SpeakerClassificationKnowledge, channel: UtteranceChannel)] = []

        for sid in speakerIds {
            if let entry = dbKnowledge.first(where: { $0.speakerId == sid }) {
                let canAutoAccept = SpeakerNamingPolicy.shouldAutoAccept(
                    profile: entry.profile,
                    similarity: entry.similarity,
                    secondBestSimilarity: entry.secondSimilarity,
                    recentOutcomes: cachedRecentOutcomes(entry.profile)
                )
                if canAutoAccept {
                    autoAcceptedIds.insert(sid)
                    pendingAutoAccepts.append((entry, .system))
                } else {
                    needsActionIds.insert(sid)
                }
            } else {
                // Unknown speaker — check if they at least have a persistent profile
                let hasProfile = result.systemUtterances.contains {
                    String($0.speakerId) == sid && $0.persistentSpeakerId != nil
                }
                if hasProfile {
                    needsActionIds.insert(sid)
                }
            }
        }

        // Auto-accept known speakers: populate mappings from DB without showing naming UI
        var identifiedSpeakers: [IdentifiedSpeaker] = []
        for entry in dbKnowledge {
            let key = "system_\(entry.speakerId)"
            let mapping = SpeakerNamingPolicy.initialMapping(
                speakerId: entry.speakerId,
                profile: entry.profile,
                similarity: entry.similarity,
                secondBestSimilarity: entry.secondSimilarity,
                recentOutcomes: recentOutcomesByProfile[entry.profile.id] ?? []
            )
            speakerMappings[key] = mapping
            speakerSources[key] = autoAcceptedIds.contains(entry.speakerId) ? "db" : "db_pending"

            if autoAcceptedIds.contains(entry.speakerId),
               let name = entry.profile.displayName {
                let confidence = SpeakerNamingPolicy.confidence(
                    similarity: entry.similarity,
                    callCount: entry.profile.callCount
                )
                identifiedSpeakers.append(IdentifiedSpeaker(
                    name: name,
                    speakerId: entry.speakerId,
                    confidence: confidence,
                    evidence: "Voice fingerprint match (\(String(format: "%.0f", entry.similarity * 100))%, \(entry.profile.callCount) calls)"
                ))
            }
        }

        AppLogger.speakers.info("Per-speaker classification", [
            "autoAccepted": "\(autoAcceptedIds.count)",
            "needsAction": "\(needsActionIds.count)",
            "total": "\(speakerIds.count)"
        ])

        // Phase 1.6: Parallel classification for MIC speakers when local-speaker split ran.
        // Mirrors the system-speaker block above but scoped to mic utterances.
        var micNeedsActionIds: Set<String> = []
        var micAutoAcceptedIds: Set<String> = []
        if splitLocalSpeakers && result.micPersistentSpeakerIds.count > 0 {
            let micSpeakerIds = Array(result.micSpeakerIds).sorted()
            let micDbKnowledge = Self.speakerClassificationKnowledge(
                speakerIds: micSpeakerIds,
                utterances: result.micUtterances,
                contexts: result.micSpeakerContexts,
                speakerDB: speakerDB
            )

            for sid in micSpeakerIds {
                if let entry = micDbKnowledge.first(where: { $0.speakerId == sid }) {
                    let canAutoAccept = SpeakerNamingPolicy.shouldAutoAccept(
                        profile: entry.profile,
                        similarity: entry.similarity,
                        secondBestSimilarity: entry.secondSimilarity,
                        recentOutcomes: cachedRecentOutcomes(entry.profile)
                    )
                    if canAutoAccept {
                        micAutoAcceptedIds.insert(sid)
                        // Mic speakers still flow through the review sheet when
                        // local split ran with audio (the section shows every mic
                        // voice), so their verdicts arrive from the coordinator —
                        // recording an auto-accept row too would double-count the
                        // same match. Only record when no mic review will happen.
                        if micURL == nil {
                            pendingAutoAccepts.append((entry, .mic))
                        }
                    } else {
                        micNeedsActionIds.insert(sid)
                    }
                } else {
                    let hasProfile = result.micUtterances.contains {
                        String($0.speakerId) == sid && $0.persistentSpeakerId != nil
                    }
                    if hasProfile {
                        micNeedsActionIds.insert(sid)
                    }
                }
            }

            for entry in micDbKnowledge {
                let key = "mic_\(entry.speakerId)"
                let mapping = SpeakerNamingPolicy.initialMapping(
                    speakerId: entry.speakerId,
                    profile: entry.profile,
                    similarity: entry.similarity,
                    secondBestSimilarity: entry.secondSimilarity,
                    recentOutcomes: recentOutcomesByProfile[entry.profile.id] ?? []
                )
                speakerMappings[key] = mapping
                speakerSources["mic_\(entry.speakerId)"] = micAutoAcceptedIds.contains(entry.speakerId) ? "db" : "db_pending"
            }

            AppLogger.speakers.info("Per-mic-speaker classification", [
                "autoAccepted": "\(micAutoAcceptedIds.count)",
                "needsAction": "\(micNeedsActionIds.count)",
                "total": "\(micSpeakerIds.count)"
            ])
        }

        let queuedMicReviewIds: Set<String>
        if splitLocalSpeakers && micURL != nil && !result.micPersistentSpeakerIds.isEmpty {
            queuedMicReviewIds = result.micSpeakerIds
        } else {
            queuedMicReviewIds = micNeedsActionIds
        }
        let protectedReviewProfileIds = Self.pendingReviewProfileIds(
            systemUtterances: result.systemUtterances,
            micUtterances: result.micUtterances,
            systemNeedsActionIds: needsActionIds,
            micQueuedReviewIds: queuedMicReviewIds
        )

        // Clean up speaker profiles without deleting IDs still referenced by pending review rows.
        speakerDB.mergeDuplicates(protecting: protectedReviewProfileIds)
        speakerDB.pruneWeakProfiles()

        // Build diarizer-channel-qualified speaker key → persistent DB UUID mapping for YAML.
        // Keyed "system_0" / "mic_0" so mic and system speakers with the same diarizer
        // index don't collide in the single dictionary.
        var speakerDbIds: [String: UUID] = [:]
        for utterance in result.systemUtterances {
            let key = "system_\(utterance.speakerId)"
            if let pid = utterance.persistentSpeakerId, speakerDbIds[key] == nil {
                speakerDbIds[key] = pid
            }
        }
        for utterance in result.micUtterances {
            let key = "mic_\(utterance.speakerId)"
            if let pid = utterance.persistentSpeakerId, speakerDbIds[key] == nil {
                speakerDbIds[key] = pid
            }
        }

        // Keep placeholder labels tied to persistent speaker UUIDs so later confirmation
        // and retroactive renames can update the same person cleanly.
        for key in speakerDbIds.keys where speakerMappings[key] == nil {
            let sid = key.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true).last.map(String.init) ?? key
            speakerMappings[key] = SpeakerMapping(speakerId: sid)
            if speakerSources[key] == nil {
                speakerSources[key] = "db_pending"
            }
        }

        let replacementTranscriptRollback = try ReplacementTranscriptRollback.capture(for: targetTranscriptURL)
        let transcriptId = replacementTranscriptRollback?.transcriptId ?? UUID()
        try Task.checkCancellation()
        // Phase 2: Save transcript with speaker names
        let notifier: TranscriptNotifier? = await MainActor.run {
            self.displayStatus = .finishing
            return self.notifier
        }
        let formatOptions = await MainActor.run {
            self.resolvedTranscriptFormatOptions(hasMicAudio: micURL != nil)
        }

        let transcriptDate = recordingDate ?? Date()
        guard let savedURL = TranscriptSaver.saveTranscript(
            result,
            transcriptId: transcriptId,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            directory: outputFolder,
            meetingTitle: meetingTitle,
            healthInfo: healthInfo,
            notifier: nil,
            speakerStore: speakerDB,
            statsStore: DeferredTranscriptStatsStore(),
            recordingDate: transcriptDate,
            targetURL: targetTranscriptURL,
            transcriptionEngine: speechEngine,
            formatOptions: formatOptions
        ) else {
            throw PipelineError.saveFailed(detail: "Could not write transcript to \(outputFolder.lastPathComponent)")
        }
        let deleteSavedTranscriptOnCancellation = replacementTranscriptRollback == nil
        try await checkCancellationAfterTranscriptSideEffects(
            savedURL: savedURL,
            deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
            replacementTranscriptRollback: replacementTranscriptRollback
        )

        AppLogger.pipeline.info("Phase 2 complete: Transcript saved", ["file": savedURL.lastPathComponent])

        // Record the silent auto-recognitions in the lifeline store so
        // speaker-stats, health demotion, and the app's bucketed analytics can
        // see them. Deferred until the saved-transcript side effects commit so
        // a cancelled run cannot leave outcome rows for a rolled-back
        // transcript. Review verdicts are recorded separately by the naming
        // coordinator when the review sheet is submitted.
        func recordPendingAutoAcceptOutcomes() {
            speakerDB.recordMatchOutcomes(pendingAutoAccepts.map { pending in
                SpeakerMatchOutcome(
                    profileId: pending.knowledge.profile.id,
                    kind: .autoAccepted,
                    similarity: pending.knowledge.similarity,
                    secondSimilarity: pending.knowledge.secondSimilarity,
                    callCountAtMatch: pending.knowledge.profile.callCount,
                    channel: pending.channel.rawValue,
                    transcriptId: transcriptId
                )
            })
        }

        let archiveOutcome = archiveRecordingAudio
            ? await archiveRecordingAudioIfConfigured(
                micURL: micURL,
                systemURL: systemURL,
                savedURL: savedURL
            )
            : RecordingAudioArchiveOutcome(
                didArchiveRecordingAudio: false,
                retainedAudioDirectory: nil,
                retainedAudioURLs: []
            )
        try await checkCancellationAfterTranscriptSideEffects(
            savedURL: savedURL,
            retainedAudioDirectory: archiveOutcome.retainedAudioDirectory,
            retainedAudioURLs: archiveOutcome.retainedAudioURLs,
            deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
            replacementTranscriptRollback: replacementTranscriptRollback
        )
        let shouldRemoveScratchAudio = archiveOutcome.didArchiveRecordingAudio && removeSourceAudioAfterArchive

        // Phase 3: Speaker naming — for system speakers that need action, plus any mic
        // speakers surfaced by local-speaker split. Entries from both channels flow
        // through the same SpeakerNamingSheet (grouped by channel in the UI).
        var namingEntries: [SpeakerNamingEntry] = []

        if !needsActionIds.isEmpty {
            do {
                let actionUtterances = result.systemUtterances.filter {
                    needsActionIds.contains(String($0.speakerId))
                }
                let clips = try SpeakerClipExtractor.extractClips(
                    sourceAudioURL: systemURL,
                    utterances: actionUtterances,
                    channel: .system,
                    speakerDB: speakerDB,
                    clipsDirectory: transcription.speakerClipsDirectory
                )
                for clip in clips {
                    let context = result.systemSpeakerContexts[clip.diarizerSpeakerId]
                    namingEntries.append(SpeakerNamingEntry(
                        id: clip.persistentSpeakerId,
                        diarizerSpeakerId: clip.diarizerSpeakerId,
                        channel: .system,
                        clipURL: clip.clipURL,
                        sampleText: clip.sampleText,
                        currentName: clip.currentName,
                        matchSimilarity: clip.matchSimilarity,
                        matchSecondSimilarity: context?.matchSecondSimilarity,
                        callCount: context?.matchedProfileSnapshot?.callCount ?? 0,
                        needsNaming: clip.currentName == nil,
                        needsConfirmation: clip.currentName != nil,
                        sessionEmbedding: context?.sessionEmbedding,
                        matchedProfileSnapshot: context?.matchedProfileSnapshot
                    ))
                }
            } catch {
                AppLogger.pipeline.warning("System clip extraction failed, skipping system naming", ["error": error.localizedDescription])
            }
            try await checkCancellationAfterTranscriptSideEffects(
                savedURL: savedURL,
                retainedAudioDirectory: archiveOutcome.retainedAudioDirectory,
                retainedAudioURLs: archiveOutcome.retainedAudioURLs,
                speakerClipURLs: namingEntries.map(\.clipURL),
                deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
                replacementTranscriptRollback: replacementTranscriptRollback
            )
        }

        // Mic-channel naming — surface every mic speaker with a persistent profile so the
        // user can name them or collapse the group via "Keep as You". We intentionally
        // don't filter to "needs action" on the mic side: if local split ran and produced
        // multiple speakers, the user should always see the section so they can decide.
        if splitLocalSpeakers && !result.micPersistentSpeakerIds.isEmpty, let micURL {
            do {
                let micUtterancesWithProfiles = result.micUtterances.filter {
                    $0.persistentSpeakerId != nil
                }
                let micClips = try SpeakerClipExtractor.extractClips(
                    sourceAudioURL: micURL,
                    utterances: micUtterancesWithProfiles,
                    channel: .mic,
                    speakerDB: speakerDB,
                    clipsDirectory: transcription.speakerClipsDirectory
                )
                for clip in micClips {
                    let context = result.micSpeakerContexts[clip.diarizerSpeakerId]
                    namingEntries.append(SpeakerNamingEntry(
                        id: clip.persistentSpeakerId,
                        diarizerSpeakerId: clip.diarizerSpeakerId,
                        channel: .mic,
                        clipURL: clip.clipURL,
                        sampleText: clip.sampleText,
                        currentName: clip.currentName,
                        matchSimilarity: clip.matchSimilarity,
                        matchSecondSimilarity: context?.matchSecondSimilarity,
                        callCount: context?.matchedProfileSnapshot?.callCount ?? 0,
                        needsNaming: clip.currentName == nil,
                        needsConfirmation: clip.currentName != nil,
                        sessionEmbedding: context?.sessionEmbedding,
                        matchedProfileSnapshot: context?.matchedProfileSnapshot
                    ))
                }
            } catch {
                AppLogger.pipeline.warning("Mic clip extraction failed, skipping mic naming", ["error": error.localizedDescription])
            }
            try await checkCancellationAfterTranscriptSideEffects(
                savedURL: savedURL,
                retainedAudioDirectory: archiveOutcome.retainedAudioDirectory,
                retainedAudioURLs: archiveOutcome.retainedAudioURLs,
                speakerClipURLs: namingEntries.map(\.clipURL),
                deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
                replacementTranscriptRollback: replacementTranscriptRollback
            )
        }

        if !namingEntries.isEmpty {
            // Seed knownPeople with existing named DB profiles so the sheet's combobox has
            // suggestions. Previously this was always empty — users typed blind.
            let allProfiles = speakerDB.allSpeakers()
            let knownPeople: [SpeakerIdentityOption] = allProfiles
                .compactMap { profile in
                    guard let name = profile.displayName, !name.isEmpty else { return nil }
                    return SpeakerIdentityOption(
                        id: profile.id,
                        displayName: name,
                        callCount: profile.callCount
                    )
                }
            // The auto-recognition roster shown as the review sheet's payoff
            // line. Shares the exact policy predicate (including lifeline
            // health) with the auto-accept gate so the sheet never promises
            // recognition the pipeline would refuse.
            let recognizedPeopleCount = allProfiles.filter { profile in
                guard profile.displayName?.isEmpty == false, profile.callCount > 4 else {
                    return false
                }
                return SpeakerNamingPolicy.isAutoRecognizable(
                    profile: profile,
                    recentOutcomes: cachedRecentOutcomes(profile)
                )
            }.count

            let capturedEntries = namingEntries
            try await checkCancellationAfterTranscriptSideEffects(
                savedURL: savedURL,
                retainedAudioDirectory: archiveOutcome.retainedAudioDirectory,
                retainedAudioURLs: archiveOutcome.retainedAudioURLs,
                speakerClipURLs: capturedEntries.map(\.clipURL),
                deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
                replacementTranscriptRollback: replacementTranscriptRollback
            )
            await MainActor.run {
                self.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
                    speakers: capturedEntries,
                    knownPeople: knownPeople,
                    recognizedPeopleCount: recognizedPeopleCount,
                    transcriptURL: savedURL,
                    transcriptId: transcriptId,
                    systemAudioURL: systemURL,
                    micAudioURL: micURL,
                    shouldRemoveTemporaryAudioOnCleanup: shouldRemoveScratchAudio && sourceFailedTranscriptionId == nil,
                    sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                    onComplete: { [weak self] updates in
                        self?.handleNamingComplete(
                            updates: updates,
                            transcriptURL: savedURL,
                            transcriptId: transcriptId,
                            transcriptionResult: result,
                            micURL: micURL,
                            systemURL: systemURL,
                            shouldRemoveTemporaryAudio: shouldRemoveScratchAudio,
                            sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                            clips: capturedEntries
                        )
                    }
                ))
            }
            try await checkCancellationAfterTranscriptSideEffects(
                savedURL: savedURL,
                retainedAudioDirectory: archiveOutcome.retainedAudioDirectory,
                retainedAudioURLs: archiveOutcome.retainedAudioURLs,
                speakerClipURLs: capturedEntries.map(\.clipURL),
                queuedSpeakerRequestTranscriptId: transcriptId,
                deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
                replacementTranscriptRollback: replacementTranscriptRollback
            )
            try await commitSavedTranscriptSideEffectsUnlessCancelled(
                taskId: taskId,
                savedURL: savedURL,
                result: result,
                transcriptId: transcriptId,
                meetingTitle: meetingTitle,
                transcriptDate: transcriptDate,
                notifier: notifier,
                retainedAudioDirectory: archiveOutcome.retainedAudioDirectory,
                retainedAudioURLs: archiveOutcome.retainedAudioURLs,
                speakerClipURLs: capturedEntries.map(\.clipURL),
                queuedSpeakerRequestTranscriptId: transcriptId,
                deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
                replacementTranscriptRollback: replacementTranscriptRollback
            )
            recordPendingAutoAcceptOutcomes()

            AppLogger.pipeline.info("Speaker naming requested", [
                "total": "\(namingEntries.count)",
                "mic": "\(namingEntries.filter { $0.channel == .mic }.count)",
                "system": "\(namingEntries.filter { $0.channel == .system }.count)"
            ])
            return savedURL
        }

        try await commitSavedTranscriptSideEffectsUnlessCancelled(
            taskId: taskId,
            savedURL: savedURL,
            result: result,
            transcriptId: transcriptId,
            meetingTitle: meetingTitle,
            transcriptDate: transcriptDate,
            notifier: notifier,
            retainedAudioDirectory: archiveOutcome.retainedAudioDirectory,
            retainedAudioURLs: archiveOutcome.retainedAudioURLs,
            deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
            replacementTranscriptRollback: replacementTranscriptRollback
        )
        recordPendingAutoAcceptOutcomes()

        // No naming needed — clean up scratch audio after the saved outcome has
        // committed, so a late cancellation cannot delete transcript + retained
        // audio after scratch files are gone.
        if shouldRemoveScratchAudio, sourceFailedTranscriptionId == nil {
            removeManagedCleanupFile(micURL, label: "completed mic scratch")
            removeManagedCleanupFile(systemURL, label: "completed system scratch")
        }

        return savedURL
    }

    private struct RecordingAudioArchiveOutcome {
        let didArchiveRecordingAudio: Bool
        let retainedAudioDirectory: URL?
        let retainedAudioURLs: [URL]
    }

    private struct ReplacementTranscriptRollback: Sendable {
        let url: URL
        let originalData: Data
        private let originalFileDates: OriginalFileDates?
        let transcriptId: UUID?

        static func capture(for targetURL: URL?) throws -> ReplacementTranscriptRollback? {
            guard let targetURL else { return nil }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue else {
                return nil
            }

            let originalData = try Data(contentsOf: targetURL)
            let originalFileDates = OriginalFileDates.capture(for: targetURL)
            let values = try? TranscriptFrontmatter.readValues(from: targetURL)
            let transcriptId = replacementTranscriptId(from: values)
            return ReplacementTranscriptRollback(
                url: targetURL,
                originalData: originalData,
                originalFileDates: originalFileDates,
                transcriptId: transcriptId
            )
        }

        func restore() {
            do {
                try originalData.write(to: url, options: .atomic)
                FileManager.default.restrictToOwnerOnly(atPath: url.path)
                originalFileDates?.restore(to: url)
            } catch {
                AppLogger.pipeline.error("Failed to restore cancelled replacement transcript", [
                    "error": error.localizedDescription
                ])
            }
        }

        private struct OriginalFileDates: Sendable {
            let creationDate: Date?
            let modificationDate: Date?

            static func capture(for url: URL) -> OriginalFileDates? {
                guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
                    return nil
                }

                return OriginalFileDates(
                    creationDate: attributes[.creationDate] as? Date,
                    modificationDate: attributes[.modificationDate] as? Date
                )
            }

            func restore(to url: URL) {
                var attributes: [FileAttributeKey: Any] = [:]
                if let creationDate {
                    attributes[.creationDate] = creationDate
                }
                if let modificationDate {
                    attributes[.modificationDate] = modificationDate
                }
                guard !attributes.isEmpty else { return }

                do {
                    try FileManager.default.setAttributes(attributes, ofItemAtPath: url.path)
                } catch {
                    AppLogger.pipeline.warning("Failed to restore replacement rollback file dates", [
                        "error_type": String(describing: type(of: error))
                    ])
                }
            }
        }

        private static func replacementTranscriptId(from values: [String: String]?) -> UUID? {
            values.flatMap(TranscriptFrontmatter.captureID(in:))
        }
    }

    nonisolated private func archiveRecordingAudioIfConfigured(
        micURL: URL?,
        systemURL: URL,
        savedURL: URL
    ) async -> RecordingAudioArchiveOutcome {
        let retainedAudioDirectory = await MainActor.run { self.resolvedRetainedAudioDirectory() }
        guard let retainedAudioDirectory else {
            return RecordingAudioArchiveOutcome(
                didArchiveRecordingAudio: true,
                retainedAudioDirectory: nil,
                retainedAudioURLs: []
            )
        }

        do {
            let retainedAudio = try RecordingAudioArchiver.archive(
                micURL: micURL,
                systemURL: systemURL,
                transcriptURL: savedURL,
                archiveRoot: retainedAudioDirectory
            )
            AppLogger.pipeline.info("Retained meeting audio files", [
                "hasMic": "\(retainedAudio.micURL != nil)",
                "hasSystem": "\(retainedAudio.systemURL != nil)"
            ])
            return RecordingAudioArchiveOutcome(
                didArchiveRecordingAudio: true,
                retainedAudioDirectory: retainedAudio.directory,
                retainedAudioURLs: [retainedAudio.micURL, retainedAudio.systemURL].compactMap { $0 }
            )
        } catch {
            AppLogger.pipeline.warning("Failed to retain meeting audio; leaving scratch files in place", [
                "hasMic": "\(micURL != nil)",
                "hasSystem": "true",
                "errorType": "\(type(of: error))"
            ])
            return RecordingAudioArchiveOutcome(
                didArchiveRecordingAudio: false,
                retainedAudioDirectory: nil,
                retainedAudioURLs: []
            )
        }
    }

    private func commitSavedTranscriptSideEffects(
        savedURL: URL,
        result: TranscriptionResult,
        transcriptId: UUID,
        meetingTitle: String?,
        transcriptDate: Date,
        notifier: TranscriptNotifier?
    ) {
        if let notifier {
            Task { @MainActor in
                notifier.notifyTranscriptSaved(fileURL: savedURL)
            }
        }

        let metadata = StatsService.createMetadata(
            from: result,
            captureId: transcriptId,
            transcriptPath: savedURL.path,
            title: meetingTitle,
            date: transcriptDate
        )
        (statsStore ?? StatsDatabase.shared).recordSession(metadata)
    }

    private func commitSavedTranscriptSideEffectsUnlessCancelled(
        taskId: UUID,
        savedURL: URL,
        result: TranscriptionResult,
        transcriptId: UUID,
        meetingTitle: String?,
        transcriptDate: Date,
        notifier: TranscriptNotifier?,
        retainedAudioDirectory: URL? = nil,
        retainedAudioURLs: [URL] = [],
        speakerClipURLs: [URL] = [],
        queuedSpeakerRequestTranscriptId: UUID? = nil,
        deleteSavedTranscriptOnCancellation: Bool = true,
        replacementTranscriptRollback: ReplacementTranscriptRollback? = nil
    ) async throws {
        try await checkCancellationAfterTranscriptSideEffects(
            savedURL: savedURL,
            retainedAudioDirectory: retainedAudioDirectory,
            retainedAudioURLs: retainedAudioURLs,
            speakerClipURLs: speakerClipURLs,
            queuedSpeakerRequestTranscriptId: queuedSpeakerRequestTranscriptId,
            deleteSavedTranscriptOnCancellation: deleteSavedTranscriptOnCancellation,
            replacementTranscriptRollback: replacementTranscriptRollback
        )

        let didCommit = await MainActor.run {
            guard canCommitTaskSideEffects(taskId: taskId) else {
                if let queuedSpeakerRequestTranscriptId {
                    cancelSpeakerNamingRequest(transcriptId: queuedSpeakerRequestTranscriptId)
                }
                return false
            }

            commitSavedTranscriptSideEffects(
                savedURL: savedURL,
                result: result,
                transcriptId: transcriptId,
                meetingTitle: meetingTitle,
                transcriptDate: transcriptDate,
                notifier: notifier
            )
            markTaskTranscriptCommitted(taskId: taskId)
            return true
        }

        guard didCommit else {
            cleanupCancelledTranscriptSideEffects(
                savedURL: savedURL,
                retainedAudioDirectory: retainedAudioDirectory,
                retainedAudioURLs: retainedAudioURLs,
                speakerClipURLs: speakerClipURLs,
                deleteSavedTranscript: deleteSavedTranscriptOnCancellation,
                replacementTranscriptRollback: replacementTranscriptRollback
            )
            throw CancellationError()
        }
    }

    private func checkCancellationAfterTranscriptSideEffects(
        savedURL: URL,
        retainedAudioDirectory: URL? = nil,
        retainedAudioURLs: [URL] = [],
        speakerClipURLs: [URL] = [],
        queuedSpeakerRequestTranscriptId: UUID? = nil,
        deleteSavedTranscriptOnCancellation: Bool = true,
        replacementTranscriptRollback: ReplacementTranscriptRollback? = nil
    ) async throws {
        do {
            try Task.checkCancellation()
        } catch {
            if let queuedSpeakerRequestTranscriptId {
                await MainActor.run {
                    cancelSpeakerNamingRequest(transcriptId: queuedSpeakerRequestTranscriptId)
                }
            }
            cleanupCancelledTranscriptSideEffects(
                savedURL: savedURL,
                retainedAudioDirectory: retainedAudioDirectory,
                retainedAudioURLs: retainedAudioURLs,
                speakerClipURLs: speakerClipURLs,
                deleteSavedTranscript: deleteSavedTranscriptOnCancellation,
                replacementTranscriptRollback: replacementTranscriptRollback
            )
            throw error
        }
    }

    nonisolated private func cleanupCancelledTranscriptSideEffects(
        savedURL: URL,
        retainedAudioDirectory: URL?,
        retainedAudioURLs: [URL],
        speakerClipURLs: [URL],
        deleteSavedTranscript: Bool,
        replacementTranscriptRollback: ReplacementTranscriptRollback?
    ) {
        if let replacementTranscriptRollback {
            replacementTranscriptRollback.restore()
        } else if deleteSavedTranscript {
            try? FileManager.default.removeItem(at: savedURL)
        }
        for retainedAudioURL in retainedAudioURLs {
            try? FileManager.default.removeItem(at: retainedAudioURL)
        }
        if let retainedAudioDirectory {
            let remaining = (try? FileManager.default.contentsOfDirectory(
                at: retainedAudioDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            if remaining.isEmpty {
                try? FileManager.default.removeItem(at: retainedAudioDirectory)
            }
        }
        for clipURL in speakerClipURLs {
            try? FileManager.default.removeItem(at: clipURL)
        }
        AppLogger.pipeline.info("Cleaned cancelled transcription side effects", [
            "transcript": savedURL.lastPathComponent,
            "transcriptRemoved": "\(deleteSavedTranscript)",
            "clips": "\(speakerClipURLs.count)",
            "retainedAudioFiles": "\(retainedAudioURLs.count)",
            "retainedAudio": retainedAudioDirectory == nil ? "false" : "true"
        ])
    }

}

@available(macOS 14.0, *)
private struct DeferredTranscriptStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}
    func getTotalRecordingsCount() -> Int { 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }
    func recordingExists(transcriptPath: String) -> Bool { false }
}
