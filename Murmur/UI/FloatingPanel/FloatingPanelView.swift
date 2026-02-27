import SwiftUI

// MARK: - SwiftUI View

@available(macOS 26.0, *)
struct FloatingPanelView: View {
    @ObservedObject var taskManager: TranscriptionTaskManager
    @ObservedObject var audio: Audio
    @ObservedObject var pillStateManager: PillStateManager
    @ObservedObject var failedTranscriptionManager: FailedTranscriptionManager

    // User preference for aurora recording indicator
    @AppStorage("useAuroraRecording") private var useAuroraRecording: Bool = false

    // Accessibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Toast notification state
    @State private var showErrorToast = false
    @State private var currentError: ContextualError?

    // Attention prompt states
    @State private var showSilencePrompt = false
    @State private var silencePromptDismissed = false  // Prevents re-showing after dismiss
    private let silenceThresholdSeconds: TimeInterval = 120  // 2 minutes

    // MARK: - Computed Properties

    /// Dynamic frame width based on state
    private var frameWidth: CGFloat {
        if pillStateManager.state == .reviewing {
            return PillDimensions.trayWidth + 40
        } else {
            return PillDimensions.recordingWidth + 40
        }
    }

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

            // MARK: - Toast Notifications (float above pill)
            ZStack {
                Color.clear
                    .frame(height: pillStateManager.state == .reviewing ? 0 : 60)

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
        .frame(width: frameWidth)
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
        // Trigger error toasts based on displayStatus changes
        // (Success is now shown in-pill via AuroraSuccessView, not as overlay)
        // Note: Use Task to debounce rapid status changes and prevent
        // "action tried to update multiple times per frame" warning
        .onChange(of: taskManager.displayStatus) { _, newStatus in
            Task { @MainActor in
                if case .failed(let message) = newStatus {
                    triggerErrorToast(message: message)
                }
            }
        }
    }

    // MARK: - Error Toast

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
            AuroraIdleView(
                onRecord: { audio.start() },
                onFiles: { openTranscriptsFolder() },
                failedCount: failedTranscriptionManager.failedTranscriptions.count
            )
        case .recording:
            if useAuroraRecording {
                AuroraRecordingView(audio: audio) {
                    audio.stop()
                }
            } else {
                PillRecordingView(audio: audio) {
                    audio.stop()
                }
            }
        case .processing:
            // Show success view for success states, processing aurora otherwise
            switch taskManager.displayStatus {
            case .transcriptSaved:
                AuroraSuccessView(successType: .transcriptSaved)
            case .completed(let count):
                AuroraSuccessView(successType: .tasksAdded(count: count))
            default:
                AuroraProcessingView(status: taskManager.displayStatus)
            }
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
