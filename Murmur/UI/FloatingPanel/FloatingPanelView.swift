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

    // Transcript tray state
    @State private var showTranscriptTray = false
    @StateObject private var transcriptStore = TranscriptStore()

    // MARK: - Computed Properties

    /// Dynamic frame width based on state
    private var frameWidth: CGFloat {
        if showTranscriptTray {
            return PillDimensions.trayWidth + 40
        } else {
            return PillDimensions.recordingWidth + 40
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Spacer (pushes content to bottom)
            Spacer(minLength: 0)

            // MARK: - Transcript Tray (expands upward when browsing recent meetings)
            if showTranscriptTray && (pillStateManager.state == .idle || pillStateManager.state == .recording) {
                TranscriptTrayView(
                    store: transcriptStore,
                    onOpenFolder: {
                        openTranscriptsFolder()
                        showTranscriptTray = false
                    }
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.95))
                ))
            }

            // MARK: - Toast Notifications (float above pill)
            ZStack {
                Color.clear
                    .frame(height: showTranscriptTray ? 0 : 60)

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
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: showTranscriptTray)
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
        // Dismiss transcript tray when recording starts
        // Dismiss transcript tray when processing starts (but keep it available during recording)
        .onChange(of: pillStateManager.state) { _, newState in
            if newState == .processing {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                    showTranscriptTray = false
                }
            }
        }
        // Refresh transcript list when tray opens
        .onChange(of: showTranscriptTray) { _, isShowing in
            if isShowing { transcriptStore.refresh() }
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
                onRecord: {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                        showTranscriptTray = false
                    }
                    audio.start()
                },
                onTranscripts: { toggleTranscriptTray() },
                failedCount: failedTranscriptionManager.failedTranscriptions.count,
                backgroundTaskCount: taskManager.backgroundTaskCount,
                forceExpanded: showTranscriptTray
            )
        case .recording:
            if useAuroraRecording {
                AuroraRecordingView(audio: audio, onStop: {
                    audio.stop()
                }, onTranscripts: {
                    toggleTranscriptTray()
                })
            } else {
                PillRecordingView(audio: audio) {
                    audio.stop()
                }
            }
        case .processing:
            // Show success view for transcript saved, processing aurora otherwise
            switch taskManager.displayStatus {
            case .transcriptSaved:
                AuroraSuccessView(successType: .transcriptSaved)
            default:
                AuroraProcessingView(status: taskManager.displayStatus)
            }
        }
    }

    // MARK: - Transcript Tray

    private func toggleTranscriptTray() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            showTranscriptTray.toggle()
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
