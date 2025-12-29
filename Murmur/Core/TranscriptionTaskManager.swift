import Foundation
import UserNotifications

// MARK: - Display Status for UI (Goal-Gradient Effect)
// Users are more motivated when they can see visible progress

enum DisplayStatus: Equatable {
    case idle
    case preparing                      // 0-10%: Loading audio files
    case transcribing(progress: Double) // 10-70%: Active transcription
    case extractingActionItems          // 70-90%: AI processing
    case saving                         // 90-95%: Writing to disk
    case transcriptSaved                // Complete but no action items
    case pendingReview(itemCount: Int)  // Waiting for user to review action items
    case completed(taskCount: Int)      // Complete with action items
    case failed(message: String)        // Error state

    /// Computed progress value (0.0 to 1.0) for UI progress bar
    var progress: Double {
        switch self {
        case .idle:
            return 0.0
        case .preparing:
            return 0.10
        case .transcribing(let p):
            // Map transcription progress (0-1) to (0.10-0.70)
            return 0.10 + (p * 0.60)
        case .extractingActionItems:
            return 0.80
        case .saving:
            return 0.95
        case .transcriptSaved, .pendingReview, .completed:
            return 1.0
        case .failed:
            return 0.0
        }
    }

    /// User-friendly status text
    var statusText: String {
        switch self {
        case .idle:
            return "Ready"
        case .preparing:
            return "Preparing..."
        case .transcribing(let p):
            let pct = Int(p * 100)
            return "Transcribing (\(pct)%)"
        case .extractingActionItems:
            return "Extracting tasks..."
        case .saving:
            return "Saving..."
        case .transcriptSaved:
            return "Saved"
        case .pendingReview(let count):
            return "\(count) task\(count == 1 ? "" : "s") to review"
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
        case .preparing, .transcribing, .extractingActionItems, .saving:
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

    /// Whether this is a "processing" state (show progress bar)
    var isProcessing: Bool {
        switch self {
        case .preparing, .transcribing, .extractingActionItems, .saving:
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

    init(micURL: URL, systemURL: URL?, outputFolder: URL) {
        self.id = UUID()
        self.micURL = micURL
        self.systemURL = systemURL
        self.outputFolder = outputFolder
        self.startTime = Date()
    }
}

@available(macOS 26.0, *)
class TranscriptionTaskManager: ObservableObject {
    @Published var activeCount: Int = 0
    @Published var justCompleted: Bool = false

    // Display status for the status bar
    @Published var displayStatus: DisplayStatus = .idle

    // Action item result state - for in-app notification
    @Published var actionItemsAddedCount: Int = 0
    @Published var showActionItemsAdded: Bool = false

    // Phase 2: Track full task creation result for error visibility
    @Published var lastTaskCreationResult: TaskCreationResult?

    // Action item review state - holds items pending user review
    @Published var pendingReview: PendingActionItemsReview? = nil
    @Published var isSubmittingReview: Bool = false

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private let transcription = Transcription()

    // Reference to failed transcription manager
    private let failedTranscriptionManager: FailedTranscriptionManager

    init(failedTranscriptionManager: FailedTranscriptionManager) {
        self.failedTranscriptionManager = failedTranscriptionManager
    }

    /// Start a new transcription task in the background
    /// Uses enhanced pipeline for AssemblyAI: Transcribe → Identify Speakers → Save with Names → Action Items
    func startTranscription(micURL: URL, systemURL: URL?, outputFolder: URL) {
        let task = TranscriptionTask(micURL: micURL, systemURL: systemURL, outputFolder: outputFolder)

        // Increment active count and set preparing status immediately (Goal-Gradient Effect)
        DispatchQueue.main.async {
            self.activeCount += 1
            self.displayStatus = .preparing
        }

        print("📝 Starting transcription task \(task.id) (active: \(activeCount))")

        // Create async task
        let asyncTask = Task {
            do {
                // TESTING: Uncomment the line below to force a failure for testing the retry mechanism
                // throw NSError(domain: "TestError", code: 999, userInfo: [NSLocalizedDescriptionKey: "Test transcription failure - this is intentional for testing"])

                // Update to transcribing state
                await MainActor.run {
                    self.displayStatus = .transcribing(progress: 0.0)
                }

                // AssemblyAI pipeline: Transcribe → Identify Speakers → Save with Names → Action Items
                let transcriptURL = try await self.transcribeWithSpeakerIdentification(
                    micURL: micURL,
                    systemURL: systemURL,
                    outputFolder: outputFolder,
                    taskId: task.id
                )

                // Extract action items from the saved transcript
                await self.extractAndSendActionItems(from: transcriptURL)

                await MainActor.run {
                    self.handleTaskCompletion(taskId: task.id)
                }

            } catch {
                print("❌ Transcription task \(task.id) failed: \(error.localizedDescription)")

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

    // MARK: - Enhanced AssemblyAI Pipeline with Speaker Identification

    /// Transcribe with speaker identification: Transcribe → Identify Speakers → Save with Names
    /// - Returns: URL of saved transcript with identified speaker names
    private func transcribeWithSpeakerIdentification(
        micURL: URL,
        systemURL: URL?,
        outputFolder: URL,
        taskId: UUID
    ) async throws -> URL {

        // Phase 1: Transcribe and get intermediate result (not saved yet)
        let transcriptionResult = try await transcription.transcribeToIntermediateResult(
            micURL: micURL,
            systemURL: systemURL,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.displayStatus = .transcribing(progress: progress)
                }
            }
        )

        print("✅ Phase 1 complete: Transcription done, \(transcriptionResult.allSpeakerIds.count) speakers detected")

        // Phase 2: Identify speakers with Gemini (if API key available)
        var speakerMappings: [String: SpeakerMapping] = [:]
        let geminiApiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        let userName = UserDefaults.standard.string(forKey: "userName") ?? "You"

        if !geminiApiKey.isEmpty && !transcriptionResult.allSpeakerIds.isEmpty {
            await MainActor.run {
                self.displayStatus = .extractingActionItems  // Reuse status for "AI processing"
            }

            print("📋 Phase 2: Identifying \(transcriptionResult.allSpeakerIds.count) speakers with Gemini...")

            // Generate preliminary transcript for Gemini
            let preliminaryTranscript = ActionItemExtractor.generatePreliminaryTranscript(from: transcriptionResult)

            // Identify speakers
            let speakerResult = await ActionItemExtractor.identifySpeakersWithFallback(
                from: preliminaryTranscript,
                speakerIds: Array(transcriptionResult.allSpeakerIds).sorted(),
                userName: userName,
                apiKey: geminiApiKey
            )

            // Build speaker mappings
            speakerMappings = ActionItemExtractor.buildSpeakerMappings(
                from: speakerResult,
                allSpeakerIds: transcriptionResult.allSpeakerIds,
                userName: userName
            )

            let identifiedCount = speakerMappings.values.filter { $0.identifiedName != nil }.count
            print("✅ Phase 2 complete: Identified \(identifiedCount) of \(speakerMappings.count) speakers")

        } else {
            // No Gemini key or no speakers - use generic mappings
            for id in transcriptionResult.allSpeakerIds {
                speakerMappings[id] = SpeakerMapping(speakerId: id, identifiedName: nil, confidence: nil)
            }
            print("ℹ️ Phase 2 skipped: Using generic speaker labels")
        }

        // Phase 3: Save transcript WITH speaker names
        await MainActor.run {
            self.displayStatus = .saving
        }

        guard let transcriptURL = TranscriptSaver.saveRichAssemblyAITranscript(
            transcriptionResult,
            speakerMappings: speakerMappings,
            directory: outputFolder
        ) else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to save transcript"
            ])
        }

        print("✅ Phase 3 complete: Transcript saved to \(transcriptURL.lastPathComponent)")

        // Cleanup audio files
        try? FileManager.default.removeItem(at: micURL)
        if let systemURL = systemURL {
            try? FileManager.default.removeItem(at: systemURL)
        }

        return transcriptURL
    }

    /// Retry a failed transcription by its ID
    func retryFailedTranscription(failedId: UUID) async -> Bool {
        guard let failed = failedTranscriptionManager.failedTranscriptions.first(where: { $0.id == failedId }) else {
            print("❌ Failed transcription not found: \(failedId)")
            return false
        }

        // Verify audio files still exist
        guard failed.audioFilesExist() else {
            print("❌ Audio files no longer exist for failed transcription: \(failedId)")
            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
            }
            return false
        }

        print("🔄 Retrying failed transcription: \(failedId)")

        // Increment retry count
        await MainActor.run {
            failedTranscriptionManager.incrementRetryCount(id: failedId)
        }

        // Get output folder (same as original)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let transcriptedFolder = documentsURL.appendingPathComponent("Transcripted")

        do {
            let transcriptURL = try await transcription.transcribeMeetingFiles(
                micURL: failed.micAudioURL,
                systemURL: failed.systemAudioURL,
                outputFolder: transcriptedFolder
            )

            print("✅ Retry successful: \(transcriptURL.lastPathComponent)")

            // Remove from failed queue and delete audio files
            await MainActor.run {
                failedTranscriptionManager.deleteFailedTranscription(id: failedId)
            }

            return true

        } catch {
            print("❌ Retry failed: \(error.localizedDescription)")
            return false
        }
    }

    private func handleTaskCompletion(taskId: UUID) {
        // Remove from active tasks
        activeTasks.removeValue(forKey: taskId)
        activeCount -= 1

        print("✓ Task \(taskId) cleaned up (remaining: \(activeCount))")

        // Show completion checkmark if this was the last task
        if activeCount == 0 {
            justCompleted = true

            // Reset flag after animation
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                self.justCompleted = false
            }
        }
    }

    /// Cancel all active transcription tasks
    func cancelAll() {
        for (taskId, task) in activeTasks {
            task.cancel()
            print("🚫 Cancelled task \(taskId)")
        }
        activeTasks.removeAll()
        activeCount = 0
    }

    // MARK: - Action Item Extraction

    /// Extract action items from transcript and present for user review
    private func extractAndSendActionItems(from transcriptURL: URL) async {
        let apiKey = UserDefaults.standard.string(forKey: "geminiAPIKey") ?? ""
        guard !apiKey.isEmpty else {
            print("⚠️ Gemini API key not configured, skipping action item extraction")
            // Show "Transcript saved" status and reset after 10 seconds
            await MainActor.run {
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset()
            }
            return
        }

        // If there are pending items from a previous recording, auto-submit them first
        if let pending = await MainActor.run(body: { self.pendingReview }) {
            print("📋 Auto-submitting \(pending.selectedCount) pending items before showing new review")
            await submitSelectedItemsInternal()
        }

        // Update status to show we're extracting action items
        await MainActor.run {
            self.displayStatus = .extractingActionItems
        }

        do {
            // Read transcript content
            let content = try String(contentsOf: transcriptURL, encoding: .utf8)

            // Extract action items using Gemini
            let result = try await ActionItemExtractor.extract(from: content, apiKey: apiKey)

            // Update transcript with Gemini-generated summary (if available)
            var currentURL = transcriptURL
            if let summary = result.meetingSummary, !summary.isEmpty {
                TranscriptUtils.updateWithSummary(at: currentURL, summary: summary)
            }

            // Rename file with descriptive title (if available)
            if let title = result.meetingTitle, !title.isEmpty {
                currentURL = TranscriptUtils.renameWithTitle(at: currentURL, title: title)
            }

            if result.actionItems.isEmpty {
                print("ℹ️ No action items found in transcript")
                // Show transcript saved since no action items were found
                await MainActor.run {
                    self.displayStatus = .transcriptSaved
                    self.scheduleStatusReset()
                }
                return
            }

            // Store items for user review instead of auto-sending
            await MainActor.run {
                self.pendingReview = PendingActionItemsReview(from: result)
                self.displayStatus = .pendingReview(itemCount: result.actionItems.count)
                // Don't schedule reset - wait for user action
            }
            print("📋 \(result.actionItems.count) action items ready for review")

        } catch {
            print("❌ Action item extraction failed: \(error.localizedDescription)")
            // Still show transcript saved on error
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
            print("✅ Todoist result: \(result.summary)")
        } else {
            // Use Apple Reminders (default)
            let reminders = RemindersService()
            guard await reminders.requestAccess() else {
                print("⚠️ Reminders access denied")
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
                    self.scheduleStatusReset(delay: 15)  // Keep error visible longer
                }
                return
            }
            result = await reminders.createReminders(from: selectedItems)
            print("✅ Reminders result: \(result.summary)")
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
                print("⚠️ \(result.failureCount) tasks failed:")
                for failure in result.failures {
                    print("   - \(failure.taskTitle): \(failure.errorMessage)")
                }
                self.scheduleStatusReset()
            } else if result.allFailed {
                // All tasks failed
                let errorMessage = result.failures.first?.errorMessage ?? "Failed to create tasks"
                self.displayStatus = .failed(message: errorMessage)
                self.scheduleStatusReset(delay: 15)  // Keep error visible longer
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
        print("ℹ️ Action item review skipped")
    }

    /// Schedule reset of displayStatus to .idle after delay
    /// - Parameter delay: Seconds to wait before resetting (default 10s for success, 15s for errors)
    private func scheduleStatusReset(delay: TimeInterval = 10) {
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
                print("✓ Notification permission granted")
            } else if let error = error {
                print("⚠️ Notification permission error: \(error.localizedDescription)")
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
                print("⚠️ Failed to send notification: \(error.localizedDescription)")
            } else {
                print("📢 Failure notification sent")
            }
        }
    }
}

