import SwiftUI

// MARK: - SwiftUI View

// MARK: - Celebration State (consolidated)

/// Single enum for all celebration overlays - prevents state explosion
enum CelebrationState: Equatable {
    case none
    case transcriptSaved
    case actionItemsCreated(count: Int)
}

@available(macOS 26.0, *)
struct FloatingPanelView: View {
    @ObservedObject var taskManager: TranscriptionTaskManager
    @ObservedObject var audio: Audio
    @ObservedObject var pillStateManager: PillStateManager
    @ObservedObject var failedTranscriptionManager: FailedTranscriptionManager

    // Consolidated celebration state (replaces 3 separate @State vars)
    @State private var celebrationState: CelebrationState = .none

    // Toast notification state
    @State private var showErrorToast = false
    @State private var currentError: ContextualError?

    // Attention prompt states
    @State private var showSilencePrompt = false
    @State private var silencePromptDismissed = false  // Prevents re-showing after dismiss
    private let silenceThresholdSeconds: TimeInterval = 120  // 2 minutes

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Spacer (pushes content to bottom)
            Spacer(minLength: 0)

            // MARK: - Review Tray (expands upward when reviewing)
            if pillStateManager.state == .reviewing {
                ReviewTrayView(taskManager: taskManager)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
            }

            // MARK: - Celebration Overlays & Toast (float above pill)
            ZStack {
                Color.clear
                    .frame(height: 60)

                // Single celebration overlay based on consolidated state
                if celebrationState != .none && pillStateManager.state != .reviewing {
                    celebrationOverlay
                        .transition(.scale.combined(with: .opacity))
                }

                // Toast notification for errors (appears above pill, auto-dismisses)
                if showErrorToast, let error = currentError {
                    ToastNotificationView(error: error, isVisible: $showErrorToast)
                        .transition(.asymmetric(
                            insertion: .move(edge: .bottom).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            }

            // MARK: - Pill Content (centered, morphs between states)
            pillContent
                .animation(.pillMorph, value: pillStateManager.state)
                .padding(.bottom, 10)
        }
        .frame(width: pillStateManager.state == .reviewing ? PillDimensions.trayWidth + 40 : PillDimensions.recordingWidth + 40)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onChange(of: audio.silenceDuration) { _, duration in
            // UX: Don't interrupt user flow - show amber ring indicator without forcing panel expansion
            if audio.isRecording && duration >= silenceThresholdSeconds && !silencePromptDismissed && !showSilencePrompt {
                showSilencePrompt = true
            }
        }
        .onChange(of: audio.isRecording) { _, isRecording in
            if !isRecording {
                showSilencePrompt = false
                silencePromptDismissed = false
            }
        }
        // Trigger celebrations and toasts based on displayStatus changes
        .onChange(of: taskManager.displayStatus) { _, newStatus in
            switch newStatus {
            case .transcriptSaved:
                triggerCelebration(.transcriptSaved, duration: 2.0)
            case .completed(let count):
                triggerCelebration(.actionItemsCreated(count: count), duration: 3.0)
            case .failed(let message):
                triggerErrorToast(message: message)
            default:
                break
            }
        }
        // Clear celebrations immediately when pill state changes
        .onChange(of: pillStateManager.state) { _, _ in
            celebrationState = .none
        }
    }

    // MARK: - Celebration

    /// Computed overlay view based on current celebration state
    @ViewBuilder
    private var celebrationOverlay: some View {
        switch celebrationState {
        case .none:
            EmptyView()
        case .transcriptSaved:
            CelebrationOverlay(celebrationType: .transcriptSaved, isVisible: true)
        case .actionItemsCreated(let count):
            CelebrationOverlay(celebrationType: .actionItemsCreated(count: count), isVisible: true)
        }
    }

    /// Unified celebration trigger - shows overlay then auto-dismisses
    private func triggerCelebration(_ state: CelebrationState, duration: TimeInterval) {
        celebrationState = state
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            if celebrationState == state {  // Only clear if still showing same celebration
                celebrationState = .none
            }
        }
    }

    /// Trigger error toast notification - parses message into contextual error
    private func triggerErrorToast(message: String) {
        // Parse the error message to determine type and recovery hint
        currentError = ContextualError.from(message: message)
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            showErrorToast = true
        }
    }

    // MARK: - Pill Content (Dynamic Island-style state switching)

    /// Switches between pill views based on current state
    @ViewBuilder
    private var pillContent: some View {
        switch pillStateManager.state {
        case .idle:
            PillIdleView(
                onRecord: { audio.start() },
                onFiles: { openTranscriptsFolder() },
                failedCount: failedTranscriptionManager.failedTranscriptions.count
            )
        case .recording:
            PillRecordingView(audio: audio) {
                audio.stop()
            }
        case .processing:
            PillProcessingView(status: taskManager.displayStatus)
        case .reviewing:
            PillReviewingView(itemCount: taskManager.pendingReview?.totalCount ?? 0)
        }
    }

    // MARK: - Helper Functions

    private func openTranscriptsFolder() {
        let transcriptsFolder: URL
        if let customPath = UserDefaults.standard.string(forKey: "transcriptSaveLocation"),
           !customPath.isEmpty {
            transcriptsFolder = URL(fileURLWithPath: customPath)
        } else {
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            transcriptsFolder = documentsPath.appendingPathComponent("Transcripted")
        }
        try? FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(transcriptsFolder)
    }
}
