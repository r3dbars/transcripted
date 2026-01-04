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
            return "Getting ready..."
        case .transcribing:
            return "Transcribing..."
        case .findingActionItems:
            return "Finding action items..."
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

    init(micURL: URL, systemURL: URL?, outputFolder: URL) {
        self.id = UUID()
        self.micURL = micURL
        self.systemURL = systemURL
        self.outputFolder = outputFolder
        self.startTime = Date()
    }
}

@available(macOS 26.0, *)
@MainActor
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

    // PHASE 3 FIX: Deferred items from previous review (merged into next review instead of auto-submitted)
    private var deferredActionItems: [SelectableActionItem] = []

    private var activeTasks: [UUID: Task<Void, Never>] = [:]
    private let transcription = Transcription()

    // Reference to failed transcription manager
    private let failedTranscriptionManager: FailedTranscriptionManager

    // PHASE 6: Failed action item extraction manager with retry queue
    let failedActionItemManager = FailedActionItemManager()

    init(failedTranscriptionManager: FailedTranscriptionManager) {
        self.failedTranscriptionManager = failedTranscriptionManager
    }

    /// Start a new transcription task in the background
    /// Uses enhanced pipeline for AssemblyAI: Transcribe → Identify Speakers → Save with Names → Action Items
    func startTranscription(micURL: URL, systemURL: URL?, outputFolder: URL) {
        let task = TranscriptionTask(micURL: micURL, systemURL: systemURL, outputFolder: outputFolder)

        // Increment active count and set initial status immediately (Goal-Gradient Effect)
        DispatchQueue.main.async {
            self.activeCount += 1
            self.displayStatus = .gettingReady
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
    /// Uses multichannel mode when both mic and system audio are available (preferred - 50% fewer API calls)
    /// - Returns: URL of saved transcript with identified speaker names
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated private func transcribeWithSpeakerIdentification(
        micURL: URL,
        systemURL: URL?,
        outputFolder: URL,
        taskId: UUID
    ) async throws -> URL {

        // Use multichannel mode when both sources available (preferred approach)
        if let systemURL = systemURL {
            return try await transcribeMultichannelPipeline(
                micURL: micURL,
                systemURL: systemURL,
                outputFolder: outputFolder,
                taskId: taskId
            )
        }

        // Fallback: Single source (mic only) - use original pipeline
        return try await transcribeSingleSourcePipeline(
            micURL: micURL,
            outputFolder: outputFolder,
            taskId: taskId
        )
    }

    /// Multichannel pipeline: Merge to stereo → Single API call → Channel-based attribution
    /// Benefits: 50% fewer API calls, perfect sync, channel-based speaker ID
    /// Deepgram bonus: Also gets speaker diarization within the system audio channel!
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated private func transcribeMultichannelPipeline(
        micURL: URL,
        systemURL: URL,
        outputFolder: URL,
        taskId: UUID
    ) async throws -> URL {

        let provider = TranscriptionProvider.current
        print("🔀 Using multichannel pipeline with \(provider.rawValue) (mic + system → stereo)")

        // Phase 1: Transcribe with multichannel mode (provider-agnostic)
        let unifiedResult = try await transcription.transcribeMultichannel(
            micURL: micURL,
            systemURL: systemURL,
            onProgress: { [weak self] progress in
                Task { @MainActor in
                    self?.displayStatus = .transcribing(progress: progress)
                }
            }
        )

        print("✅ Phase 1 complete: Multichannel transcription done")
        print("   • Mic utterances: \(unifiedResult.micUtteranceCount)")
        print("   • System utterances: \(unifiedResult.systemUtteranceCount)")

        // Phase 2: Save transcript based on provider
        await MainActor.run {
            self.displayStatus = .finishing
        }

        let transcriptURL: URL?

        switch unifiedResult {
        case .deepgram(let result):
            // Deepgram: Save with speaker diarization info
            transcriptURL = TranscriptSaver.saveDeepgramMultichannelTranscript(
                result,
                speakerMappings: [:],  // Could add Gemini speaker ID for system speakers here
                directory: outputFolder
            )

        case .assemblyAI(let result):
            // AssemblyAI: Save with channel-based attribution only (no diarization in multichannel)
            transcriptURL = TranscriptSaver.saveMultichannelTranscript(
                result,
                speakerMappings: [:],
                directory: outputFolder
            )
        }

        guard let savedURL = transcriptURL else {
            throw NSError(domain: "Transcription", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Failed to save transcript"
            ])
        }

        print("✅ Phase 2 complete: Transcript saved to \(savedURL.lastPathComponent)")

        // Cleanup audio files
        try? FileManager.default.removeItem(at: micURL)
        try? FileManager.default.removeItem(at: systemURL)

        return savedURL
    }

    /// Single source pipeline: Original approach for mic-only recordings
    /// Note: nonisolated to keep heavy async work off the main thread
    nonisolated private func transcribeSingleSourcePipeline(
        micURL: URL,
        outputFolder: URL,
        taskId: UUID
    ) async throws -> URL {

        print("📝 Using single source pipeline (mic only)")

        // Phase 1: Transcribe and get intermediate result (not saved yet)
        let transcriptionResult = try await transcription.transcribeToIntermediateResult(
            micURL: micURL,
            systemURL: nil,
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
                self.displayStatus = .findingActionItems  // AI processing phase
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
            self.displayStatus = .finishing
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

        return transcriptURL
    }

    /// Retry a failed transcription by its ID
    /// Uses multichannel pipeline when both mic and system audio are available
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
            self.displayStatus = .gettingReady
        }

        // Get output folder (same as original)
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let transcriptedFolder = documentsURL.appendingPathComponent("Transcripted")

        do {
            // Use multichannel pipeline when both sources available (consistent with main flow)
            let transcriptURL = try await transcribeWithSpeakerIdentification(
                micURL: failed.micAudioURL,
                systemURL: failed.systemAudioURL,
                outputFolder: transcriptedFolder,
                taskId: failedId
            )

            print("✅ Retry successful: \(transcriptURL.lastPathComponent)")

            // Remove from failed queue (audio files already cleaned up by pipeline)
            await MainActor.run {
                failedTranscriptionManager.removeFailedTranscription(id: failedId)
                self.displayStatus = .transcriptSaved
                self.scheduleStatusReset()
            }

            return true

        } catch {
            print("❌ Retry failed: \(error.localizedDescription)")
            await MainActor.run {
                self.displayStatus = .failed(message: "Retry failed")
                self.scheduleStatusReset(delay: 15)
            }
            return false
        }
    }

    // MARK: - Retry Failed Action Item Extraction (Phase 6)

    /// Retry a failed action item extraction by its ID
    func retryFailedActionItemExtraction(failedId: UUID) async -> Bool {
        guard let failed = await MainActor.run(body: { failedActionItemManager.failedExtractions.first(where: { $0.id == failedId }) }) else {
            print("❌ Failed action item extraction not found: \(failedId)")
            return false
        }

        // Verify transcript file still exists
        guard failed.transcriptExists() else {
            print("❌ Transcript file no longer exists for failed extraction: \(failedId)")
            await MainActor.run {
                failedActionItemManager.removeFailedExtraction(id: failedId)
            }
            return false
        }

        print("🔄 Retrying action item extraction: \(failed.transcriptFilename)")

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
                print("ℹ️ Retry successful but no action items found")
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

            print("✅ Retry successful: \(result.actionItems.count) action items ready for review")
            return true

        } catch {
            print("❌ Action item extraction retry failed: \(error.localizedDescription)")
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

        print("📋 Retry batch complete: \(succeeded) succeeded, \(failed) failed")
        return (succeeded, failed)
    }

    private func handleTaskCompletion(taskId: UUID) {
        // Remove from active tasks
        activeTasks.removeValue(forKey: taskId)
        activeCount -= 1

        print("✓ Task \(taskId) cleaned up (remaining: \(activeCount))")

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
            print("🚫 Cancelled task \(taskId)")
        }
        activeTasks.removeAll()
        activeCount = 0
    }

    // MARK: - Action Item Extraction

    /// Extract action items from transcript and present for user review
    /// Note: nonisolated to keep heavy async work (Gemini API calls) off the main thread
    nonisolated private func extractAndSendActionItems(from transcriptURL: URL) async {
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

        // PHASE 3 FIX: If there are pending items from a previous recording, defer them
        // to be merged with the next review (instead of auto-submitting without consent)
        if let pending = await MainActor.run(body: { self.pendingReview }) {
            let selectedItems = pending.items.filter { $0.isSelected }
            if !selectedItems.isEmpty {
                await MainActor.run {
                    self.deferredActionItems = selectedItems
                    self.pendingReview = nil
                }
                print("ℹ️ Deferred \(selectedItems.count) selected items to merge with next review")
            } else {
                await MainActor.run {
                    self.pendingReview = nil
                }
                print("ℹ️ Dismissed previous review (no items selected)")
            }
        }

        // Update status to show we're finding action items
        await MainActor.run {
            self.displayStatus = .findingActionItems
        }

        do {
            // Read transcript content
            let content = try String(contentsOf: transcriptURL, encoding: .utf8)

            // Extract action items using Gemini
            let result = try await ActionItemExtractor.extract(from: content, apiKey: apiKey)

            // Update transcript with Gemini-generated summary (if available)
            var currentURL = transcriptURL
            print("📋 Gemini extraction result:")
            print("   • Title: \(result.meetingTitle ?? "nil")")
            if let summary = result.meetingSummary {
                print("   • Summary: \(String(summary.prefix(100)))...")
            } else {
                print("   • Summary: nil")
            }
            print("   • Action items: \(result.actionItems.count)")

            if let summary = result.meetingSummary, !summary.isEmpty {
                TranscriptUtils.updateWithSummary(at: currentURL, summary: summary)
            } else {
                print("⚠️ No summary returned from Gemini")
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
                // Create new selectable items from extraction result
                var allItems = result.actionItems.map { SelectableActionItem(item: $0) }

                // PHASE 3 FIX: Merge any deferred items from previous review (prepend so they appear first)
                let deferredCount = self.deferredActionItems.count
                if deferredCount > 0 {
                    allItems = self.deferredActionItems + allItems
                    self.deferredActionItems = []  // Clear after merging
                    print("📋 Merged \(deferredCount) deferred items into new review")
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
            print("📋 \(result.actionItems.count) action items ready for review")

        } catch {
            print("❌ Action item extraction failed: \(error.localizedDescription)")

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

