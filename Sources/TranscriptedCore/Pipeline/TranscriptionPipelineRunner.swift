import Foundation
import AVFoundation

// MARK: - Pipeline Execution (Multichannel Transcription + Speaker Identification)

extension TranscriptionTaskManager {

    /// Local pipeline: selected STT + diarization (Nemotron or pyannote) → Speaker identification → Save.
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
        stableTranscriptId: UUID? = nil,
        languageSelection: TranscriptionLanguageSelection = .automatic,
        importedAt: Date? = nil
    ) async throws -> URL {

        let transcription = await MainActor.run { self.transcription }
        try await transcription.ensureModelsReadyForPipeline()

        let speechEngine = await MainActor.run {
            transcription.parakeet.transcriptionEngineDescriptor
        }

        // Read after the models load, so a Nemotron load failure logs pyannote.
        let diarizationRun = await MainActor.run { transcription.diarization.activeRunDescriptor }
        AppLogger.pipeline.info("Using local \(speechEngine.displayName) + \(diarizationRun.backend.transcriptEngineIdentifier) pipeline", [
            "splitLocalSpeakers": "\(splitLocalSpeakers)",
            "transcription_engine": speechEngine.identifier,
            "diarization_engine": diarizationRun.backend.transcriptEngineIdentifier,
            "voiceprint_model": diarizationRun.voiceprintModel ?? "none"
        ])

        // An imported file's date says when the file was made or copied, not
        // which meeting it was, so imports never pick up a calendar invite:
        // no invite cap on its speakers and no lowered lineup bars.
        let isImport = importedAt != nil
        let separationProvider = await MainActor.run { self.speakerSeparationProvider }
        let speakerSeparation = await separationProvider?(isImport ? nil : recordingDate)
        // Lineup naming: people on the lineup get lower silent-naming bars
        // (SpeakerNamingPolicy.InviteeBars). Resolved before Phase 1 matches voices,
        // so a voice heard in this meeting can't put itself on its own lineup.
        let lineupProvider = await MainActor.run { self.lineupNamingProvider }
        let invitedNameKeys: Set<String>
        let lineupIsFromInvite: Bool
        if !isImport, let request = await lineupProvider?(recordingDate) {
            let profilesBefore = await MainActor.run { transcription.speakerDB.allSpeakers() }
            invitedNameKeys = SpeakerNamingPolicy.lineupNameKeys(request, profilesBeforeMeeting: profilesBefore)
            lineupIsFromInvite = SpeakerNamingPolicy.lineupIsFromInvite(request)
        } else {
            invitedNameKeys = []
            lineupIsFromInvite = false
        }

        // Phase 1: Transcribe with local models
        let result = try await transcription.transcribeMultichannel(
            micURL: micURL,
            systemURL: systemURL,
            splitLocalSpeakers: splitLocalSpeakers,
            languageSelection: languageSelection,
            speakerSeparation: speakerSeparation,
            onProgress: TranscribingProgressGate.onProgress { [weak self] progress in
                self?.displayStatus = .transcribing(progress: progress)
            }
        )

        AppLogger.pipeline.info("Phase 1 complete: Local transcription done", ["micUtterances": "\(result.micUtteranceCount)", "systemUtterances": "\(result.systemUtteranceCount)"])
        if let observer = await MainActor.run(body: { self.pipelineResultObserver }) {
            observer(result)
        }

        // Phase 1.5: Identify speakers from DB knowledge
        var speakerMappings: [String: SpeakerMapping] = [:]
        var speakerSources: [String: String] = [:]  // "db" per speaker ID
        // Build DB knowledge snapshot: what do we already know about these speakers?
        let speakerIds = Array(result.systemSpeakerIds).sorted()
        let speakerDB = await MainActor.run { transcription.speakerDB }
        // The active voiceprint model's cosine bars: the naming ladder and lineup bars below.
        let speakerThresholds = await MainActor.run { transcription.diarization.activeSpeakerThresholds }
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
                    marginSimilarities: entry.marginSimilarities,
                    inviteeBars: SpeakerNamingPolicy.inviteeBars(
                        for: entry.profile, invitedNameKeys: invitedNameKeys, lineupIsFromInvite: lineupIsFromInvite,
                        thresholds: speakerThresholds),
                    thresholds: speakerThresholds
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
                marginSimilarities: entry.marginSimilarities,
                inviteeBars: SpeakerNamingPolicy.inviteeBars(
                        for: entry.profile, invitedNameKeys: invitedNameKeys, lineupIsFromInvite: lineupIsFromInvite,
                        thresholds: speakerThresholds),
                thresholds: speakerThresholds
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
                        marginSimilarities: entry.marginSimilarities,
                        inviteeBars: SpeakerNamingPolicy.inviteeBars(
                        for: entry.profile, invitedNameKeys: invitedNameKeys, lineupIsFromInvite: lineupIsFromInvite,
                        thresholds: speakerThresholds),
                        thresholds: speakerThresholds
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
                    marginSimilarities: entry.marginSimilarities,
                    inviteeBars: SpeakerNamingPolicy.inviteeBars(
                        for: entry.profile, invitedNameKeys: invitedNameKeys, lineupIsFromInvite: lineupIsFromInvite,
                        thresholds: speakerThresholds),
                    thresholds: speakerThresholds
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

        // Clean up speaker profiles without deleting IDs still referenced by pending review rows,
        // this meeting's and any other review that is still open or queued. Merging or pruning a
        // profile an open review points at made that review's Save fail later.
        let cleanupProtectedProfileIds = protectedReviewProfileIds
            .union(speakerReviewProfileProtection.protectedProfileIds)
        speakerDB.mergeDuplicates(protecting: cleanupProtectedProfileIds)
        speakerDB.pruneWeakProfiles(protecting: cleanupProtectedProfileIds)

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
        var formatOptions = await MainActor.run {
            self.resolvedTranscriptFormatOptions(
                hasMicAudio: savedAudio.includesMicrophone,
                // A mic-only meeting's silent stand-in track is kept for
                // playback and re-transcribe, but it isn't a source.
                hasSystemAudio: savedAudio.includesSystemAudio
                    && savedAudio.healthInfo?.systemAudioSkippedByChoice != true
            )
        }
        // An import is listed by when it was imported. Re-transcribing that
        // file later keeps its original import time instead of dropping it.
        formatOptions.importedAt = importedAt
            ?? Self.existingImportedAt(of: targetTranscriptURL)

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

        // Remote voices named silently in this meeting. They aren't asked
        // about, but the review lists them with a clip each so a wrong
        // auto-name can be corrected ("Not Taylor?") and land as a correction
        // on the lifeline. A meeting where everyone was recognized still gets
        // this list. Only the Notch island shows it; the review window never
        // does, so without the island no clips are cut and a meeting with
        // nobody to ask finishes saving at once.
        let reviewListsRecognizedVoices = await MainActor.run {
            self.reviewListsRecognizedVoicesProvider?() ?? false
        }
        var recognizedEntries: [SpeakerNamingEntry] = []
        if reviewListsRecognizedVoices && !autoAcceptedIds.isEmpty {
            do {
                let recognizedUtterances = result.systemUtterances.filter {
                    autoAcceptedIds.contains(String($0.speakerId))
                }
                let clips = try SpeakerClipExtractor.extractClips(
                    sourceAudioURL: systemURL,
                    utterances: recognizedUtterances,
                    channel: .system,
                    speakerDB: speakerDB,
                    clipsDirectory: transcription.speakerClipsDirectory
                )
                for clip in clips {
                    guard let name = clip.currentName?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !name.isEmpty else {
                        _ = removeManagedCleanupFile(clip.clipURL, label: "unnamed recognized speaker clip")
                        _ = removeManagedCleanupFile(
                            SpeakerClipSidecar.url(nextTo: clip.clipURL),
                            label: "unnamed recognized speaker clip sidecar"
                        )
                        continue
                    }
                    let context = result.systemSpeakerContexts[clip.diarizerSpeakerId]
                    recognizedEntries.append(SpeakerNamingEntry(
                        id: clip.persistentSpeakerId,
                        diarizerSpeakerId: clip.diarizerSpeakerId,
                        channel: .system,
                        clipURL: clip.clipURL,
                        sampleText: clip.sampleText,
                        currentName: name,
                        matchSimilarity: clip.matchSimilarity,
                        matchSecondSimilarity: context?.matchSecondSimilarity,
                        callCount: context?.matchedProfileSnapshot?.callCount ?? 0,
                        needsNaming: false,
                        needsConfirmation: false,
                        sessionEmbedding: context?.sessionEmbedding,
                        matchedProfileSnapshot: context?.matchedProfileSnapshot
                    ))
                }
                Self.registerSpeakerClipsRollback(clips.map(\.clipURL), channel: "recognized", into: rollback)
            } catch {
                AppLogger.pipeline.warning("Recognized clip extraction failed, recognized voices can't be corrected from the review", ["error": error.localizedDescription])
            }
            try await rollback.checkCancellation()
        }

        if SpeakerNamingPolicy.shouldQueueSpeakerReview(
            askedVoices: namingEntries.count,
            recognizedVoices: recognizedEntries.count,
            reviewListsRecognizedVoices: reviewListsRecognizedVoices
        ) {
            let allProfiles = speakerDB.allSpeakers()
            let confirmationIdentity = await MainActor.run { self.confirmationMeetingId(for: taskId) }
            let earnsConfirmationByProfile = try Self.confirmationEligibility(profiles: allProfiles, store: speakerDB, transcriptId: transcriptId, meetingId: confirmationIdentity)
            let knownPeople: [SpeakerIdentityOption] = allProfiles
                .compactMap { profile in
                    guard let name = profile.displayName, !name.isEmpty else { return nil }
                    return SpeakerIdentityOption(
                        id: profile.id,
                        displayName: name,
                        callCount: profile.callCount, confirmedMeetings: profile.confirmedMeetingCount, isTrusted: SpeakerNamingPolicy.isAutoRecognizable(profile: profile, recentOutcomes: cachedRecentOutcomes(profile), requiredConfirmations: 0), earnsConfirmation: earnsConfirmationByProfile[profile.id] ?? false
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

            let capturedEntries = Self.withConfirmationProgress(namingEntries, profile: { speakerDB.getSpeaker(id: $0) }, trusted: { SpeakerNamingPolicy.isAutoRecognizable(profile: $0, recentOutcomes: cachedRecentOutcomes($0), requiredConfirmations: 0) }, earnsConfirmation: { earnsConfirmationByProfile[$0] ?? false }, invited: invitedNameKeys, fromInvite: lineupIsFromInvite, thresholds: speakerThresholds)
            let capturedRecognizedEntries = Self.withConfirmationProgress(recognizedEntries, recognized: true, profile: { speakerDB.getSpeaker(id: $0) }, trusted: { SpeakerNamingPolicy.isAutoRecognizable(profile: $0, recentOutcomes: cachedRecentOutcomes($0), requiredConfirmations: 0) }, earnsConfirmation: { earnsConfirmationByProfile[$0] ?? false }, invited: invitedNameKeys, fromInvite: lineupIsFromInvite, thresholds: speakerThresholds)
            // Voices auto-named in this meeting, once each, in the order heard.
            var seenRecognizedNames: Set<String> = []
            let recognizedSpeakerNames = pendingAutoAccepts.compactMap { pending -> String? in
                guard let name = pending.knowledge.profile.displayName?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                    !name.isEmpty,
                    seenRecognizedNames.insert(name).inserted else { return nil }
                return name
            }
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
                    recognizedSpeakerNames: recognizedSpeakerNames,
                    recognizedSpeakers: capturedRecognizedEntries,
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
                        // A recognized voice joins the save only when it was
                        // corrected; otherwise its auto-name stands.
                        let reviewed = SpeakerNamingPolicy.reviewEntriesToFinalize(
                            asked: capturedEntries,
                            recognized: capturedRecognizedEntries,
                            updates: updates
                        )
                        for entry in reviewed.discardClips {
                            _ = self?.removeManagedCleanupFile(entry.clipURL, label: "recognized speaker clip")
                            _ = self?.removeManagedCleanupFile(
                                SpeakerClipSidecar.url(nextTo: entry.clipURL),
                                label: "recognized speaker clip sidecar"
                            )
                        }
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
                            clips: reviewed.finalize,
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
                "recognized": "\(recognizedEntries.count)",
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

}
