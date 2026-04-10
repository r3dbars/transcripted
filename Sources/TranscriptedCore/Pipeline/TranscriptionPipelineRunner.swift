import Foundation
import AVFoundation

// MARK: - Pipeline Execution (Multichannel Transcription + Speaker Identification)

extension TranscriptionTaskManager {

    /// Transcribe with multichannel mode (requires both mic and system audio)
    /// - Returns: URL of saved transcript with speaker attribution
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated func transcribeWithSpeakerIdentification(
        micURL: URL,
        systemURL: URL?,
        outputFolder: URL,
        taskId: UUID,
        healthInfo: RecordingHealthInfo?
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
            healthInfo: healthInfo
        )
    }

    /// Local pipeline: Parakeet STT + Sortformer diarization → Speaker identification → Save
    /// Benefits: 100% local, no cloud API, no cost, speaker voice fingerprints
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated func transcribeMultichannelPipeline(
        micURL: URL,
        systemURL: URL,
        outputFolder: URL,
        taskId: UUID,
        healthInfo: RecordingHealthInfo?
    ) async throws -> URL {

        let transcription = await MainActor.run { self.transcription }

        AppLogger.pipeline.info("Using local Parakeet + PyAnnote pipeline")

        // Phase 1: Transcribe with local models
        let result = try await transcription.transcribeMultichannel(
            micURL: micURL,
            systemURL: systemURL,
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
        let speakerClipsDirectory = await MainActor.run { transcription.speakerClipsDirectory }
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
                let canAutoAccept = entry.profile.displayName != nil
                    && entry.similarity > 0.88
                    && entry.profile.callCount > 4
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

        // Keep identity metadata for every speaker, but only persist a visible person name
        // once the match is strong enough to auto-accept.
        for sid in speakerIds {
            let key = "system_\(sid)"
            if let entry = dbKnowledge.first(where: { $0.speakerId == sid }) {
                let confidence: SpeakerConfidence = entry.similarity > 0.85 && entry.profile.callCount > 3 ? .high : .medium
                speakerMappings[key] = SpeakerMapping(
                    speakerId: sid,
                    identifiedName: entry.profile.displayName,
                    confidence: confidence,
                    isConfirmedIdentity: autoAcceptedIds.contains(sid)
                )
                speakerSources[sid] = "db"
            } else {
                speakerMappings[key] = SpeakerMapping(
                    speakerId: sid,
                    identifiedName: nil,
                    confidence: nil,
                    isConfirmedIdentity: false
                )
            }
        }

        AppLogger.speakers.info("Per-speaker classification", [
            "autoAccepted": "\(autoAcceptedIds.count)",
            "needsAction": "\(needsActionIds.count)",
            "total": "\(speakerIds.count)"
        ])

        // Clean up speaker profiles: first merge obvious duplicates, then prune orphans
        speakerDB.mergeDuplicates()
        speakerDB.pruneWeakProfiles()

        // Tentative suggestions stay generic in saved artifacts until the user confirms them.
        let tentativeSuggestedSpeakerIds = Set(
            dbKnowledge.compactMap { entry -> String? in
                guard !autoAcceptedIds.contains(entry.speakerId),
                      let suggestedName = entry.profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !suggestedName.isEmpty else {
                    return nil
                }
                return entry.speakerId
            }
        )

        // Build diarizer speaker-ID → persistent DB UUID mapping for YAML
        var speakerDbIds: [String: UUID] = [:]
        for utterance in result.systemUtterances {
            let sid = String(utterance.speakerId)
            if let pid = utterance.persistentSpeakerId, speakerDbIds[sid] == nil {
                speakerDbIds[sid] = pid
            }
        }
        for sid in tentativeSuggestedSpeakerIds {
            speakerDbIds.removeValue(forKey: sid)
        }

        // Phase 2: Save transcript with speaker names
        let (notifier, statsStore): (TranscriptNotifier?, (any StatsStore)?) = await MainActor.run {
            self.displayStatus = .finishing
            return (self.notifier, self.statsStore)
        }

        guard let savedURL = TranscriptSaver.saveTranscript(
            result,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            directory: outputFolder,
            healthInfo: healthInfo,
            notifier: notifier,
            speakerStoreForIndex: speakerDB,
            statsStore: statsStore
        ) else {
            throw PipelineError.saveFailed(detail: "Could not write transcript to \(outputFolder.lastPathComponent)")
        }

        AppLogger.pipeline.info("Phase 2 complete: Transcript saved", ["file": savedURL.lastPathComponent])

        // Phase 3: Speaker naming — only for speakers that need action
        if !needsActionIds.isEmpty {
            // Extract clips only for speakers that need naming/confirmation
            do {
                let actionUtterances = result.systemUtterances.filter {
                    needsActionIds.contains(String($0.speakerId))
                }
                let clips = try SpeakerClipExtractor.extractClips(
                    systemAudioURL: systemURL,
                    utterances: actionUtterances,
                    speakerDB: speakerDB
                )

                // Persist clips so they survive naming tray dismissal
                var provisionalSuggestions: [String: (provisionalId: UUID, suggested: SpeakerIdentityOption)] = [:]
                for sid in needsActionIds.sorted() {
                    guard let entry = dbKnowledge.first(where: { $0.speakerId == sid }),
                          let suggestedName = entry.profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !suggestedName.isEmpty else {
                        continue
                    }

                    let provisionalProfile = speakerDB.addOrUpdateSpeaker(
                        embedding: entry.profile.embedding,
                        existingId: nil
                    )
                    provisionalSuggestions[sid] = (
                        provisionalProfile.id,
                        SpeakerIdentityOption(
                            id: entry.profile.id,
                            displayName: suggestedName,
                            callCount: entry.profile.callCount
                        )
                    )
                }

                for clip in clips {
                    let clipSpeakerId = provisionalSuggestions[clip.sortformerSpeakerId]?.provisionalId
                        ?? clip.persistentSpeakerId
                    SpeakerClipExtractor.persistClip(
                        from: clip.clipURL,
                        speakerId: clipSpeakerId,
                        clipsDirectory: speakerClipsDirectory
                    )
                }

                if !clips.isEmpty {
                    let knownPeople = speakerDB.allSpeakers().compactMap { profile -> SpeakerIdentityOption? in
                        guard let name = profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !name.isEmpty else { return nil }
                        return SpeakerIdentityOption(id: profile.id, displayName: name, callCount: profile.callCount)
                    }.sorted { lhs, rhs in
                        if lhs.displayName.caseInsensitiveCompare(rhs.displayName) == .orderedSame {
                            if lhs.callCount == rhs.callCount {
                                return lhs.id.uuidString < rhs.id.uuidString
                            }
                            return lhs.callCount > rhs.callCount
                        }
                        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
                    }

                    let entries = clips.map { clip in
                        let suggestedIdentity = provisionalSuggestions[clip.sortformerSpeakerId]?.suggested
                        let currentName = suggestedIdentity?.displayName ?? clip.currentName
                        return SpeakerNamingEntry(
                            id: provisionalSuggestions[clip.sortformerSpeakerId]?.provisionalId ?? clip.persistentSpeakerId,
                            suggestedProfileId: suggestedIdentity?.id,
                            sortformerSpeakerId: clip.sortformerSpeakerId,
                            clipURL: clip.clipURL,
                            sampleText: clip.sampleText,
                            currentName: currentName,
                            matchSimilarity: clip.matchSimilarity,
                            callCount: suggestedIdentity?.callCount ?? clip.callCount,
                            needsNaming: currentName == nil,
                            needsConfirmation: currentName != nil
                        )
                    }

                    // Publish naming request on main thread — UI will show naming tray
                    // Audio cleanup is deferred until naming completes
                    await MainActor.run {
                        self.speakerNamingRequest = SpeakerNamingRequest(
                            speakers: entries,
                            knownPeople: knownPeople,
                            transcriptURL: savedURL,
                            systemAudioURL: systemURL,
                            micAudioURL: micURL,
                            onComplete: { [weak self] updates in
                                self?.handleNamingComplete(
                                    updates: updates,
                                    transcriptURL: savedURL,
                                    micURL: micURL,
                                    systemURL: systemURL,
                                    clips: entries
                                )
                            }
                        )
                    }

                    AppLogger.pipeline.info("Speaker naming requested", ["speakers": "\(entries.count)"])
                    return savedURL
                }
            } catch {
                AppLogger.pipeline.warning("Clip extraction failed, skipping naming", ["error": error.localizedDescription])
            }
        }

        // No naming needed (or clip extraction failed) — clean up audio files
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)

        return savedURL
    }

}
