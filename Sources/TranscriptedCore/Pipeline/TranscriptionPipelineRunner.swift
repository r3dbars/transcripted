import Foundation
import AVFoundation

// MARK: - Pipeline Execution (Multichannel Transcription + Speaker Identification)

extension TranscriptionTaskManager {

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
        meetingTitle: String? = nil
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
            meetingTitle: meetingTitle
        )
    }

    /// Transcribe an imported audio file through the system-audio speaker path.
    nonisolated func transcribeImportedAudio(
        audioURL: URL,
        outputFolder: URL,
        taskId: UUID,
        meetingTitle: String? = nil
    ) async throws -> URL {
        try await transcribeMultichannelPipeline(
            micURL: nil,
            systemURL: audioURL,
            outputFolder: outputFolder,
            taskId: taskId,
            healthInfo: nil,
            splitLocalSpeakers: false,
            meetingTitle: meetingTitle
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
        meetingTitle: String? = nil
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
        let statsStore = await MainActor.run { self.statsStore }
        var dbKnowledge: [(speakerId: String, profile: SpeakerProfile, similarity: Double)] = []

        for utterance in result.systemUtterances {
            let sid = String(utterance.speakerId)
            // Only process each speaker ID once
            guard !dbKnowledge.contains(where: { $0.speakerId == sid }) else { continue }
            if let persistentId = utterance.persistentSpeakerId,
               let similarity = utterance.matchSimilarity,
               let profile = speakerDB.getSpeaker(id: persistentId) {
                dbKnowledge.append((speakerId: sid, profile: profile, similarity: similarity))
            }
        }

        // Per-speaker classification: auto-accept high-confidence known speakers,
        // track which ones need naming or confirmation
        var autoAcceptedIds: Set<String> = []
        var needsActionIds: Set<String> = []

        for sid in speakerIds {
            if let entry = dbKnowledge.first(where: { $0.speakerId == sid }) {
                let canAutoAccept = SpeakerNamingPolicy.shouldAutoAccept(
                    profile: entry.profile,
                    similarity: entry.similarity
                )
                if canAutoAccept {
                    autoAcceptedIds.insert(sid)
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
                similarity: entry.similarity
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
            var micDbKnowledge: [(speakerId: String, profile: SpeakerProfile, similarity: Double)] = []
            for utterance in result.micUtterances {
                let sid = String(utterance.speakerId)
                guard !micDbKnowledge.contains(where: { $0.speakerId == sid }) else { continue }
                if let persistentId = utterance.persistentSpeakerId,
                   let similarity = utterance.matchSimilarity,
                   let profile = speakerDB.getSpeaker(id: persistentId) {
                    micDbKnowledge.append((speakerId: sid, profile: profile, similarity: similarity))
                }
            }

            for sid in micSpeakerIds {
                if let entry = micDbKnowledge.first(where: { $0.speakerId == sid }) {
                    let canAutoAccept = SpeakerNamingPolicy.shouldAutoAccept(
                        profile: entry.profile,
                        similarity: entry.similarity
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
                    similarity: entry.similarity
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

        // Clean up speaker profiles: first merge obvious duplicates, then prune orphans
        speakerDB.mergeDuplicates()
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

        // Phase 2: Save transcript with speaker names
        let notifier: TranscriptNotifier? = await MainActor.run {
            self.displayStatus = .finishing
            return self.notifier
        }

        let transcriptId = UUID()

        guard let savedURL = TranscriptSaver.saveTranscript(
            result,
            transcriptId: transcriptId,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            directory: outputFolder,
            meetingTitle: meetingTitle,
            healthInfo: healthInfo,
            notifier: notifier,
            speakerStore: speakerDB,
            statsStore: statsStore,
            transcriptionEngine: speechEngine
        ) else {
            throw PipelineError.saveFailed(detail: "Could not write transcript to \(outputFolder.lastPathComponent)")
        }

        AppLogger.pipeline.info("Phase 2 complete: Transcript saved", ["file": savedURL.lastPathComponent])

        let shouldRemoveScratchAudio = await archiveRecordingAudioIfConfigured(
            micURL: micURL,
            systemURL: systemURL,
            savedURL: savedURL
        )

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
                    namingEntries.append(SpeakerNamingEntry(
                        id: clip.persistentSpeakerId,
                        diarizerSpeakerId: clip.diarizerSpeakerId,
                        channel: .system,
                        clipURL: clip.clipURL,
                        sampleText: clip.sampleText,
                        currentName: clip.currentName,
                        matchSimilarity: clip.matchSimilarity,
                        needsNaming: clip.currentName == nil,
                        needsConfirmation: clip.currentName != nil,
                        sessionEmbedding: result.systemSpeakerContexts[clip.diarizerSpeakerId]?.sessionEmbedding,
                        matchedProfileSnapshot: result.systemSpeakerContexts[clip.diarizerSpeakerId]?.matchedProfileSnapshot
                    ))
                }
            } catch {
                AppLogger.pipeline.warning("System clip extraction failed, skipping system naming", ["error": error.localizedDescription])
            }
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
                    namingEntries.append(SpeakerNamingEntry(
                        id: clip.persistentSpeakerId,
                        diarizerSpeakerId: clip.diarizerSpeakerId,
                        channel: .mic,
                        clipURL: clip.clipURL,
                        sampleText: clip.sampleText,
                        currentName: clip.currentName,
                        matchSimilarity: clip.matchSimilarity,
                        needsNaming: clip.currentName == nil,
                        needsConfirmation: clip.currentName != nil,
                        sessionEmbedding: result.micSpeakerContexts[clip.diarizerSpeakerId]?.sessionEmbedding,
                        matchedProfileSnapshot: result.micSpeakerContexts[clip.diarizerSpeakerId]?.matchedProfileSnapshot
                    ))
                }
            } catch {
                AppLogger.pipeline.warning("Mic clip extraction failed, skipping mic naming", ["error": error.localizedDescription])
            }
        }

        if !namingEntries.isEmpty {
            // Seed knownPeople with existing named DB profiles so the sheet's combobox has
            // suggestions. Previously this was always empty — users typed blind.
            let knownPeople: [SpeakerIdentityOption] = speakerDB.allSpeakers()
                .compactMap { profile in
                    guard let name = profile.displayName, !name.isEmpty else { return nil }
                    return SpeakerIdentityOption(
                        id: profile.id,
                        displayName: name,
                        callCount: profile.callCount
                    )
                }

            let capturedEntries = namingEntries
            await MainActor.run {
                self.enqueueSpeakerNamingRequest(SpeakerNamingRequest(
                    speakers: capturedEntries,
                    knownPeople: knownPeople,
                    transcriptURL: savedURL,
                    transcriptId: transcriptId,
                    systemAudioURL: systemURL,
                    micAudioURL: micURL,
                    shouldRemoveTemporaryAudioOnCleanup: shouldRemoveScratchAudio,
                    onComplete: { [weak self] updates in
                        self?.handleNamingComplete(
                            updates: updates,
                            transcriptURL: savedURL,
                            transcriptId: transcriptId,
                            transcriptionResult: result,
                            micURL: micURL,
                            systemURL: systemURL,
                            shouldRemoveTemporaryAudio: shouldRemoveScratchAudio,
                            clips: capturedEntries
                        )
                    }
                ))
            }

            AppLogger.pipeline.info("Speaker naming requested", [
                "total": "\(namingEntries.count)",
                "mic": "\(namingEntries.filter { $0.channel == .mic }.count)",
                "system": "\(namingEntries.filter { $0.channel == .system }.count)"
            ])
            return savedURL
        }

        // No naming needed — clean up scratch audio once retained copies exist.
        if shouldRemoveScratchAudio, let micURL {
            try? FileManager.default.removeItem(at: micURL)
        }
        if shouldRemoveScratchAudio {
            try? FileManager.default.removeItem(at: systemURL)
        }

        return savedURL
    }

    nonisolated private func archiveRecordingAudioIfConfigured(
        micURL: URL?,
        systemURL: URL,
        savedURL: URL
    ) async -> Bool {
        let retainedAudioDirectory = await MainActor.run { self.resolvedRetainedAudioDirectory() }
        guard let retainedAudioDirectory else { return true }

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
            return true
        } catch {
            AppLogger.pipeline.warning("Failed to retain meeting audio; leaving scratch files in place", [
                "hasMic": "\(micURL != nil)",
                "hasSystem": "true",
                "errorType": "\(type(of: error))"
            ])
            return false
        }
    }

}
