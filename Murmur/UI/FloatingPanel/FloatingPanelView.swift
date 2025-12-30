import SwiftUI

// MARK: - SwiftUI View

@available(macOS 26.0, *)
struct FloatingPanelView: View {
    @ObservedObject var taskManager: TranscriptionTaskManager
    @ObservedObject var audio: Audio
    @ObservedObject var pillStateManager: PillStateManager

    @State private var showCompletionCheckmark = false
    @State private var checkmarkScale: CGFloat = 0.7
    @State private var isRecordButtonHovered = false
    @State private var isFileButtonHovered = false

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

    private let panelHeight: CGFloat = 110  // Increased to fit content (was 68)
    private let panelWidth: CGFloat = 200  // Reduced width
    private let baseNotificationHeight: CGFloat = 100  // Base space for celebrations
    private let reviewNotificationHeight: CGFloat = 280  // Expanded height for review UI
    private let totalWindowWidth: CGFloat = 320  // Wide enough for notifications
    private let maxWindowHeight: CGFloat = 390  // Max window size (controller uses this)

    // Dynamic notification height based on review state
    private var notificationHeight: CGFloat {
        taskManager.pendingReview != nil ? reviewNotificationHeight : baseNotificationHeight
    }

    // Dynamic total height for content area (matches controller's window)
    private var totalWindowHeight: CGFloat {
        maxWindowHeight
    }

    // Whether we have pending action items to review
    private var hasPendingReview: Bool {
        taskManager.pendingReview != nil
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
                onTap: { audio.start() },
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

    // MARK: - Full Panel Content (Laws of UX Warm Minimalism) - DEPRECATED

    private var fullPanelContent: some View {
        VStack(spacing: 10) {
            // Status Display Area (Laws of UX card style)
            ZStack {
                RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                    .fill(Color.surfaceCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lawsButton, style: .continuous)
                            .stroke(Color.accentBlue.opacity(0.1), lineWidth: 1)
                    )

                HStack(spacing: 8) {
                    // Left side: Status display with priority logic
                    if audio.isRecording {
                        // Recording indicator dot with glow pulse
                        Circle()
                            .fill(Color.recordingCoral)
                            .frame(width: 8, height: 8)
                            .shadow(color: .recordingCoral.opacity(0.5), radius: 2)
                            .pulse(when: true, minScale: 0.9, maxScale: 1.1)

                        if showSilencePrompt {
                            // Silence warning during recording
                            Text("Silence: \(Int(audio.silenceDuration / 60))m")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(.statusWarningMuted)
                        } else {
                            // Timer display (monospace for retro feel)
                            Text(formatDuration(audio.recordingDuration))
                                .font(.system(size: 14, weight: .bold, design: .monospaced))
                                .foregroundColor(.textOnCream)
                        }
                    } else {
                        // Status display with celebration overlays
                        ZStack {
                            LawsStatusTextView(status: taskManager.displayStatus)

                            // Recording stopped celebration (blue ring)
                            RecordingStoppedCelebration(isVisible: showRecordingStoppedCelebration)
                        }
                    }

                    Spacer()

                    // Right side: Mini waveform only when recording (shows both mic & system audio)
                    if audio.isRecording {
                        WaveformMiniView(
                            levels: Array(audio.audioLevelHistory.suffix(8)),
                            systemLevels: Array(audio.systemAudioLevelHistory.suffix(8)),
                            maxHeight: 20
                        )
                        .frame(height: 20)
                    }
                }
                .padding(.horizontal, 10)
            }
            .frame(height: 28)

            // Controls (Laws of UX style buttons)
            HStack(spacing: 10) {
                LawsButton(
                    iconName: audio.isRecording ? "stop.fill" : "record.circle",
                    label: audio.isRecording ? "Stop" : "Record",
                    color: audio.isRecording ? .textOnCreamSecondary : .recordingCoral,
                    isActive: audio.isRecording
                ) {
                    if audio.isRecording {
                        audio.stop()
                    } else {
                        audio.start()
                    }
                }

                LawsButton(
                    iconName: "folder.fill",
                    label: "Files",
                    color: .accentBlue,
                    isActive: false
                ) {
                    openTranscriptsFolder()
                }
            }
        }
        .padding(12)
    }

    // MARK: - Panel Background (Laws of UX Warm Minimalism)

    private var panelBackground: some View {
        ZStack {
            // Warm cream base with vibrancy
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)

            // Eggshell tint overlay
            Color.surfaceEggshell.opacity(0.85)

            // Recording state: Add red glow border
            if audio.isRecording {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .stroke(Color.recordingCoral.opacity(0.5), lineWidth: 2)
            }

            // Subtle border (Laws of UX style)
            RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                .stroke(Color.accentBlue.opacity(0.15), lineWidth: 1)
        }
        // Laws of UX shadow
        .shadow(
            color: CardStyle.shadowCard.color,
            radius: CardStyle.shadowCard.radius,
            x: CardStyle.shadowCard.x,
            y: CardStyle.shadowCard.y
        )
    }

    // MARK: - Error Overlay (Contextual with recovery actions)

    private var errorOverlay: some View {
        Group {
            if let errorMessage = audio.error {
                let contextualError = ContextualError.from(message: errorMessage)

                VStack {
                    Spacer()
                    ContextualErrorBanner(
                        error: contextualError,
                        onTap: errorTapAction(for: contextualError)
                    )
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            }
        }
    }

    /// Returns the appropriate action for tapping on an error banner
    private func errorTapAction(for error: ContextualError) -> (() -> Void)? {
        switch error {
        case .transcriptionFailed:
            // Could trigger retry - for now, just open settings
            return {
                if let url = URL(string: "x-apple.systempreferences:") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .microphoneError, .permissionDenied:
            // Open System Settings > Privacy > Microphone
            return {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .invalidAPIKey:
            // Could open app settings - for now just dismiss
            return nil
        case .storageFull:
            // Open About This Mac > Storage
            return {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.storagemanagement") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .networkError:
            // Open Network preferences
            return {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.network") {
                    NSWorkspace.shared.open(url)
                }
            }
        case .unknown:
            return nil
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
