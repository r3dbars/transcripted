import Foundation
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

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    let transcription = Transcription()

    // Reference to failed transcription manager
    private let failedTranscriptionManager: FailedTranscriptionManager

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
        } else {
            AppLogger.speakers.info("Using DB-only speaker identification (no Gemini)")
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

    /// Schedule reset of displayStatus to .idle after delay
    /// - Parameter delay: Seconds to wait before resetting (default 3s — quick return to idle so user can record again)
    func scheduleStatusReset(delay: TimeInterval = 3) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            switch self.displayStatus {
            case .transcriptSaved, .failed:
                self.displayStatus = .idle
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

