import SwiftUI

// MARK: - SwiftUI View

@available(macOS 26.0, *)
struct FloatingPanelView: View {
    @ObservedObject var taskManager: TranscriptionTaskManager
    @ObservedObject var audio: Audio
    @ObservedObject var pillStateManager: PillStateManager

    @State private var showCompletionCheckmark = false
    @State private var checkmarkScale: CGFloat = 0.7

    // Success celebration states (Peak-End Rule)
    @State private var showRecordingStoppedCelebration = false
    @State private var showTranscriptSavedCelebration = false
    @State private var showActionItemsCelebration = false
    @State private var actionItemsCount: Int = 0
    @State private var previousRecordingState = false

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

            // MARK: - Celebration Overlays (float above pill)
            ZStack {
                Color.clear
                    .frame(height: 60)

                // Transcript saved celebration
                if showTranscriptSavedCelebration && pillStateManager.state != .reviewing {
                    CelebrationOverlay(
                        celebrationType: .transcriptSaved,
                        isVisible: showTranscriptSavedCelebration
                    )
                    .transition(.scale.combined(with: .opacity))
                }

                // Action items celebration
                if showActionItemsCelebration && pillStateManager.state != .reviewing {
                    CelebrationOverlay(
                        celebrationType: .actionItemsCreated(count: actionItemsCount),
                        isVisible: showActionItemsCelebration
                    )
                    .transition(.scale.combined(with: .opacity))
                }
            }

            // MARK: - Pill Content (centered, morphs between states)
            pillContent
                .animation(.pillMorph, value: pillStateManager.state)
                .padding(.bottom, 10)
        }
        .frame(width: pillStateManager.state == .reviewing ? PillDimensions.trayWidth + 40 : PillDimensions.recordingWidth + 40)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .onChange(of: taskManager.justCompleted) { _, newValue in
            if newValue {
                triggerCompletionCheckmark()
            }
        }
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

                // Trigger recording stopped celebration when recording ends
                if previousRecordingState {
                    triggerRecordingStoppedCelebration()
                }
            }
            previousRecordingState = isRecording
        }
        // Trigger celebrations based on displayStatus changes
        .onChange(of: taskManager.displayStatus) { _, newStatus in
            switch newStatus {
            case .transcriptSaved:
                triggerTranscriptSavedCelebration()
            case .completed(let count):
                triggerActionItemsCelebration(count: count)
            default:
                break
            }
        }
        // PHASE 4 FIX: Clear celebrations immediately when state changes
        // Prevents lingering overlays from previous states
        .onChange(of: pillStateManager.state) { _, _ in
            showRecordingStoppedCelebration = false
            showTranscriptSavedCelebration = false
            showActionItemsCelebration = false
        }
    }

    // MARK: - Celebration Triggers

    private func triggerRecordingStoppedCelebration() {
        showRecordingStoppedCelebration = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            showRecordingStoppedCelebration = false
        }
    }

    private func triggerTranscriptSavedCelebration() {
        showTranscriptSavedCelebration = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            showTranscriptSavedCelebration = false
        }
    }

    private func triggerActionItemsCelebration(count: Int) {
        actionItemsCount = count
        showActionItemsCelebration = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            showActionItemsCelebration = false
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
                failedCount: 0  // TODO: Wire to FailedTranscriptionManager
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

    private func formatDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func triggerCompletionCheckmark() {
        checkmarkScale = 0.0
        showCompletionCheckmark = true

        withAnimation(.spring(response: 0.7, dampingFraction: 0.5, blendDuration: 0)) {
            checkmarkScale = 0.9
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.easeOut(duration: 0.3)) {
                showCompletionCheckmark = false
                checkmarkScale = 0.7
            }
        }
    }
}
