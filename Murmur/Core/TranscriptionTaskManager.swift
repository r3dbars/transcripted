import Foundation
import UserNotifications

// MARK: - Display Status for UI (Goal-Gradient Effect)
// Users are more motivated when they can see visible progress
// Simplified to 4 user-focused phases for cognitive clarity

enum DisplayStatus: Equatable {
    case idle

    // Processing phases (4 user-focused steps)
    case gettingReady                    // 0-15%: Loading audio, initial setup
    case transcribing(progress: Double)  // 15-75%: Active transcription
    case findingActionItems              // 75-95%: AI analysis
    case finishing                       // 95-100%: Saving, final steps

    // Completion states
    case transcriptSaved                 // Complete but no action items
    case pendingReview(itemCount: Int)   // Waiting for user to review action items
    case completed(taskCount: Int)       // Complete with action items
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
        case .findingActionItems:
            return 0.85
        case .finishing:
            return 0.97
        case .transcriptSaved, .pendingReview, .completed:
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
        case .findingActionItems:
            return "Finding tasks..."
        case .finishing:
            return "Almost done..."
        case .transcriptSaved:
            return "Saved"
        case .pendingReview(let count):
            return "\(count) item\(count == 1 ? "" : "s") to review"
        case .completed(let count):
            return "\(count) task\(count == 1 ? "" : "s") added"
        case .failed(let message):
            return message
        }
    }

    /// Icon for the status (SF Symbol name)
    var icon: String {
        switch self {
        case .idle:
            return "circle"
        case .gettingReady, .transcribing, .findingActionItems, .finishing:
            return "arrow.triangle.2.circlepath"
        case .transcriptSaved:
            return "checkmark.circle.fill"
        case .pendingReview:
            return "checklist"
        case .completed:
            return "checkmark.seal.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    /// Whether this is a "processing" state (show progress indicator)
    var isProcessing: Bool {
        switch self {
        case .gettingReady, .transcribing, .findingActionItems, .finishing:
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

    // Action item result state - for in-app notification
    @Published var actionItemsAddedCount: Int = 0
    @Published var showActionItemsAdded: Bool = false

    // Phase 2: Track full task creation result for error visibility
    @Published var lastTaskCreationResult: TaskCreationResult?

    // Action item review state - holds items pending user review
    @Published var pendingReview: PendingActionItemsReview? = nil
    @Published var isSubmittingReview: Bool = false

    // PHASE 3 FIX: Deferred items from previous review (merged into next review instead of auto-submitted)
    private var deferredActionItems: [SelectableActionItem] = []

    // Cache speaker identification result from transcription phase to reuse in action item extraction
    private var cachedSpeakerResult: SpeakerIdentificationResult?

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    let transcription = Transcription()

    // Reference to failed transcription manager
    private let failedTranscriptionManager: FailedTranscriptionManager

    // PHASE 6: Failed action item extraction manager with retry queue
    let failedActionItemManager = FailedActionItemManager()

    init(failedTranscriptionManager: FailedTranscriptionManager) {
        self.failedTranscriptionManager = failedTranscriptionManager
    }

    /// Start a new transcription task in the background
    /// Uses local Parakeet + Sortformer pipeline: Transcribe → Save with Speaker Attribution → Extract Action Items
    /// - Parameter healthInfo: Recording health metrics for transcript metadata (Phase 3: Post-hoc transparency)
    func startTranscription(micURL: URL, systemURL: URL?, outputFolder: URL, healthInfo: RecordingHealthInfo? = nil) {
        let task = TranscriptionTask(micURL: micURL, systemURL: systemURL, outputFolder: outputFolder, healthInfo: healthInfo)

        // Increment active count and set initial status immediately (Goal-Gradient Effect)
        DispatchQueue.main.async {
            self.activeCount += 1
            self.backgroundTaskCount += 1
            self.displayStatus = .gettingReady
        }

        AppLogger.pipeline.info("Starting transcription task", ["taskId": "\(task.id)", "activeCount": "\(activeCount)"])

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

                // Extract action items from the saved transcript
                await self.extractAndSendActionItems(from: transcriptURL)

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

    /// Format TranscriptionResult as text for Gemini speaker identification
    /// Uses same format as saved transcript so Gemini can match speaker IDs
    nonisolated private static func formatForSpeakerIdentification(_ result: TranscriptionResult) -> String {
        return result.allUtterances.map { utterance in
            let minutes = Int(utterance.start) / 60
            let seconds = Int(utterance.start) % 60
            let timestamp = String(format: "[%02d:%02d]", minutes, seconds)
            let source = utterance.channel == 0 ? "Mic" : "System"
            let speaker = utterance.channel == 0 ? "You" : "Speaker \(utterance.speakerId)"
            return "\(timestamp) [\(source)/\(speaker)] \(utterance.transcript)"
        }.joined(separator: "\n")
    }

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
            throw NSError(domain: "Transcription", code: 100, userInfo: [
                NSLocalizedDescriptionKey: "System audio is required. Please grant Screen Recording permission in System Settings."
            ])
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

        // Phase 1.5: Identify speakers — DB knowledge first, then Gemini if needed
        var speakerMappings: [String: SpeakerMapping] = [:]
        var speakerSources: [String: String] = [:]  // "db" or "gemini" per speaker ID
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

        // Check if ALL system speakers are already known with high confidence
        let allSpeakersKnown = !speakerIds.isEmpty &&
            speakerIds.allSatisfy { sid in
                dbKnowledge.contains { $0.speakerId == sid && $0.profile.displayName != nil && $0.similarity > 0.85 && $0.profile.callCount > 3 }
            }

        let geminiAPIKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""

        if allSpeakersKnown {
            // Skip Gemini entirely — build mappings + synthetic SpeakerIdentificationResult from DB
            AppLogger.speakers.info("All speakers known from DB, skipping Gemini", ["speakerCount": "\(speakerIds.count)"])

            var identifiedSpeakers: [IdentifiedSpeaker] = []
            for entry in dbKnowledge {
                guard let name = entry.profile.displayName else { continue }
                let key = "system_\(entry.speakerId)"
                let confidence = entry.similarity > 0.85 && entry.profile.callCount > 3 ? "high" : "medium"
                speakerMappings[key] = SpeakerMapping(
                    speakerId: entry.speakerId,
                    identifiedName: name,
                    confidence: confidence
                )
                speakerSources[entry.speakerId] = "db"
                identifiedSpeakers.append(IdentifiedSpeaker(
                    name: name,
                    speakerId: entry.speakerId,
                    confidence: confidence,
                    evidence: "Voice fingerprint match (\(String(format: "%.0f", entry.similarity * 100))%, \(entry.profile.callCount) calls)"
                ))
            }

            speakerResult = SpeakerIdentificationResult(speakers: identifiedSpeakers, userSpeakerId: nil)
            let resultToCache = speakerResult
            await MainActor.run {
                self.cachedSpeakerResult = resultToCache
            }

        } else if !geminiAPIKey.isEmpty {
            // Call Gemini with DB preamble for context
            await MainActor.run {
                self.displayStatus = .finishing
            }

            do {
                let transcriptText = Self.formatForSpeakerIdentification(result)
                let userName = UserDefaults.standard.string(forKey: "userName")
                let effectiveUserName = (userName?.isEmpty ?? true) ? "You" : userName!

                // Build preamble from DB knowledge with trust tier framing
                var preambleLines: [String] = []
                if !dbKnowledge.isEmpty {
                    preambleLines.append("Known speakers from voice fingerprint database:")
                    for entry in dbKnowledge {
                        let sim = String(format: "%.0f", entry.similarity * 100)
                        if let name = entry.profile.displayName {
                            let isUserSet = entry.profile.nameSource == "user_manual"
                            if isUserSet || (entry.similarity > 0.85 && entry.profile.callCount > 3) {
                                // LOCKED tier
                                let source = isUserSet ? "user-confirmed" : "voice-confirmed"
                                preambleLines.append("- Speaker \(entry.speakerId): LOCKED as \"\(name)\" (\(sim)% voice match, \(entry.profile.callCount) calls, \(source))")
                                preambleLines.append("  → Do NOT rename this speaker unless you find very strong contradictory evidence.")
                            } else if entry.similarity > 0.75 && entry.profile.callCount > 1 {
                                // PROBABLE tier
                                preambleLines.append("- Speaker \(entry.speakerId): Likely \"\(name)\" (\(sim)% voice match, \(entry.profile.callCount) calls)")
                                preambleLines.append("  → Confirm or correct this name based on transcript evidence.")
                            } else {
                                // TENTATIVE tier
                                preambleLines.append("- Speaker \(entry.speakerId): Possibly \"\(name)\" (\(sim)% voice match, \(entry.profile.callCount) call\(entry.profile.callCount == 1 ? "" : "s") — LOW CONFIDENCE)")
                                preambleLines.append("  → This is a weak match. Look for transcript evidence to confirm or override.")
                            }
                        } else {
                            preambleLines.append("- Speaker \(entry.speakerId): Recurring voice, no name yet (\(sim)% match to unnamed profile, \(entry.profile.callCount) calls)")
                            preambleLines.append("  → Identify this person if possible from conversation context.")
                        }
                    }
                    for sid in speakerIds where !dbKnowledge.contains(where: { $0.speakerId == sid }) {
                        preambleLines.append("- Speaker \(sid): New speaker (no voice match in database)")
                        preambleLines.append("  → Identify this person if possible from conversation context.")
                    }
                }
                let speakerContext = preambleLines.joined(separator: "\n")

                AppLogger.speakers.info("Identifying speakers with Gemini", ["dbKnownCount": "\(dbKnowledge.count)"])
                speakerResult = try await ActionItemExtractor.identifySpeakers(
                    from: transcriptText,
                    speakerIds: speakerIds,
                    userName: effectiveUserName,
                    apiKey: geminiAPIKey,
                    speakerContext: speakerContext
                )

                // Convert to mappings
                speakerMappings = ActionItemExtractor.toSpeakerMappings(speakerResult!)
                for speaker in speakerResult!.speakers {
                    if let sid = speaker.speakerId {
                        speakerSources[sid] = "gemini"
                    }
                }

                let speakerNames = speakerResult!.speakers.map { $0.name }
                AppLogger.speakers.info("Speaker identification complete", ["count": "\(speakerResult!.speakers.count)", "names": speakerNames.joined(separator: ", ")])

                // Update SpeakerDatabase with confidence-gated overwriting
                for speaker in speakerResult!.speakers {
                    let matchingUtterances = result.systemUtterances.filter {
                        String($0.speakerId) == speaker.speakerId
                    }
                    guard let persistentId = matchingUtterances.first?.persistentSpeakerId else { continue }

                    // Look up existing DB profile to check current name
                    let existingProfile = speakerDB.getSpeaker(id: persistentId)

                    if let existingName = existingProfile?.displayName {
                        // Profile already has a name — apply confidence-gated logic
                        let nameSource = existingProfile?.nameSource

                        if nameSource == "user_manual" {
                            // NEVER override user-set names
                            AppLogger.speakers.info("Keeping user-set name", ["speakerId": "\(speaker.speakerId ?? "")", "existingName": existingName, "geminiSuggested": speaker.name])

                        } else if SpeakerDatabase.areNameVariants(existingName, speaker.name) {
                            // Names are variants (e.g., "Nate" / "Nathan") — not a conflict, reset disputes
                            AppLogger.speakers.info("Name variant match", ["speakerId": "\(speaker.speakerId ?? "")", "existingName": existingName, "variantName": speaker.name])
                            await MainActor.run {
                                self.transcription.speakerDB.resetDisputeCount(id: persistentId)
                            }

                        } else if (existingProfile?.callCount ?? 0) > 5 && speaker.confidence != "high" {
                            // Well-established name + non-high Gemini confidence → protect DB, log dispute
                            AppLogger.speakers.info("Protecting established name", ["speakerId": "\(speaker.speakerId ?? "")", "existingName": existingName, "callCount": "\(existingProfile?.callCount ?? 0)", "geminiSuggested": speaker.name, "confidence": speaker.confidence])
                            await MainActor.run {
                                self.transcription.speakerDB.incrementDisputeCount(id: persistentId)
                            }
                            speakerSources[speaker.speakerId ?? ""] = "db"

                        } else if (existingProfile?.callCount ?? 0) <= 2 {
                            // Low call count — Gemini can freely override
                            AppLogger.speakers.info("Overriding recent name", ["speakerId": "\(speaker.speakerId ?? "")", "oldName": existingName, "newName": speaker.name, "callCount": "\(existingProfile?.callCount ?? 0)"])
                            await MainActor.run {
                                self.transcription.speakerDB.setDisplayName(id: persistentId, name: speaker.name, source: "gemini_override")
                            }

                        } else if speaker.confidence == "high" {
                            // High confidence from Gemini with moderate call count — override
                            AppLogger.speakers.info("Gemini high-confidence override", ["speakerId": "\(speaker.speakerId ?? "")", "oldName": existingName, "newName": speaker.name])
                            await MainActor.run {
                                self.transcription.speakerDB.setDisplayName(id: persistentId, name: speaker.name, source: "gemini_override")
                            }

                        } else {
                            // Medium confidence Gemini vs moderate DB — log dispute, keep DB
                            AppLogger.speakers.info("Keeping DB name over Gemini suggestion", ["speakerId": "\(speaker.speakerId ?? "")", "existingName": existingName, "geminiSuggested": speaker.name, "confidence": "medium"])
                            await MainActor.run {
                                self.transcription.speakerDB.incrementDisputeCount(id: persistentId)
                            }
                            speakerSources[speaker.speakerId ?? ""] = "db"
                        }
                    } else {
                        // Profile has no name — Gemini can set it freely
                        AppLogger.speakers.info("Setting new name from Gemini", ["speakerId": "\(speaker.speakerId ?? "")", "name": speaker.name])
                        await MainActor.run {
                            self.transcription.speakerDB.setDisplayName(id: persistentId, name: speaker.name, source: "gemini_inferred")
                        }
                    }
                }

                // Cache for action item extraction
                let resultToCache = speakerResult
                await MainActor.run {
                    self.cachedSpeakerResult = resultToCache
                }
            } catch {
                AppLogger.speakers.error("Speaker identification failed, using defaults", ["error": "\(error.localizedDescription)"])
            }
        } else {
            AppLogger.speakers.info("No Gemini API key, skipping speaker identification")
        }

        // Fill gaps: use DB display names for any speaker IDs not yet in speakerMappings
        for entry in dbKnowledge {
            let key = "system_\(entry.speakerId)"
            if speakerMappings[key] == nil, let name = entry.profile.displayName {
                let confidence = entry.similarity > 0.85 && entry.profile.callCount > 3 ? "high" : "medium"
                speakerMappings[key] = SpeakerMapping(
                    speakerId: entry.speakerId,
                    identifiedName: name,
                    confidence: confidence
                )
                if speakerSources[entry.speakerId] == nil {
                    speakerSources[entry.speakerId] = "db"
                }
                AppLogger.speakers.info("DB fallback for speaker", ["speakerId": entry.speakerId, "name": name, "confidence": confidence, "similarity": String(format: "%.0f", entry.similarity * 100)])
            }
        }

        // Clean up duplicate speaker profiles that accumulated from noisy embeddings
        speakerDB.mergeDuplicates()

        // Phase 2: Save transcript with speaker names
        await MainActor.run {
            self.displayStatus = .finishing
        }

        guard let savedURL = TranscriptSaver.saveTranscript(
            result,
            speakerMappings: speakerMappings,
            speakerSources: speakerSources,
            directory: outputFolder,
            healthInfo: healthInfo
        ) else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to save transcript"
            ])
        }

        AppLogger.pipeline.info("Phase 2 complete: Transcript saved", ["file": savedURL.lastPathComponent])

        // Cleanup audio files
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

        // Verify audio files still exist
        guard failed.audioFilesExist() else {
            AppLogger.pipeline.error("Audio files no longer exist for failed transcription", ["failedId": "\(failedId)"])
            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
            }
            return false
        }

        AppLogger.pipeline.info("Retrying failed transcription", ["failedId": "\(failedId)"])

        // Increment retry count
        await MainActor.run {
            failedTranscriptionManager.incrementRetryCount(id: failedId)
            self.displayStatus = .gettingReady
        }

        // Get output folder (same as original)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let transcriptedFolder = documentsURL.appendingPathComponent("Transcripted")

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
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset()
            }

            return true

        } catch {
            AppLogger.pipeline.error("Retry failed", ["error": "\(error.localizedDescription)"])
            await MainActor.run {
                self.displayStatus = .failed(message: "Retry failed")
                self.scheduleStatusReset(delay: 8)
            }
            return false
        }
    }

    // MARK: - Retry Failed Action Item Extraction (Phase 6)

    /// Retry a failed action item extraction by its ID
    func retryFailedActionItemExtraction(failedId: UUID) async -> Bool {
        guard let failed = await MainActor.run(body: { failedActionItemManager.failedExtractions.first(where: { $0.id == failedId }) }) else {
            AppLogger.actionItems.error("Failed action item extraction not found", ["failedId": "\(failedId)"])
            return false
        }

        // Verify transcript file still exists
        guard failed.transcriptExists() else {
            AppLogger.actionItems.error("Transcript file no longer exists for failed extraction", ["failedId": "\(failedId)"])
            await MainActor.run {
                failedActionItemManager.removeFailedExtraction(id: failedId)
            }
            return false
        }

        AppLogger.actionItems.info("Retrying action item extraction", ["filename": failed.transcriptFilename])

        // Increment retry count (handles backoff timing)
        await MainActor.run {
            failedActionItemManager.incrementRetryCount(id: failedId)
        }

        do {
            // Read transcript content
            let content = try String(contentsOf: failed.transcriptURL, encoding: .utf8)
            let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""

            guard !apiKey.isEmpty else {
                throw ActionItemExtractionError.noAPIKey
            }

            // Extract action items using Gemini
            let result = try await ActionItemExtractor.extract(from: content, apiKey: apiKey)

            if result.actionItems.isEmpty {
                AppLogger.actionItems.info("Retry successful but no action items found")
                await MainActor.run {
                    failedActionItemManager.removeFailedExtraction(id: failedId)
                }
                return true
            }

            // Store items for user review
            await MainActor.run {
                self.pendingReview = PendingActionItemsReview(
                    items: result.actionItems.map { SelectableActionItem(item: $0) },
                    meetingTitle: result.meetingTitle,
                    meetingSummary: result.meetingSummary
                )
                self.displayStatus = .pendingReview(itemCount: result.actionItems.count)
                failedActionItemManager.removeFailedExtraction(id: failedId)
            }

            AppLogger.actionItems.info("Retry successful, action items ready for review", ["count": "\(result.actionItems.count)"])
            return true

        } catch {
            AppLogger.actionItems.error("Action item extraction retry failed", ["error": "\(error.localizedDescription)"])
            return false
        }
    }

    /// Retry all failed action item extractions that are ready (backoff elapsed)
    func retryAllReadyActionItemExtractions() async -> (succeeded: Int, failed: Int) {
        let ready = await MainActor.run { failedActionItemManager.extractionsReadyForRetry }
        var succeeded = 0
        var failed = 0

        for extraction in ready {
            let success = await retryFailedActionItemExtraction(failedId: extraction.id)
            if success {
                succeeded += 1
            } else {
                failed += 1
            }
        }

        AppLogger.actionItems.info("Retry batch complete", ["succeeded": "\(succeeded)", "failed": "\(failed)"])
        return (succeeded, failed)
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

            // Reset flag after animation (use weak self to prevent retain cycle)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.justCompleted = false
            }
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
    }

    // MARK: - Action Item Extraction

    /// Extract action items from transcript and present for user review
    /// Note: nonisolated to keep heavy async work (Gemini API calls) off the main thread
    nonisolated private func extractAndSendActionItems(from transcriptURL: URL) async {
        let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            AppLogger.actionItems.warning("Gemini API key not configured, skipping action item extraction")
            // Show "Transcript saved" status and reset after 10 seconds
            await MainActor.run {
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset()
            }
            return
        }

        // PHASE 3 FIX: If there are pending items from a previous recording, defer them
        // to be merged with the next review (instead of auto-submitting without consent)
        if let pending = await MainActor.run(body: { self.pendingReview }) {
            let selectedItems = pending.items.filter { $0.isSelected }
            if !selectedItems.isEmpty {
                await MainActor.run {
                    self.deferredActionItems = selectedItems
                    self.pendingReview = nil
                }
                AppLogger.actionItems.info("Deferred selected items to merge with next review", ["count": "\(selectedItems.count)"])
            } else {
                await MainActor.run {
                    self.pendingReview = nil
                }
                AppLogger.actionItems.info("Dismissed previous review (no items selected)")
            }
        }

        // Update status to show we're finding action items
        await MainActor.run {
            self.displayStatus = .findingActionItems
        }

        do {
            // Read transcript content
            let content = try String(contentsOf: transcriptURL, encoding: .utf8)

            // Get cached speaker result (if available from transcription phase)
            let cachedSpeakers = await MainActor.run { self.cachedSpeakerResult }

            // Extract action items using Gemini (reusing speaker identification if available)
            let result = try await ActionItemExtractor.extract(
                from: content,
                apiKey: apiKey,
                preIdentifiedSpeakers: cachedSpeakers
            )

            // Clear cached speaker result after use
            await MainActor.run { self.cachedSpeakerResult = nil }

            // Update transcript with Gemini-generated summary (if available)
            var currentURL = transcriptURL
            AppLogger.actionItems.info("Gemini extraction result", [
                "title": result.meetingTitle ?? "nil",
                "summaryLength": "\(result.meetingSummary?.count ?? 0)",
                "actionItemCount": "\(result.actionItems.count)"
            ])

            if let summary = result.meetingSummary, !summary.isEmpty {
                TranscriptUtils.updateWithSummary(at: currentURL, summary: summary)
            } else {
                AppLogger.actionItems.warning("No summary returned from Gemini")
            }

            // Rename file with descriptive title (if available)
            if let title = result.meetingTitle, !title.isEmpty {
                currentURL = TranscriptUtils.renameWithTitle(at: currentURL, title: title)
            }

            // Record action items to stats database and update YAML
            let actionItemCount = result.actionItems.count
            TranscriptUtils.updateActionItemsCount(at: currentURL, count: actionItemCount)

            if actionItemCount > 0 {
                // Convert to ActionItemRecord for database storage
                let records = result.actionItems.map { item in
                    ActionItemRecord(
                        task: item.task,
                        owner: item.owner,
                        priority: item.priority,
                        dueDate: item.dueDate,
                        destination: "extracted"
                    )
                }
                await StatsService.shared.recordActionItems(records, for: currentURL.path)
                AppLogger.stats.info("Recorded action items to stats database", ["count": "\(actionItemCount)"])
            }

            if result.actionItems.isEmpty {
                AppLogger.actionItems.info("No action items found in transcript")
                // Show transcript saved since no action items were found
                await MainActor.run {
                    self.displayStatus = .transcriptSaved
                    self.scheduleStatusReset()
                }
                return
            }

            // Store items for user review instead of auto-sending
            await MainActor.run {
                // Create new selectable items from extraction result
                var allItems = result.actionItems.map { SelectableActionItem(item: $0) }

                // PHASE 3 FIX: Merge any deferred items from previous review (prepend so they appear first)
                let deferredCount = self.deferredActionItems.count
                if deferredCount > 0 {
                    allItems = self.deferredActionItems + allItems
                    self.deferredActionItems = []  // Clear after merging
                    AppLogger.actionItems.info("Merged deferred items into new review", ["deferredCount": "\(deferredCount)"])
                }

                // Create pending review with merged items
                self.pendingReview = PendingActionItemsReview(
                    items: allItems,
                    meetingTitle: result.meetingTitle,
                    meetingSummary: result.meetingSummary
                )
                self.displayStatus = .pendingReview(itemCount: allItems.count)
                // Don't schedule reset - wait for user action
            }
            AppLogger.actionItems.info("Action items ready for review", ["count": "\(result.actionItems.count)"])

        } catch {
            AppLogger.actionItems.error("Action item extraction failed", ["error": "\(error.localizedDescription)"])

            // PHASE 6: Track failure for retry
            await MainActor.run {
                self.failedActionItemManager.addFailedExtraction(
                    transcriptURL: transcriptURL,
                    error: error
                )
            }

            // Still show transcript saved on error (transcript exists, just extraction failed)
            await MainActor.run {
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset()
            }
        }
    }

    // MARK: - Action Item Review Methods

    /// Toggle selection state of a single action item
    func toggleItemSelection(id: UUID) {
        guard var review = pendingReview,
              let index = review.items.firstIndex(where: { $0.id == id }) else {
            return
        }
        review.items[index].isSelected.toggle()
        pendingReview = review
    }

    /// Select all action items
    func selectAllItems() {
        guard var review = pendingReview else { return }
        for i in review.items.indices {
            review.items[i].isSelected = true
        }
        pendingReview = review
    }

    /// Deselect all action items
    func deselectAllItems() {
        guard var review = pendingReview else { return }
        for i in review.items.indices {
            review.items[i].isSelected = false
        }
        pendingReview = review
    }

    /// Submit selected action items to configured task service
    func submitSelectedItems() async {
        await submitSelectedItemsInternal()
    }

    /// Internal implementation for submitting selected items
    /// Phase 2: Now handles TaskCreationResult for proper error visibility
    private func submitSelectedItemsInternal() async {
        guard let review = await MainActor.run(body: { self.pendingReview }) else { return }

        let selectedItems = review.selectedItems
        guard !selectedItems.isEmpty else {
            // No items selected, just skip
            await skipReview()
            return
        }

        await MainActor.run {
            self.isSubmittingReview = true
        }

        // Send to configured task service (Reminders or Todoist)
        let taskServiceSetting = UserDefaults.standard.string(forKey: "taskService") ?? "reminders"
        let result: TaskCreationResult

        if taskServiceSetting == "todoist" {
            // Use Todoist
            let todoist = TodoistService()
            result = await todoist.createTasks(from: selectedItems)
            AppLogger.actionItems.info("Todoist result", ["summary": result.summary])
        } else {
            // Use Apple Reminders (default)
            let reminders = RemindersService()
            guard await reminders.requestAccess() else {
                AppLogger.actionItems.warning("Reminders access denied")
                // Phase 2: Create a proper failure result for visibility
                let failure = TaskCreationFailure(
                    taskTitle: "All tasks",
                    errorMessage: "Reminders access denied",
                    isRecoverable: false,
                    recoveryHint: "Enable Reminders access in System Settings → Privacy & Security → Reminders"
                )
                await MainActor.run {
                    self.isSubmittingReview = false
                    self.pendingReview = nil
                    self.lastTaskCreationResult = .failed(failures: [failure])
                    self.displayStatus = .failed(message: "Reminders access denied")
                    self.scheduleStatusReset(delay: 8)  // Keep error visible longer
                }
                return
            }
            result = await reminders.createReminders(from: selectedItems)
            AppLogger.actionItems.info("Reminders result", ["summary": result.summary])
        }

        // Phase 2: Handle all result cases - success, partial, and failure
        await MainActor.run {
            self.isSubmittingReview = false
            self.pendingReview = nil
            self.lastTaskCreationResult = result
            self.actionItemsAddedCount = result.successCount

            if result.allSucceeded {
                // All tasks created successfully
                self.showActionItemsAdded = true
                self.displayStatus = .completed(taskCount: result.successCount)
                self.scheduleStatusReset()
            } else if result.partialSuccess {
                // Some tasks created, some failed - show success but also track failures
                self.showActionItemsAdded = true
                self.displayStatus = .completed(taskCount: result.successCount)
                // Log failures for debugging
                AppLogger.actionItems.warning("Some tasks failed to create", ["failureCount": "\(result.failureCount)"])
                for failure in result.failures {
                    AppLogger.actionItems.warning("Task creation failed", ["task": failure.taskTitle, "error": failure.errorMessage])
                }
                self.scheduleStatusReset()
            } else if result.allFailed {
                // All tasks failed
                let errorMessage = result.failures.first?.errorMessage ?? "Failed to create tasks"
                self.displayStatus = .failed(message: errorMessage)
                self.scheduleStatusReset(delay: 8)  // Keep error visible longer
            } else {
                // Empty result (shouldn't happen but handle gracefully)
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset()
            }
        }
    }

    /// Skip review without adding any action items
    func skipReview() async {
        await MainActor.run {
            self.pendingReview = nil
            self.displayStatus = .transcriptSaved
            self.scheduleStatusReset()
        }
        AppLogger.actionItems.info("Action item review skipped")
    }

    /// Schedule reset of displayStatus to .idle after delay
    /// - Parameter delay: Seconds to wait before resetting (default 3s — quick return to idle so user can record again)
    private func scheduleStatusReset(delay: TimeInterval = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // Only reset if we're in a completion state (not if new recording started or pending review)
            switch self.displayStatus {
            case .completed, .transcriptSaved, .failed:
                self.displayStatus = .idle
            case .pendingReview:
                // Don't reset - user is still reviewing
                break
            default:
                break
            }
        }
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

    /// Send a macOS notification when transcription fails
    private func sendFailureNotification(errorMessage: String) {
        let content = UNMutableNotificationContent()
        content.title = "Transcription Failed"
        content.body = "Recording saved. Tap to retry."
        content.sound = .default
        content.categoryIdentifier = "TRANSCRIPTION_FAILURE"

        // Add error details as user info for potential use
        content.userInfo = ["errorMessage": errorMessage]

        // Create the request with a unique identifier
        let request = UNNotificationRequest(
            identifier: "transcription-failure-\(UUID().uuidString)",
            content: content,
            trigger: nil  // nil = deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                AppLogger.app.warning("Failed to send notification", ["error": "\(error.localizedDescription)"])
            } else {
                AppLogger.app.info("Failure notification sent")
            }
        }
    }
}

