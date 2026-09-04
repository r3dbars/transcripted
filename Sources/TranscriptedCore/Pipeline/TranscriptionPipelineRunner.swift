import Foundation
import AVFoundation

// MARK: - Pipeline Execution (Multichannel Transcription + Speaker Identification)

extension TranscriptionTaskManager {

    struct SavedTranscriptAudioResolution: Sendable {
        let includesMicrophone: Bool
        let includesSystemAudio: Bool
        let healthInfo: RecordingHealthInfo?
    }

    /// Resolve partial-success audio channels before formatting and retention.
    /// Unusable channels are excluded from source metadata and mark the artifact
    /// degraded. A failed mic keeps flowing through archival for future retry;
    /// a corrupt/short system file is excluded from retained playback.
    nonisolated static func savedTranscriptAudioResolution(
        microphoneURLWasProvided: Bool,
        microphoneOutcome: TranscriptionResult.MicrophoneAudioOutcome,
        systemOutcome: TranscriptionResult.SystemAudioOutcome = .usable,
        healthInfo: RecordingHealthInfo?
    ) -> SavedTranscriptAudioResolution {
        let includesMicrophone = microphoneURLWasProvided && microphoneOutcome != .unusable
        let includesSystemAudio = systemOutcome == .usable
        var resolvedHealth = healthInfo
        if microphoneURLWasProvided && microphoneOutcome == .unusable {
            resolvedHealth = (resolvedHealth ?? .perfect).markingMicrophoneAudioUnusable()
        }
        if systemOutcome == .unusable {
            resolvedHealth = (resolvedHealth ?? .perfect).markingSystemAudioMissing()
        }
        return SavedTranscriptAudioResolution(
            includesMicrophone: includesMicrophone,
            includesSystemAudio: includesSystemAudio,
            healthInfo: resolvedHealth
        )
    }

    struct SpeakerClassificationKnowledge: Sendable {
        let speakerId: String
        let profile: SpeakerProfile
        let similarity: Double
        /// Runner-up similarity for the auto-accept margin guard; nil when unknown (the
        /// utterance fallback path), which `shouldAutoAccept` treats as "confirm, don't auto".
        let secondSimilarity: Double?
        /// Winner's average-only cosine and the runner-up's average-only cosine, when carried by
        /// the match context. Feed `SpeakerNamingPolicy.shouldAutoAccept`'s `marginSimilarities`
        /// so the auto-accept margin is judged on the blended average, not the best exemplar.
        let averageSimilarity: Double?
        let secondAverageSimilarity: Double?

        /// Average-based margin pair for `shouldAutoAccept`, or nil to fall back to the legacy
        /// (exemplar) margin when the average sims weren't carried (e.g. utterance fallback).
        var marginSimilarities: (best: Double, secondBest: Double)? {
            guard let best = averageSimilarity, let second = secondAverageSimilarity else { return nil }
            return (best: best, secondBest: second)
        }
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
                    secondSimilarity: context.matchSecondSimilarity,
                    averageSimilarity: context.matchAverageSimilarity,
                    secondAverageSimilarity: context.matchSecondBestAverageSimilarity
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
                    secondSimilarity: nil,   // runner-up not carried on the utterance fallback
                    averageSimilarity: nil,
                    secondAverageSimilarity: nil
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
        micURL: URL?,
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

        guard let systemURL else {
            guard let micURL else {
                throw PipelineError.invalidAudioFormat(detail: "No meeting audio files were available")
            }
            let micExists = FileManager.default.fileExists(atPath: micURL.path)
            return try await transcribeMicrophoneOnlyPipeline(
                micURL: micURL,
                outputFolder: outputFolder,
                taskId: taskId,
                healthInfo: healthInfo,
                meetingTitle: meetingTitle,
                recordingDate: recordingDate,
                sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                removeSourceAudioAfterArchive: removeSourceAudioAfterArchive,
                splitLocalSpeakers: splitLocalSpeakers && micExists
            )
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

    nonisolated func transcribeMicrophoneOnlyPipeline(
        micURL: URL,
        outputFolder: URL,
        taskId: UUID,
        healthInfo: RecordingHealthInfo?,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        sourceFailedTranscriptionId: UUID? = nil,
        removeSourceAudioAfterArchive: Bool = true,
        splitLocalSpeakers: Bool = false
    ) async throws -> URL {
        let transcription = await MainActor.run { self.transcription }
        try await transcription.ensureModelsReadyForPipeline()

        let speechEngine = await MainActor.run {
            transcription.parakeet.transcriptionEngineDescriptor
        }

        AppLogger.pipeline.info("Using local \(speechEngine.displayName) mic-only recovery pipeline", [
            "transcription_engine": speechEngine.identifier
        ])

        let result = try await transcription.transcribeMicrophoneOnly(
            micURL: micURL,
            splitLocalSpeakers: splitLocalSpeakers,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.displayStatus = .transcribing(progress: progress)
                }
            }
        )

        let replacementTranscriptRollback = try ReplacementTranscriptRollback.capture(for: nil)
        let transcriptId = UUID()
        try Task.checkCancellation()

        let notifier: TranscriptNotifier? = await MainActor.run {
            self.displayStatus = .finishing
            return self.notifier
        }
        let formatOptions = await MainActor.run {
            self.resolvedTranscriptFormatOptions(hasMicAudio: true, hasSystemAudio: false)
        }

        let transcriptDate = recordingDate ?? Date()
        let micOnlyHealth = healthInfo?.markingSystemAudioMissing()
            ?? RecordingHealthInfo(
                captureQuality: .degraded,
                audioGaps: 0,
                deviceSwitches: 0,
                gapDescriptions: [],
                systemAudioMissing: true,
                qualityReason: .systemAudioMissing
            )
        guard let savedURL = TranscriptSaver.saveTranscript(
            result,
            transcriptId: transcriptId,
            speakerMappings: [:],
            speakerSources: [:],
            speakerDbIds: [:],
            directory: outputFolder,
            meetingTitle: meetingTitle,
            healthInfo: micOnlyHealth,
            notifier: nil,
            speakerStore: nil,
            statsStore: DeferredTranscriptStatsStore(),
            recordingDate: transcriptDate,
            transcriptionEngine: speechEngine,
            formatOptions: formatOptions
        ) else {
            throw PipelineError.saveFailed(detail: "Could not write mic-only transcript to \(outputFolder.lastPathComponent)")
        }
        let rollback = PipelineRollbackRegistry()
        Self.registerSavedTranscriptRollback(
            savedURL: savedURL,
            replacementTranscriptRollback: replacementTranscriptRollback,
            into: rollback
        )
        try await rollback.checkCancellation()

        let archiveOutcome = await archiveRecordingAudioIfConfigured(
            micURL: micURL,
            systemURL: nil,
            savedURL: savedURL
        )
        Self.registerRetainedAudioRollback(
            directory: archiveOutcome.retainedAudioDirectory,
            urls: archiveOutcome.retainedAudioURLs,
            into: rollback
        )
        try await rollback.checkCancellation()

        try await commitSavedTranscriptSideEffectsUnlessCancelled(
            taskId: taskId,
            savedURL: savedURL,
            result: result,
            transcriptId: transcriptId,
            meetingTitle: meetingTitle,
            transcriptDate: transcriptDate,
            notifier: notifier,
            rollback: rollback
        )

        if archiveOutcome.canRemoveMicScratch && removeSourceAudioAfterArchive && sourceFailedTranscriptionId == nil {
            removeManagedCleanupFile(micURL, label: "completed mic-only scratch")
        }

        return savedURL
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
            recordingDate: recordingDate,
            stableTranscriptId: taskId
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
        archiveRecordingAudio: Bool = true,
        stableTranscriptId: UUID? = nil
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
                    recentOutcomes: cachedRecentOutcomes(entry.profile),
                    marginSimilarities: entry.marginSimilarities
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
        for entry in dbKnowledge {
            let key = "system_\(entry.speakerId)"
            let mapping = SpeakerNamingPolicy.initialMapping(
                speakerId: entry.speakerId,
                profile: entry.profile,
                similarity: entry.similarity,
                secondBestSimilarity: entry.secondSimilarity,
                recentOutcomes: recentOutcomesByProfile[entry.profile.id] ?? [],
                marginSimilarities: entry.marginSimilarities
            )
            speakerMappings[key] = mapping
            speakerSources[key] = autoAcceptedIds.contains(entry.speakerId) ? "db" : "db_pending"
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
                        recentOutcomes: cachedRecentOutcomes(entry.profile),
                        marginSimilarities: entry.marginSimilarities
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
                    recentOutcomes: recentOutcomesByProfile[entry.profile.id] ?? [],
                    marginSimilarities: entry.marginSimilarities
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
        let transcriptId = replacementTranscriptRollback?.transcriptId
            ?? stableTranscriptId
            ?? UUID()
        try Task.checkCancellation()
        // Phase 2: Save transcript with speaker names
        let notifier: TranscriptNotifier? = await MainActor.run {
            self.displayStatus = .finishing
            return self.notifier
        }
        let savedAudio = Self.savedTranscriptAudioResolution(
            microphoneURLWasProvided: micURL != nil,
            microphoneOutcome: result.microphoneAudioOutcome,
            systemOutcome: result.systemAudioOutcome,
            healthInfo: healthInfo
        )
        let formatOptions = await MainActor.run {
            self.resolvedTranscriptFormatOptions(
                hasMicAudio: savedAudio.includesMicrophone,
                hasSystemAudio: savedAudio.includesSystemAudio
            )
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
            healthInfo: savedAudio.healthInfo,
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
        let rollback = PipelineRollbackRegistry()
        Self.registerSavedTranscriptRollback(
            savedURL: savedURL,
            replacementTranscriptRollback: replacementTranscriptRollback,
            into: rollback
        )
        try await rollback.checkCancellation()

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
                systemURL: savedAudio.includesSystemAudio ? systemURL : nil,
                savedURL: savedURL
            )
            : RecordingAudioArchiveOutcome(
                canRemoveMicScratch: false,
                canRemoveSystemScratch: false,
                retainedAudioDirectory: nil,
                retainedAudioURLs: []
            )
        Self.registerRetainedAudioRollback(
            directory: archiveOutcome.retainedAudioDirectory,
            urls: archiveOutcome.retainedAudioURLs,
            into: rollback
        )
        try await rollback.checkCancellation()
        let shouldRemoveMicScratchAudio = archiveOutcome.canRemoveMicScratch && removeSourceAudioAfterArchive
        let shouldRemoveSystemScratchAudio = archiveOutcome.canRemoveSystemScratch && removeSourceAudioAfterArchive
        let shouldRemoveAllScratchAudio = shouldRemoveMicScratchAudio && shouldRemoveSystemScratchAudio

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
                Self.registerSpeakerClipsRollback(clips.map(\.clipURL), channel: "system", into: rollback)
            } catch {
                AppLogger.pipeline.warning("System clip extraction failed, skipping system naming", ["error": error.localizedDescription])
            }
            try await rollback.checkCancellation()
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
                Self.registerSpeakerClipsRollback(micClips.map(\.clipURL), channel: "mic", into: rollback)
            } catch {
                AppLogger.pipeline.warning("Mic clip extraction failed, skipping mic naming", ["error": error.localizedDescription])
            }
            try await rollback.checkCancellation()
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
                return SpeakerNamingPolicy.isAutoRecognizable(
                    profile: profile,
                    recentOutcomes: cachedRecentOutcomes(profile)
                )
            }.count

            let capturedEntries = namingEntries
            let speakerNamingRequestId = UUID()
            try await rollback.checkCancellation()
            await MainActor.run {
                let importedRecoverySession = self.importedRecoverySession(
                    taskId: taskId
                )
                self.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
                    id: speakerNamingRequestId,
                    speakers: capturedEntries,
                    knownPeople: knownPeople,
                    recognizedPeopleCount: recognizedPeopleCount,
                    transcriptURL: savedURL,
                    transcriptId: transcriptId,
                    systemAudioURL: systemURL,
                    micAudioURL: micURL,
                    shouldRemoveTemporaryAudioOnCleanup: shouldRemoveAllScratchAudio && sourceFailedTranscriptionId == nil,
                    shouldRemoveMicAudioOnCleanup: shouldRemoveMicScratchAudio && sourceFailedTranscriptionId == nil,
                    shouldRemoveSystemAudioOnCleanup: shouldRemoveSystemScratchAudio && sourceFailedTranscriptionId == nil,
                    sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                    importedRecoverySession: importedRecoverySession,
                    onComplete: { [weak self] updates in
                        self?.handleNamingComplete(
                            updates: updates,
                            transcriptURL: savedURL,
                            transcriptId: transcriptId,
                            transcriptionResult: result,
                            micURL: micURL,
                            systemURL: systemURL,
                            splitLocalSpeakers: splitLocalSpeakers,
                            shouldRemoveTemporaryAudio: shouldRemoveAllScratchAudio,
                            shouldRemoveMicAudio: shouldRemoveMicScratchAudio,
                            shouldRemoveSystemAudio: shouldRemoveSystemScratchAudio,
                            sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                            clips: capturedEntries,
                            importedRecoverySession: importedRecoverySession,
                            requestId: speakerNamingRequestId
                        )
                    }
                ))
            }
            // Snapshot a strong local before the actor hop instead of capturing `[weak self]`
            // into this closure: `self` isn't Sendable, so a weak capture that then crosses into
            // a nested `@Sendable` MainActor closure warns today and is a hard error under
            // Swift 6. The registry only ever lives for the duration of this call, so there is no
            // retain-cycle risk in capturing strongly here — unlike `onComplete` above, which is
            // handed off to a request object that can outlive this function.
            let manager = self
            rollback.register {
                await manager.cancelSpeakerNamingRequest(
                    transcriptId: transcriptId,
                    requestId: speakerNamingRequestId
                )
                AppLogger.pipeline.info("Rollback: cancelled queued speaker naming request", [
                    "transcriptId": transcriptId.uuidString
                ])
            }
            try await rollback.checkCancellation()
            try await commitSavedTranscriptSideEffectsUnlessCancelled(
                taskId: taskId,
                savedURL: savedURL,
                result: result,
                transcriptId: transcriptId,
                meetingTitle: meetingTitle,
                transcriptDate: transcriptDate,
                notifier: notifier,
                rollback: rollback
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
            rollback: rollback
        )
        recordPendingAutoAcceptOutcomes()

        // No naming needed — clean up scratch audio after the saved outcome has
        // committed, so a late cancellation cannot delete transcript + retained
        // audio after scratch files are gone.
        if (shouldRemoveMicScratchAudio || shouldRemoveSystemScratchAudio),
           sourceFailedTranscriptionId == nil {
            let cleanupPrepared = await MainActor.run {
                self.prepareImportedTranscriptionScratchCleanup(taskId: taskId)
            }
            if cleanupPrepared {
                let removedMic = !shouldRemoveMicScratchAudio
                    || removeManagedCleanupFile(micURL, label: "completed mic scratch")
                let removedSystem = !shouldRemoveSystemScratchAudio
                    || removeManagedCleanupFile(systemURL, label: "completed system scratch")
                if removedMic && removedSystem {
                    await MainActor.run {
                        self.confirmImportedTranscriptionScratchCleanup(taskId: taskId)
                    }
                }
            }
        }

        return savedURL
    }

    private struct RecordingAudioArchiveOutcome {
        let canRemoveMicScratch: Bool
        let canRemoveSystemScratch: Bool
        let retainedAudioDirectory: URL?
        let retainedAudioURLs: [URL]
    }

    /// Not `private`: exercised directly (via `@testable import`) by pipeline-rollback tests
    /// that drive `registerSavedTranscriptRollback` through both its delete and restore branches
    /// without re-running the whole async pipeline. Still internal-only — outside the module
    /// boundary this stays invisible, same as before.
    struct ReplacementTranscriptRollback: Sendable {
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
        systemURL: URL?,
        savedURL: URL
    ) async -> RecordingAudioArchiveOutcome {
        let retainedAudioDirectory = await MainActor.run { self.resolvedRetainedAudioDirectory() }
        guard let retainedAudioDirectory else {
            return RecordingAudioArchiveOutcome(
                // Retention is disabled, so the committed transcript is the
                // terminal owner and both scratch sources can follow the
                // existing cleanup path.
                canRemoveMicScratch: true,
                canRemoveSystemScratch: true,
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
            let archivedEveryProvidedSource = (micURL == nil || retainedAudio.micURL != nil)
                && (systemURL == nil || retainedAudio.systemURL != nil)
            if !archivedEveryProvidedSource {
                AppLogger.pipeline.warning("Retained only part of the meeting audio; leaving scratch files in place", [
                    "micArchived": "\(retainedAudio.micURL != nil)",
                    "systemArchived": "\(retainedAudio.systemURL != nil)"
                ])
            }
            AppLogger.pipeline.info("Retained meeting audio files", [
                "hasMic": "\(retainedAudio.micURL != nil)",
                "hasSystem": "\(retainedAudio.systemURL != nil)"
            ])
            return RecordingAudioArchiveOutcome(
                // Clean only a source with a durable retained copy. If the
                // other copy failed, its original remains available for the
                // bounded temp/recovery path instead of making both successful
                // and failed sources permanent scratch orphans.
                canRemoveMicScratch: micURL == nil || retainedAudio.micURL != nil,
                canRemoveSystemScratch: systemURL == nil || retainedAudio.systemURL != nil,
                retainedAudioDirectory: retainedAudio.directory,
                retainedAudioURLs: [retainedAudio.micURL, retainedAudio.systemURL].compactMap { $0 }
            )
        } catch {
            AppLogger.pipeline.warning("Failed to retain meeting audio; leaving scratch files in place", [
                "hasMic": "\(micURL != nil)",
                "hasSystem": "\(systemURL != nil)",
                "errorType": "\(type(of: error))"
            ])
            return RecordingAudioArchiveOutcome(
                canRemoveMicScratch: false,
                canRemoveSystemScratch: false,
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

        let metadata = RecordingMetadata.from(
            result: result,
            captureId: transcriptId,
            transcriptPath: savedURL.path,
            title: meetingTitle,
            date: transcriptDate
        )
        (statsStore ?? StatsDatabase.shared).recordSession(metadata)
    }

    /// Not `private`: the "superseded task" branch below (`canCommitTaskSideEffects` returning
    /// false without any `Task.checkCancellation()` throw) is exercised directly by
    /// `PipelineRollbackRegistryManagerTests` so that scenario is tested against the real
    /// method instead of only inferred from `PipelineRollbackRegistry`'s generic behavior.
    func commitSavedTranscriptSideEffectsUnlessCancelled(
        taskId: UUID,
        savedURL: URL,
        result: TranscriptionResult,
        transcriptId: UUID,
        meetingTitle: String?,
        transcriptDate: Date,
        notifier: TranscriptNotifier?,
        rollback: PipelineRollbackRegistry
    ) async throws {
        try await rollback.checkCancellation()

        // Not a Task-cancellation rollback — a separate "did something else already claim this
        // task's side effects" check (e.g. superseded by a retry). Still routes through the same
        // registry so it undoes exactly what checkCancellation() would have.
        let didCommit = await MainActor.run {
            guard canCommitTaskSideEffects(taskId: taskId) else { return false }

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
            await rollback.rollbackAll()
            throw CancellationError()
        }
    }

    /// Registers the saved-transcript rollback: restore the pre-existing file when this
    /// run replaced one in place, otherwise delete the newly saved file. The two were
    /// always tied together 1:1 at every previous call site (`deleteSavedTranscriptOnCancellation
    /// = (replacementTranscriptRollback == nil)`), so that derivation is folded directly into
    /// the branch here instead of being re-computed and re-threaded by each caller.
    nonisolated static func registerSavedTranscriptRollback(
        savedURL: URL,
        replacementTranscriptRollback: ReplacementTranscriptRollback?,
        into rollback: PipelineRollbackRegistry
    ) {
        if let replacementTranscriptRollback {
            rollback.register {
                replacementTranscriptRollback.restore()
            }
        } else {
            rollback.register {
                try? FileManager.default.removeItem(at: savedURL)
                AppLogger.pipeline.info("Rollback: deleted saved transcript", ["file": savedURL.lastPathComponent])
            }
        }
    }

    /// Registers the retained-audio rollback: remove the archived audio files, then remove
    /// the archive directory if that leaves it empty. No-op when nothing was archived.
    nonisolated static func registerRetainedAudioRollback(
        directory: URL?,
        urls: [URL],
        into rollback: PipelineRollbackRegistry
    ) {
        guard directory != nil || !urls.isEmpty else { return }
        rollback.register {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            if let directory {
                let remaining = (try? FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )) ?? []
                if remaining.isEmpty {
                    try? FileManager.default.removeItem(at: directory)
                }
            }
            AppLogger.pipeline.info("Rollback: removed retained meeting audio", [
                "files": "\(urls.count)",
                "directoryRemoved": "\(directory != nil)"
            ])
        }
    }

    /// Registers the rollback for one channel's freshly extracted speaker clips. No-op when
    /// extraction produced nothing (matches today's behavior of only ever removing clips that
    /// actually exist).
    nonisolated static func registerSpeakerClipsRollback(
        _ urls: [URL],
        channel: String,
        into rollback: PipelineRollbackRegistry
    ) {
        guard !urls.isEmpty else { return }
        rollback.register {
            for url in urls {
                try? FileManager.default.removeItem(at: url)
            }
            AppLogger.pipeline.info("Rollback: removed extracted speaker clips", [
                "channel": channel,
                "count": "\(urls.count)"
            ])
        }
    }

}

/// Accumulates undo closures for side effects performed while one transcription pipeline run
/// (`transcribeMultichannelPipeline` / `transcribeMicrophoneOnlyPipeline`) progresses, so a late
/// cancellation rolls back exactly what has happened without every checkpoint re-stating a
/// growing "what to clean up if cancelled" parameter list. Each side effect registers its own
/// undo as it happens; `checkCancellation()` runs them (most-recently-registered first) only if
/// the run is actually cancelled at that point.
///
/// Created fresh per pipeline run and only ever driven by that run's single sequential `async`
/// call chain — never handed to a concurrent Task or shared across runs. `@unchecked Sendable`
/// here just satisfies the compiler for the awaited hops between the pipeline's `nonisolated`
/// code and its `@MainActor` helpers; it is not asserting safety under real concurrent access.
final class PipelineRollbackRegistry: @unchecked Sendable {
    private var undos: [() async -> Void] = []

    /// Register an undo for a side effect that just happened. Undos run in LIFO order — most
    /// recently registered first — mirroring "last thing done, first thing undone".
    func register(_ undo: @escaping () async -> Void) {
        undos.append(undo)
    }

    /// Checks for cancellation. If cancelled, rolls back every registered undo and rethrows.
    func checkCancellation() async throws {
        do {
            try Task.checkCancellation()
        } catch {
            await rollbackAll()
            throw error
        }
    }

    /// Runs every registered undo (most-recently-registered first), then clears the registry.
    /// Idempotent: undos are consumed as they run, so a second call is a no-op.
    func rollbackAll() async {
        guard !undos.isEmpty else { return }
        let pending = Array(undos.reversed())
        undos.removeAll()
        AppLogger.pipeline.info("Rolling back pipeline side effects", ["steps": "\(pending.count)"])
        for undo in pending {
            await undo()
        }
    }
}

@available(macOS 14.0, *)
private struct DeferredTranscriptStatsStore: StatsStore {
    func recordSession(_ metadata: RecordingMetadata) {}
    func getTotalRecordingsCount() -> Int { 0 }
    func getRecordings(from startDate: Date, to endDate: Date) -> [RecordingMetadata] { [] }
    func recordingExists(transcriptPath: String) -> Bool { false }
}
