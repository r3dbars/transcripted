import Foundation
import AVFoundation
import UserNotifications

// MARK: - Display Status for UI (Goal-Gradient Effect)
// Users are more motivated when they can see visible progress
// Simplified to 4 user-focused phases for cognitive clarity

enum DisplayStatus: Equatable {
    case idle

    // Processing phases
    case gettingReady                    // 0-15%: Loading audio, initial setup
    case transcribing(progress: Double)  // 15-75%: Active transcription
    case finishing                       // 95-100%: Saving, final steps

    // Completion states
    case transcriptSaved                 // Complete — transcript saved
    case failed(message: String)         // Error state

    /// Computed progress value (0.0 to 1.0) for UI progress bar
    var progress: Double {
        switch self {
        case .idle:
            return 0.0
        case .gettingReady:
            return 0.10
        case .transcribing(let p):
            // Map transcription progress (0-1) to (0.15-0.75)
            return 0.15 + (p * 0.60)
        case .finishing:
            return 0.97
        case .transcriptSaved:
            return 1.0
        case .failed:
            return 0.0
        }
    }

    /// User-friendly status text (outcome-oriented, not technical)
    var statusText: String {
        switch self {
        case .idle:
            return "Ready"
        case .gettingReady:
            return "Preparing..."
        case .transcribing:
            return "Transcribing..."
        case .finishing:
            return "Almost done..."
        case .transcriptSaved:
            return "Saved"
        case .failed(let message):
            return message
        }
    }

    /// Icon for the status (SF Symbol name)
    var icon: String {
        switch self {
        case .idle:
            return "circle"
        case .gettingReady, .transcribing, .finishing:
            return "arrow.triangle.2.circlepath"
        case .transcriptSaved:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Whether this is a "processing" state (show progress indicator)
    var isProcessing: Bool {
        switch self {
        case .gettingReady, .transcribing, .finishing:
            return true
        default:
            return false
        }
    }
}

struct TranscriptionTask: Identifiable {
    let id: UUID
    let micURL: URL
    let systemURL: URL?
    let outputFolder: URL
    let startTime: Date
    let healthInfo: RecordingHealthInfo?

    init(micURL: URL, systemURL: URL?, outputFolder: URL, healthInfo: RecordingHealthInfo? = nil) {
        self.id = UUID()
        self.micURL = micURL
        self.systemURL = systemURL
        self.outputFolder = outputFolder
        self.startTime = Date()
        self.healthInfo = healthInfo
    }
}

@available(macOS 26.0, *)
@MainActor
class TranscriptionTaskManager: ObservableObject {
    @Published var activeCount: Int = 0
    @Published var justCompleted: Bool = false

    // Display status for the status bar
    @Published var displayStatus: DisplayStatus = .idle

    // Background processing count — tracks transcriptions running while pill is idle
    // UI uses this to show a subtle indicator on the idle pill
    @Published var backgroundTaskCount: Int = 0

    // Speaker naming flow — published when post-meeting naming is needed
    @Published var speakerNamingRequest: SpeakerNamingRequest? = nil

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    let transcription = Transcription()

    /// Pre-loaded Qwen service — loaded when recording starts, consumed by pipeline
    private var qwenService: QwenService?
    private var qwenPreloadTask: Task<Void, Never>?
    private var qwenTimeoutTask: Task<Void, Never>?

    // Reference to failed transcription manager
    private let failedTranscriptionManager: FailedTranscriptionManager

    init(failedTranscriptionManager: FailedTranscriptionManager) {
        self.failedTranscriptionManager = failedTranscriptionManager
    }

    // MARK: - Qwen Pre-loading

    /// Pre-load Qwen model when recording starts so it's ready by the time the pipeline needs it.
    /// Only pre-loads if enabled AND model already cached (don't trigger a download during recording).
    func prepareForRecording() {
        guard QwenService.isEnabled, QwenService.isModelCached else { return }

        // Check available memory — Qwen needs ~2.5GB, require 4GB headroom
        guard hasMemoryForQwen() else {
            AppLogger.pipeline.info("Skipping Qwen pre-load — low memory")
            return
        }

        // Don't create a second instance if already loading/ready
        if let existing = qwenService {
            if case .ready = existing.modelState { return }
            if case .loading = existing.modelState { return }
        }

        AppLogger.pipeline.info("Pre-loading Qwen model for recording")

        qwenTimeoutTask?.cancel()
        let qwen = QwenService()
        self.qwenService = qwen

        qwenPreloadTask = Task { @MainActor [weak self] in
            await qwen.loadModel()
            if case .ready = qwen.modelState {
                AppLogger.pipeline.info("Qwen model pre-loaded and ready")
            } else {
                self?.qwenService = nil
            }
        }

        // Don't start the timeout yet — it will be started after the pipeline finishes
        // or if the recording is cancelled. This prevents Qwen from unloading during
        // long recordings (the old 5-minute timeout would fire mid-recording).
    }

    /// Start the Qwen safety timeout. Call this after the transcription pipeline finishes
    /// (or if the recording is cancelled) to free memory if Qwen wasn't consumed.
    private func startQwenTimeout() {
        qwenTimeoutTask?.cancel()
        qwenTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            if let self, self.qwenService != nil {
                AppLogger.pipeline.info("Qwen timeout — unloading unused model")
                self.cleanupQwen()
            }
        }
    }

    /// Check if enough memory is available for Qwen (~2.5GB model, require 2GB headroom).
    /// Returns true if memory is sufficient or the check is unavailable.
    nonisolated private func hasMemoryForQwen() -> Bool {
        let hostPort = mach_host_self()
        defer { mach_port_deallocate(mach_task_self_, hostPort) }
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(hostPort, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return true }  // if check fails, allow the attempt
        let pageSize = UInt64(vm_kernel_page_size)
        let freeBytes = (UInt64(stats.free_count) + UInt64(stats.inactive_count)) * pageSize
        let requiredBytes: UInt64 = 2 * 1024 * 1024 * 1024
        AppLogger.pipeline.debug("Qwen memory check", [
            "freeGB": String(format: "%.1f", Double(freeBytes) / 1_073_741_824),
            "requiredGB": "2.0",
            "sufficient": freeBytes >= requiredBytes ? "yes" : "no"
        ])
        return freeBytes >= requiredBytes
    }

    private func cleanupQwen() {
        qwenTimeoutTask?.cancel()
        qwenTimeoutTask = nil
        qwenPreloadTask = nil
        qwenService?.unload()
        qwenService = nil
    }

    /// Start a new transcription task in the background
    /// Uses local Parakeet + Sortformer pipeline: Transcribe → Save with Speaker Attribution → Extract Action Items
    /// - Parameter healthInfo: Recording health metrics for transcript metadata (Phase 3: Post-hoc transparency)
    func startTranscription(micURL: URL, systemURL: URL?, outputFolder: URL, healthInfo: RecordingHealthInfo? = nil) {

        // Cancel the pre-load timeout — the pipeline will handle Qwen cleanup itself
        qwenTimeoutTask?.cancel()
        qwenTimeoutTask = nil

        // Gate: reject recordings shorter than 2 seconds (they'll fail in Parakeet anyway)
        let minDuration: TimeInterval = 2.0
        if let micDuration = audioDuration(url: micURL), micDuration < minDuration {
            AppLogger.pipeline.info("Recording too short, skipping transcription", ["duration": String(format: "%.1fs", micDuration)])

            // Clean up audio files — they're useless
            try? FileManager.default.removeItem(at: micURL)
            if let systemURL { try? FileManager.default.removeItem(at: systemURL) }

            cleanupQwen()

            self.displayStatus = .failed(message: "Recording too short")
            self.scheduleStatusReset(delay: 3)
            return
        }

        let task = TranscriptionTask(micURL: micURL, systemURL: systemURL, outputFolder: outputFolder, healthInfo: healthInfo)

        // Increment active count and set initial status immediately (Goal-Gradient Effect)
        activeCount += 1
        backgroundTaskCount += 1
        displayStatus = .gettingReady

        AppLogger.pipeline.info("Starting transcription task", ["taskId": "\(task.id)", "activeCount": "\(activeCount)"])

        // Start Qwen safety timeout now that recording is done and pipeline is starting.
        // The pipeline will call cleanupQwen() when it's done with Qwen, so this timeout
        // only fires as a safety net if the task is cancelled before reaching Qwen cleanup.
        startQwenTimeout()

        // Create async task
        let asyncTask = Task {
            do {
                // TESTING: Uncomment the line below to force a failure for testing the retry mechanism
                // throw NSError(domain: "TestError", code: 999, userInfo: [NSLocalizedDescriptionKey: "Test transcription failure - this is intentional for testing"])

                // Update to transcribing state
                await MainActor.run {
                    self.displayStatus = .transcribing(progress: 0.0)
                }

                // Local pipeline: Parakeet STT + Sortformer diarization → Identify Speakers → Save → Action Items
                let transcriptURL = try await self.transcribeWithSpeakerIdentification(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputFolder: outputFolder,
                    taskId: task.id,
                    healthInfo: task.healthInfo
                )

                await MainActor.run {
                    self.displayStatus = .transcriptSaved
                    self.scheduleStatusReset()
                }

                await MainActor.run {
                    self.handleTaskCompletion(taskId: task.id)
                }

            } catch {
                AppLogger.pipeline.error("Transcription task failed", ["taskId": "\(task.id)", "error": "\(error.localizedDescription)"])

                await MainActor.run {
                    // Set failed status
                    self.displayStatus = .failed(message: "Transcription failed")

                    // Save to failed transcriptions queue
                    self.failedTranscriptionManager.addFailedTranscription(
                        micAudioURL: micURL,
                        systemAudioURL: systemURL,
                        errorMessage: error.localizedDescription
                    )

                    // Send macOS notification so user knows it failed (UX: Doherty Threshold)
                    self.sendFailureNotification(errorMessage: error.localizedDescription)

                    self.handleTaskCompletion(taskId: task.id)
                }
            }
        }

        activeTasks[task.id] = asyncTask
    }

    // MARK: - Local Transcription Pipeline

    /// Transcribe with multichannel mode (requires both mic and system audio)
    /// - Returns: URL of saved transcript with speaker attribution
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated private func transcribeWithSpeakerIdentification(
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
    nonisolated private func transcribeMultichannelPipeline(
        micURL: URL,
        systemURL: URL,
        outputFolder: URL,
        taskId: UUID,
        healthInfo: RecordingHealthInfo?
    ) async throws -> URL {

        AppLogger.pipeline.info("Using local Parakeet + Sortformer pipeline")

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

        // Build sortformer-ID → persistent DB UUID mapping for YAML
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
                    let unidentifiedClips = clips.filter { $0.currentName == nil }

                    if !unidentifiedClips.isEmpty && QwenService.isEnabled && QwenService.isModelCached {
                        let inferenceText = self.buildTranscriptTextForInference(
                            utterances: result.systemUtterances,
                            speakerMappings: speakerMappings
                        )

                        if !inferenceText.isEmpty {
                            // Free ~1.5 GB — transcription is done, these models aren't needed during speaker naming
                            await MainActor.run {
                                self.transcription.parakeet.cleanup()
                                self.transcription.sortformer.cleanup()
                            }
                            AppLogger.pipeline.info("Unloaded Parakeet + Sortformer before Qwen inference")

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
                                    qwenSuggestions = try await qwen.inferSpeakerNames(transcript: inferenceText)
                                }
                                await MainActor.run { self.cleanupQwen() }

                                // Reload for next recording (~0.3s from cache)
                                await self.transcription.initializeModels()
                                AppLogger.pipeline.info("Reloaded Parakeet + Sortformer after Qwen cleanup")

                                AppLogger.pipeline.info("Qwen speaker inference complete", [
                                    "suggestions": "\(qwenSuggestions.filter { $0.value != "Unknown" }.count)",
                                    "total": "\(qwenSuggestions.count)"
                                ])
                            } catch {
                                await MainActor.run { self.cleanupQwen() }

                                // Reload for next recording (~0.3s from cache)
                                await self.transcription.initializeModels()
                                AppLogger.pipeline.info("Reloaded Parakeet + Sortformer after Qwen cleanup")

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

    /// Retry a failed transcription by its ID
    /// Requires system audio for multichannel transcription
    func retryFailedTranscription(failedId: UUID) async -> Bool {
        guard let failed = failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == failedId }) else {
            AppLogger.pipeline.error("Failed transcription not found", ["failedId": "\(failedId)"])
            return false
        }

        // Don't retry permanent failures
        guard failed.isRetryable else {
            AppLogger.pipeline.info("Skipping retry — failure is permanent", ["failedId": "\(failedId)", "error": failed.errorMessage])
            return false
        }

        // Verify audio files still exist
        guard failed.audioFilesExist() else {
            AppLogger.pipeline.error("Audio files no longer exist for failed transcription", ["failedId": "\(failedId)"])
            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
            }
            return false
        }

        AppLogger.pipeline.info("Retrying failed transcription", ["failedId": "\(failedId)"])

        // Increment retry count and track as active task
        await MainActor.run {
            failedTranscriptionManager.incrementRetryCount(id: failedId)
            self.activeCount += 1
            self.backgroundTaskCount += 1
            self.displayStatus = .gettingReady
        }

        // Get output folder — respect custom save location from Settings
        let transcriptedFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            transcriptedFolder = URL(fileURLWithPath: customPath)
        } else {
            let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            transcriptedFolder = documentsURL.appendingPathComponent("Transcripted")
        }

        do {
            // Use multichannel pipeline when both sources available (consistent with main flow)
            // Note: healthInfo is nil for retries since we don't have the original recording state
            let transcriptURL = try await transcribeWithSpeakerIdentification(
                micURL: failed.micAudioURL,
                systemURL: failed.systemAudioURL,
                outputFolder: transcriptedFolder,
                taskId: failedId,
                healthInfo: nil
            )

            AppLogger.pipeline.info("Retry successful", ["file": transcriptURL.lastPathComponent])

            // Remove from failed queue (audio files already cleaned up by pipeline)
            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset()
            }

            return true

        } catch {
            AppLogger.pipeline.error("Retry failed", ["error": "\(error.localizedDescription)"])
            await MainActor.run {
                self.activeCount = max(0, self.activeCount - 1)
                self.backgroundTaskCount = max(0, self.backgroundTaskCount - 1)
                self.displayStatus = .failed(message: "Retry failed")
                self.scheduleStatusReset(delay: 8)
            }
            return false
        }
    }


    // MARK: - Speaker Naming Flow

    /// Handle completion of the speaker naming flow.
    /// Applies names to the database, updates the transcript, and cleans up.
    func handleNamingComplete(
        updates: [SpeakerNameUpdate],
        transcriptURL: URL,
        micURL: URL,
        systemURL: URL,
        clips: [SpeakerNamingEntry]
    ) {
        let speakerDB = transcription.speakerDB

        // Apply name updates to speaker database
        for update in updates {
            switch update.action {
            case .merged(let targetId):
                speakerDB.mergeProfiles(sourceId: update.persistentSpeakerId, into: targetId)

            case .named, .corrected:
                speakerDB.setDisplayName(
                    id: update.persistentSpeakerId,
                    name: update.newName,
                    source: "user_manual"
                )

            case .confirmed:
                speakerDB.setDisplayName(
                    id: update.persistentSpeakerId,
                    name: update.newName,
                    source: "user_manual"
                )
                speakerDB.resetDisputeCount(id: update.persistentSpeakerId)
            }

            AppLogger.speakers.info("Speaker named", [
                "id": "\(update.persistentSpeakerId)",
                "name": update.newName,
                "action": "\(update.action)"
            ])
        }

        // Merge profiles that ended up with the same name (e.g., user named 4 profiles "Jenny Wen")
        speakerDB.mergeProfilesByName()
        // Also re-run duplicate detection now that profiles have been updated
        speakerDB.mergeDuplicates()

        // Update the saved transcript file with real names
        if !updates.isEmpty {
            TranscriptSaver.updateSpeakerNames(transcriptURL: transcriptURL, updates: updates)
        }

        // Clean up clips and audio files
        SpeakerClipExtractor.cleanupClips(clips)
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)

        // Clear the naming request
        self.speakerNamingRequest = nil

        AppLogger.pipeline.info("Speaker naming complete", [
            "named": "\(updates.count)",
            "transcript": transcriptURL.lastPathComponent
        ])
    }

    private func handleTaskCompletion(taskId: UUID) {
        // Remove from active tasks
        activeTasks.removeValue(forKey: taskId)
        activeCount -= 1
        backgroundTaskCount = max(0, backgroundTaskCount - 1)

        AppLogger.pipeline.info("Task cleaned up", ["taskId": "\(taskId)", "remaining": "\(activeCount)", "backgroundTasks": "\(backgroundTaskCount)"])

        // Show completion checkmark if this was the last task
        if activeCount == 0 {
            justCompleted = true

            // Reset flag after animation
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                self?.justCompleted = false
            }
        }
    }

    /// Clean up any tasks stuck in pendingNaming state.
    /// Called from applicationWillTerminate to prevent orphaned audio files.
    func cleanupPendingNaming() {
        if let request = speakerNamingRequest {
            try? FileManager.default.removeItem(at: request.micAudioURL)
            try? FileManager.default.removeItem(at: request.systemAudioURL)
            SpeakerClipExtractor.cleanupClips(request.speakers)
            speakerNamingRequest = nil
            AppLogger.pipeline.info("Cleaned up pending naming on shutdown")
        }
    }

    /// Cancel all active transcription tasks
    func cancelAll() {
        for (taskId, task) in activeTasks {
            task.cancel()
            AppLogger.pipeline.info("Cancelled task", ["taskId": "\(taskId)"])
        }
        activeTasks.removeAll()
        activeCount = 0
        backgroundTaskCount = 0
        displayStatus = .idle
    }

    /// Schedule reset of displayStatus to .idle after delay
    /// - Parameter delay: Seconds to wait before resetting (default 3s — quick return to idle so user can record again)
    func scheduleStatusReset(delay: TimeInterval = 3) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            switch self.displayStatus {
            case .transcriptSaved, .failed:
                self.displayStatus = .idle
            default:
                break
            }
        }
    }

    // MARK: - Qwen Transcript Builder

    /// Build a text representation of system audio transcript for Qwen speaker name inference.
    /// Samples strategically: first 5 min + last 5 min + evenly spaced middle samples,
    /// capped at 8000 characters to stay within Qwen's effective context window.
    /// This captures greetings, mid-meeting name references, and closing "Thanks, [name]" patterns.
    nonisolated private func buildTranscriptTextForInference(
        utterances: [TranscriptionUtterance],
        speakerMappings: [String: SpeakerMapping]
    ) -> String {
        let sorted = utterances.sorted { $0.start < $1.start }
        guard !sorted.isEmpty else { return "" }

        let maxChars = 8000
        let totalDuration = sorted.last!.start

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

    // MARK: - Failure Notifications (UX: Doherty Threshold - users need immediate feedback)

    /// Request notification permission on first launch
    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                AppLogger.app.info("Notification permission granted")
            } else if let error = error {
                AppLogger.app.warning("Notification permission error", ["error": "\(error.localizedDescription)"])
            }
        }
    }

    /// Check audio file duration using AVAudioFile (quick metadata read, no decoding)
    private func audioDuration(url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = Double(file.length)
        let sampleRate = file.processingFormat.sampleRate
        guard sampleRate > 0 else { return nil }
        return frames / sampleRate
    }

    /// Send a macOS notification when transcription fails.
    /// Guards on authorization status to avoid UNErrorDomain error 1.
    private func sendFailureNotification(errorMessage: String) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else {
                AppLogger.pipeline.debug("Skipping failure notification — not authorized")
                return
            }

            let content = UNMutableNotificationContent()
            content.title = "Transcription Failed"
            content.body = "Recording saved. Tap to retry."
            content.sound = .default
            content.categoryIdentifier = "TRANSCRIPTION_FAILURE"
            content.userInfo = ["errorMessage": errorMessage]

            let request = UNNotificationRequest(
                identifier: "transcription-failure-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )

            UNUserNotificationCenter.current().add(request) { error in
                if let error = error {
                    AppLogger.app.warning("Failed to send notification", ["error": "\(error.localizedDescription)"])
                }
            }
        }
    }
}

