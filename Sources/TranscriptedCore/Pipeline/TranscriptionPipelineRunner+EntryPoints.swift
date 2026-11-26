import Foundation
import AVFoundation

// MARK: - Pipeline entry points (speaker knowledge, microphone-only, imported audio)

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
        removeSourceAudioAfterArchive: Bool = true,
        languageSelection: TranscriptionLanguageSelection = .automatic
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
                splitLocalSpeakers: splitLocalSpeakers && micExists,
                languageSelection: languageSelection
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
            removeSourceAudioAfterArchive: removeSourceAudioAfterArchive,
            languageSelection: languageSelection
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
        splitLocalSpeakers: Bool = false,
        languageSelection: TranscriptionLanguageSelection = .automatic
    ) async throws -> URL {
        let transcription = await MainActor.run { self.transcription }
        try await transcription.ensureModelsReadyForPipeline()

        let speechEngine = await MainActor.run {
            transcription.parakeet.transcriptionEngineDescriptor
        }

        AppLogger.pipeline.info("Using local \(speechEngine.displayName) mic-only recovery pipeline", [
            "splitLocalSpeakers": "\(splitLocalSpeakers)",
            "transcription_engine": speechEngine.identifier
        ])

        let speakerDB = await MainActor.run { transcription.speakerDB }
        let speakerThresholds = await MainActor.run { transcription.diarization.activeSpeakerThresholds }
        let lineupProvider = await MainActor.run { self.lineupNamingProvider }
        let invitedNameKeys: Set<String>
        let lineupIsFromInvite: Bool
        if splitLocalSpeakers, let request = await lineupProvider?(recordingDate) {
            let profilesBefore = speakerDB.allSpeakers()
            invitedNameKeys = SpeakerNamingPolicy.lineupNameKeys(request, profilesBeforeMeeting: profilesBefore)
            lineupIsFromInvite = SpeakerNamingPolicy.lineupIsFromInvite(request)
        } else {
            invitedNameKeys = []
            lineupIsFromInvite = false
        }

        let result = try await transcription.transcribeMicrophoneOnly(
            micURL: micURL,
            splitLocalSpeakers: splitLocalSpeakers,
            languageSelection: languageSelection,
            onProgress: TranscribingProgressGate.onProgress { [weak self] progress in
                self?.displayStatus = .transcribing(progress: progress)
            }
        )
        if let observer = await MainActor.run(body: { self.pipelineResultObserver }) {
            observer(result)
        }

        // Classify local speakers when local-speaker split ran, mirroring
        // `transcribeMultichannelPipeline`'s Phase 1.6. When `splitLocalSpeakers` is false,
        // keep the legacy single-"You" save path with empty mappings and no naming request.
        var speakerMappings: [String: SpeakerMapping] = [:]
        var speakerSources: [String: String] = [:]
        var speakerDbIds: [String: UUID] = [:]
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

        let hasSplitMicSpeakers = splitLocalSpeakers && !result.micPersistentSpeakerIds.isEmpty
        var cleanupProtectedProfileIds: Set<UUID> = []
        if hasSplitMicSpeakers {
            let micSpeakerIds = Array(result.micSpeakerIds).sorted()
            let micDbKnowledge = Self.speakerClassificationKnowledge(
                speakerIds: micSpeakerIds,
                utterances: result.micUtterances,
                contexts: result.micSpeakerContexts,
                speakerDB: speakerDB
            )

            var micAutoAcceptedIds: Set<String> = []
            var micNeedsActionIds: Set<String> = []
            for sid in micSpeakerIds {
                if let entry = micDbKnowledge.first(where: { $0.speakerId == sid }) {
                    let canAutoAccept = SpeakerNamingPolicy.shouldAutoAccept(
                        profile: entry.profile,
                        similarity: entry.similarity,
                        secondBestSimilarity: entry.secondSimilarity,
                        recentOutcomes: cachedRecentOutcomes(entry.profile),
                        marginSimilarities: entry.marginSimilarities,
                        inviteeBars: SpeakerNamingPolicy.inviteeBars(
                            for: entry.profile,
                            invitedNameKeys: invitedNameKeys,
                            lineupIsFromInvite: lineupIsFromInvite,
                            thresholds: speakerThresholds
                        ),
                        thresholds: speakerThresholds
                    )
                    if canAutoAccept {
                        micAutoAcceptedIds.insert(sid)
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
                    marginSimilarities: entry.marginSimilarities,
                    inviteeBars: SpeakerNamingPolicy.inviteeBars(
                        for: entry.profile,
                        invitedNameKeys: invitedNameKeys,
                        lineupIsFromInvite: lineupIsFromInvite,
                        thresholds: speakerThresholds
                    ),
                    thresholds: speakerThresholds
                )
                speakerMappings[key] = mapping
                speakerSources[key] = micAutoAcceptedIds.contains(entry.speakerId) ? "db" : "db_pending"
            }

            for utterance in result.micUtterances {
                let key = "mic_\(utterance.speakerId)"
                if let pid = utterance.persistentSpeakerId, speakerDbIds[key] == nil {
                    speakerDbIds[key] = pid
                }
            }
            for key in speakerDbIds.keys where speakerMappings[key] == nil {
                let sid = key.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: true).last.map(String.init) ?? key
                speakerMappings[key] = SpeakerMapping(speakerId: sid)
                if speakerSources[key] == nil {
                    speakerSources[key] = "db_pending"
                }
            }

            let protectedReviewProfileIds = Self.pendingReviewProfileIds(
                systemUtterances: [],
                micUtterances: result.micUtterances,
                systemNeedsActionIds: [],
                micQueuedReviewIds: result.micSpeakerIds
            )
            cleanupProtectedProfileIds = protectedReviewProfileIds
                .union(speakerReviewProfileProtection.protectedProfileIds)

            AppLogger.speakers.info("Per-mic-speaker classification (mic-only)", [
                "autoAccepted": "\(micAutoAcceptedIds.count)",
                "needsAction": "\(micNeedsActionIds.count)",
                "total": "\(micSpeakerIds.count)"
            ])
        }

        let replacementTranscriptRollback = try ReplacementTranscriptRollback.capture(for: nil)
        let transcriptId = UUID()
        try Task.checkCancellation()

        if hasSplitMicSpeakers {
            speakerDB.mergeDuplicates(protecting: cleanupProtectedProfileIds)
            speakerDB.pruneWeakProfiles(protecting: cleanupProtectedProfileIds)
            try Task.checkCancellation()
        }

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
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            directory: outputFolder,
            meetingTitle: meetingTitle,
            healthInfo: micOnlyHealth,
            notifier: nil,
            speakerStore: splitLocalSpeakers ? speakerDB : nil,
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

        let shouldRemoveMicScratch = archiveOutcome.canRemoveMicScratch && removeSourceAudioAfterArchive

        if hasSplitMicSpeakers {
            var namingEntries: [SpeakerNamingEntry] = []
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
                AppLogger.pipeline.warning("Mic clip extraction failed in mic-only pipeline, skipping mic naming", [
                    "error": error.localizedDescription
                ])
            }
            try await rollback.checkCancellation()

            let reviewListsRecognizedVoices = await MainActor.run {
                self.reviewListsRecognizedVoicesProvider?() ?? false
            }
            if SpeakerNamingPolicy.shouldQueueSpeakerReview(
                askedVoices: namingEntries.count,
                recognizedVoices: 0,
                reviewListsRecognizedVoices: reviewListsRecognizedVoices
            ) {
                let allProfiles = speakerDB.allSpeakers()
                let confirmationIdentity = await MainActor.run { self.confirmationMeetingId(for: taskId) }
                let earnsConfirmationByProfile = try Self.confirmationEligibility(
                    profiles: allProfiles,
                    store: speakerDB,
                    transcriptId: transcriptId,
                    meetingId: confirmationIdentity
                )
                let knownPeople: [SpeakerIdentityOption] = allProfiles.compactMap { profile in
                    guard let name = profile.displayName, !name.isEmpty else { return nil }
                    return SpeakerIdentityOption(
                        id: profile.id,
                        displayName: name,
                        callCount: profile.callCount,
                        confirmedMeetings: profile.confirmedMeetingCount,
                        isTrusted: SpeakerNamingPolicy.isAutoRecognizable(
                            profile: profile,
                            recentOutcomes: cachedRecentOutcomes(profile),
                            requiredConfirmations: 0
                        ),
                        earnsConfirmation: earnsConfirmationByProfile[profile.id] ?? false,
                        requiredMeetings: SpeakerNamingPolicy.inviteeBars(
                            for: profile,
                            invitedNameKeys: invitedNameKeys,
                            lineupIsFromInvite: lineupIsFromInvite,
                            thresholds: speakerThresholds
                        )?.requiredConfirmedMeetings ?? SpeakerNamingPolicy.requiredConfirmedMeetings
                    )
                }

                let capturedEntries = Self.withConfirmationProgress(
                    namingEntries,
                    profile: { speakerDB.getSpeaker(id: $0) },
                    trusted: { SpeakerNamingPolicy.isAutoRecognizable(profile: $0, recentOutcomes: cachedRecentOutcomes($0), requiredConfirmations: 0) },
                    earnsConfirmation: { earnsConfirmationByProfile[$0] ?? false },
                    invited: invitedNameKeys,
                    fromInvite: lineupIsFromInvite,
                    thresholds: speakerThresholds
                )
                let speakerNamingRequestId = UUID()
                try await rollback.checkCancellation()
                await MainActor.run {
                    self.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
                        id: speakerNamingRequestId,
                        speakers: capturedEntries,
                        knownPeople: knownPeople,
                        recognizedSpeakerNames: [],
                        recognizedSpeakers: [],
                        transcriptURL: savedURL,
                        transcriptId: transcriptId,
                        systemAudioURL: nil,
                        micAudioURL: micURL,
                        shouldRemoveTemporaryAudioOnCleanup: shouldRemoveMicScratch && sourceFailedTranscriptionId == nil,
                        shouldRemoveMicAudioOnCleanup: shouldRemoveMicScratch && sourceFailedTranscriptionId == nil,
                        shouldRemoveSystemAudioOnCleanup: false,
                        sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                        importedRecoverySession: nil,
                        onComplete: { [weak self] updates in
                            self?.handleNamingComplete(
                                updates: updates,
                                transcriptURL: savedURL,
                                transcriptId: transcriptId,
                                transcriptionResult: result,
                                micURL: micURL,
                                systemURL: nil,
                                splitLocalSpeakers: splitLocalSpeakers,
                                shouldRemoveTemporaryAudio: shouldRemoveMicScratch,
                                shouldRemoveMicAudio: shouldRemoveMicScratch,
                                shouldRemoveSystemAudio: false,
                                sourceFailedTranscriptionId: sourceFailedTranscriptionId,
                                clips: capturedEntries,
                                importedRecoverySession: nil,
                                requestId: speakerNamingRequestId
                            )
                        }
                    ))
                }
                let manager = self
                rollback.register {
                    await manager.cancelSpeakerNamingRequest(
                        transcriptId: transcriptId,
                        requestId: speakerNamingRequestId
                    )
                    AppLogger.pipeline.info("Rollback: cancelled queued mic-only speaker naming request", [
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
                AppLogger.pipeline.info("Mic-only speaker naming requested", [
                    "mic": "\(capturedEntries.count)"
                ])
                return savedURL
            }
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

        if shouldRemoveMicScratch && sourceFailedTranscriptionId == nil {
            removeManagedCleanupFile(micURL, label: "completed mic-only scratch")
        }

        return savedURL
    }

    nonisolated static func existingImportedAt(of transcriptURL: URL?) -> Date? {
        guard let transcriptURL,
              let raw = try? String(contentsOf: transcriptURL, encoding: .utf8),
              let values = TranscriptFrontmatter.values(in: raw) else { return nil }
        return TranscriptFrontmatter.importedAt(values: values)
    }

    /// Transcribe an imported audio file through the system-audio speaker path.
    nonisolated func transcribeImportedAudio(
        audioURL: URL,
        outputFolder: URL,
        taskId: UUID,
        meetingTitle: String? = nil,
        recordingDate: Date? = nil,
        languageSelection: TranscriptionLanguageSelection = .automatic
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
            stableTranscriptId: taskId,
            languageSelection: languageSelection,
            importedAt: Date()
        )
    }

}
