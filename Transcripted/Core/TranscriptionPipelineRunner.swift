import Foundation
import AVFoundation
import UserNotifications

// MARK: - Pipeline Execution (Multichannel Transcription + Speaker Identification)

@available(macOS 26.0, *)
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

        // Phase 1.5: Identify speakers — DB knowledge first, then Qwen if needed
        var speakerMappings: [String: SpeakerMapping] = [:]
        var speakerSources: [String: String] = [:]  // "db" per speaker ID
        var speakerResult: SpeakerIdentificationResult? = nil

        // Build DB knowledge snapshot: what do we already know about these speakers?
        let speakerIds = Array(result.systemSpeakerIds).sorted()
        let speakerDB = await MainActor.run { self.transcription.speakerDB }
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

        // Auto-accept known speakers: populate mappings from DB without showing naming UI
        var identifiedSpeakers: [IdentifiedSpeaker] = []
        for entry in dbKnowledge {
            guard let name = entry.profile.displayName else { continue }
            let key = "system_\(entry.speakerId)"
            let confidence: SpeakerConfidence = entry.similarity > 0.85 && entry.profile.callCount > 3 ? .high : .medium
            speakerMappings[key] = SpeakerMapping(
                speakerId: entry.speakerId,
                identifiedName: name,
                confidence: confidence
            )
            speakerSources[entry.speakerId] = "db"

            if autoAcceptedIds.contains(entry.speakerId) {
                identifiedSpeakers.append(IdentifiedSpeaker(
                    name: name,
                    speakerId: entry.speakerId,
                    confidence: confidence,
                    evidence: "Voice fingerprint match (\(String(format: "%.0f", entry.similarity * 100))%, \(entry.profile.callCount) calls)"
                ))
            }
        }

        if !autoAcceptedIds.isEmpty {
            speakerResult = SpeakerIdentificationResult(speakers: identifiedSpeakers, userSpeakerId: nil)
        }

        AppLogger.speakers.info("Per-speaker classification", [
            "autoAccepted": "\(autoAcceptedIds.count)",
            "needsAction": "\(needsActionIds.count)",
            "total": "\(speakerIds.count)"
        ])

        // Clean up speaker profiles: first merge obvious duplicates, then prune orphans
        speakerDB.mergeDuplicates()
        speakerDB.pruneWeakProfiles()

        // Build diarizer speaker-ID → persistent DB UUID mapping for YAML
        var speakerDbIds: [String: UUID] = [:]
        for utterance in result.systemUtterances {
            let sid = String(utterance.speakerId)
            if let pid = utterance.persistentSpeakerId, speakerDbIds[sid] == nil {
                speakerDbIds[sid] = pid
            }
        }

        // Phase 2: Save transcript with speaker names
        await MainActor.run {
            self.displayStatus = .finishing
        }

        guard let savedURL = TranscriptSaver.saveTranscript(
            result,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            speakerDbIds: speakerDbIds,
            directory: outputFolder,
            healthInfo: healthInfo
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
                for clip in clips {
                    SpeakerClipExtractor.persistClip(from: clip.clipURL, speakerId: clip.persistentSpeakerId)
                }

                if !clips.isEmpty {
                    // Run Qwen inference for unidentified speakers (if enabled)
                    var qwenSuggestions: [String: String] = [:]
                    var qwenMeetingTitle: String? = nil
                    let unidentifiedClips = clips.filter { $0.currentName == nil }

                    if !unidentifiedClips.isEmpty && QwenService.isEnabled && QwenService.isModelCached {
                        let inferenceText = self.buildTranscriptTextForInference(
                            utterances: result.systemUtterances,
                            speakerMappings: speakerMappings
                        )

                        if !inferenceText.isEmpty {
                            // On machines with ≥12 GB RAM, Parakeet (CoreML/ANE ~600 MB) and
                            // diarization (~80 MB) coexist with Qwen (MLX/GPU ~2.5 GB) without
                            // memory pressure. Only unload on smaller machines.
                            let totalMemoryGB = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
                            let shouldUnloadForQwen = totalMemoryGB < 12

                            if shouldUnloadForQwen {
                                await MainActor.run {
                                    self.transcription.parakeet.cleanup()
                                    self.transcription.diarization.cleanup()
                                }
                                AppLogger.pipeline.info("Unloaded Parakeet + diarization models before Qwen inference (RAM: \(String(format: "%.0f", totalMemoryGB)) GB)")
                            } else {
                                AppLogger.pipeline.info("Keeping models resident during Qwen inference (RAM: \(String(format: "%.0f", totalMemoryGB)) GB)")
                            }

                            do {
                                // Wait for pre-loaded model (started when recording began)
                                if let preloadTask = await MainActor.run(body: { self.qwenPreloadTask }) {
                                    await preloadTask.value
                                }

                                // Atomically check pre-loaded instance (single MainActor hop prevents TOCTOU)
                                var qwen: QwenService? = await MainActor.run {
                                    if let svc = self.qwenService, case .ready = svc.modelState { return svc }
                                    return nil
                                }

                                // Fall back to fresh load (retry path)
                                if qwen == nil {
                                    if self.hasMemoryForQwen() {
                                        let fresh = await QwenService()
                                        await fresh.loadModel()
                                        qwen = fresh
                                    } else {
                                        AppLogger.pipeline.info("Skipping Qwen fresh load — low memory")
                                    }
                                }

                                if let qwen, case .ready = await qwen.modelState {
                                    let output = try await qwen.inferSpeakerNames(transcript: inferenceText)
                                    qwenSuggestions = output.speakers
                                    qwenMeetingTitle = output.meetingTitle
                                }
                                await MainActor.run { self.cleanupQwen() }

                                if shouldUnloadForQwen {
                                    await self.transcription.initializeModels()
                                    AppLogger.pipeline.info("Reloaded Parakeet + diarization after Qwen cleanup")
                                }

                                // Retroactively add meeting title to transcript YAML
                                if let title = qwenMeetingTitle {
                                    TranscriptSaver.retroactivelyUpdateTitle(transcriptURL: savedURL, title: title)
                                }

                                AppLogger.pipeline.info("Qwen speaker inference complete", [
                                    "suggestions": "\(qwenSuggestions.filter { $0.value != "Unknown" }.count)",
                                    "total": "\(qwenSuggestions.count)",
                                    "title": qwenMeetingTitle ?? "(none)"
                                ])
                            } catch {
                                await MainActor.run { self.cleanupQwen() }

                                if shouldUnloadForQwen {
                                    await self.transcription.initializeModels()
                                    AppLogger.pipeline.info("Reloaded Parakeet + diarization after Qwen cleanup")
                                }

                                AppLogger.pipeline.warning("Qwen inference failed, falling back to manual naming", [
                                    "error": error.localizedDescription
                                ])
                            }
                        }
                    }

                    // Determine whether Qwen ran at all (drives "No name detected" hint)
                    let qwenRan = QwenService.isEnabled && QwenService.isModelCached && !unidentifiedClips.isEmpty

                    let entries = clips.map { clip in
                        let qwenName = qwenSuggestions[clip.sortformerSpeakerId]
                        let hasQwenSuggestion = qwenName != nil && qwenName != "Unknown"

                        let qwenResult: QwenInferenceResult
                        if hasQwenSuggestion {
                            qwenResult = .suggested(name: qwenName!)
                        } else if qwenRan {
                            qwenResult = .noNameFound
                        } else {
                            qwenResult = .notAttempted
                        }

                        return SpeakerNamingEntry(
                            id: clip.persistentSpeakerId,
                            sortformerSpeakerId: clip.sortformerSpeakerId,
                            clipURL: clip.clipURL,
                            sampleText: clip.sampleText,
                            currentName: clip.currentName,
                            matchSimilarity: clip.matchSimilarity,
                            needsNaming: clip.currentName == nil && !hasQwenSuggestion,
                            needsConfirmation: clip.currentName != nil || hasQwenSuggestion,
                            qwenResult: qwenResult
                        )
                    }

                    // Publish naming request on main thread — UI will show naming tray
                    // Audio cleanup is deferred until naming completes
                    await MainActor.run {
                        self.speakerNamingRequest = SpeakerNamingRequest(
                            speakers: entries,
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

        // No naming needed (or clip extraction failed) — clean up Qwen and audio files
        await MainActor.run { self.cleanupQwen() }
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)

        return savedURL
    }

    /// Build a text representation of system audio transcript for Qwen speaker name inference.
    /// Samples strategically: first 5 min + last 5 min + evenly spaced middle samples,
    /// capped at 8000 characters to stay within Qwen's effective context window.
    nonisolated func buildTranscriptTextForInference(
        utterances: [TranscriptionUtterance],
        speakerMappings: [String: SpeakerMapping]
    ) -> String {
        let sorted = utterances.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return "" }

        let maxChars = 8000
        guard let lastUtterance = sorted.last else { return "" }
        let totalDuration = lastUtterance.start

        // Strategy: first 5 min + last 5 min + ~20 samples from middle
        let firstWindow = sorted.filter { $0.start < 300 }
        let lastWindow = sorted.filter { $0.start > totalDuration - 300 }
        let middleUtterances = sorted.filter { $0.start >= 300 && $0.start <= totalDuration - 300 }

        var selected = firstWindow
        if !middleUtterances.isEmpty {
            let step = max(1, middleUtterances.count / 20)
            for i in stride(from: 0, to: middleUtterances.count, by: step) {
                selected.append(middleUtterances[i])
            }
        }
        selected.append(contentsOf: lastWindow)

        // Deduplicate by start time and sort
        var seenStarts = Set<Double>()
        selected = selected.filter { seenStarts.insert($0.start).inserted }
        selected.sort { $0.start < $1.start }

        // Format and truncate to budget
        var result = ""
        for utterance in selected {
            let mins = Int(utterance.start) / 60
            let secs = Int(utterance.start) % 60
            let key = "system_\(utterance.speakerId)"
            let label = speakerMappings[key]?.displayName ?? "Speaker \(utterance.speakerId)"
            let line = "[\(String(format: "%02d:%02d", mins, secs))] [\(label)] \(utterance.transcript)\n"
            if result.count + line.count > maxChars { break }
            result += line
        }

        return result
    }
}
