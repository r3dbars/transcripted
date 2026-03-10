import SwiftUI
import AppKit

// MARK: - Tray State (single source of truth for mutually exclusive overlays)

/// Which tray overlay is currently visible above the pill.
/// Transcript tray and speaker naming are mutually exclusive — only one can be shown.
enum TrayState: Equatable {
    case none
    case transcripts
    case speakerNaming
}

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

    // Unified tray state — replaces separate showTranscriptTray / showSpeakerNaming booleans
    @State private var trayState: TrayState = .none
    @StateObject private var transcriptStore = TranscriptStore()

    // Escape key monitors for dismissing tray (need both local + global
    // because the panel has canBecomeKey=false, so the app usually isn't frontmost)
    @State private var escapeLocalMonitor: Any?
    @State private var escapeGlobalMonitor: Any?

    // Constant frame width — prevents position shift when toggling tray
    private let frameWidth: CGFloat = PillDimensions.trayWidth + 40

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - Top Spacer (pushes content to bottom)
            Spacer(minLength: 0)

            // MARK: - Speaker Naming Tray (mutually exclusive with transcript tray)
            if trayState == .speakerNaming, let request = taskManager.speakerNamingRequest {
                SpeakerNamingView(request: request)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.95))
                    ))
            }

            // MARK: - Transcript Tray (expands upward when browsing recent meetings)
            else if trayState == .transcripts && (pillStateManager.state == .idle || pillStateManager.state == .recording) {
                TranscriptTrayView(
                    store: transcriptStore,
                    onOpenFolder: {
                        openTranscriptsFolder()
                        trayState = .none
                    },
                    onDismiss: {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                            trayState = .none
                        }
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
                    .frame(height: trayState == .transcripts ? 0 : 60)

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
        .animation(.spring(response: 0.25, dampingFraction: 0.85), value: trayState)
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
        // Dismiss transcript tray when processing starts (keep available during recording)
        // Note: naming tray is NOT dismissed — it's sticky across pill state changes
        .onChange(of: pillStateManager.state) { _, newState in
            if newState == .processing && trayState == .transcripts {
                withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                    trayState = .none
                }
            }
        }
        // Auto-show naming tray when a naming request arrives; auto-hide when it clears
        .onChange(of: taskManager.speakerNamingRequest != nil) { _, hasRequest in
            if hasRequest {
                if pillStateManager.state == .idle {
                    // Background processing just finished — pill has been idle.
                    // Play completion sound as heads-up, then show naming tray
                    // after a brief delay so it doesn't appear mid-drag.
                    PillSounds.playComplete()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            trayState = .speakerNaming
                        }
                    }
                } else {
                    // Pill is still in processing — show tray immediately
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                        trayState = .speakerNaming
                    }
                }
            } else {
                // Request cleared by handleNamingComplete — dismiss tray
                withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                    trayState = .none
                }
                removeEscapeMonitor()
            }
        }
        // Refresh transcript list when tray opens; manage escape key monitor
        .onChange(of: trayState) { _, newState in
            switch newState {
            case .transcripts:
                transcriptStore.refresh()
                installEscapeMonitor()
            case .speakerNaming:
                installEscapeMonitor()
            case .none:
                removeEscapeMonitor()
            }
        }
        .onDisappear { removeEscapeMonitor() }
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
                        trayState = .none
                    }
                    audio.start()
                },
                onTranscripts: { toggleTranscriptTray() },
                failedCount: failedTranscriptionManager.failedTranscriptions.count,
                backgroundTaskCount: taskManager.backgroundTaskCount,
                forceExpanded: trayState == .transcripts
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
            trayState = trayState == .transcripts ? .none : .transcripts
        }
    }

    // MARK: - Escape Key Monitor

    private func installEscapeMonitor() {
        guard escapeLocalMonitor == nil else { return }

        // Local monitor: catches Escape when our app is frontmost
        // Naming tray is sticky — escape only dismisses the transcript tray
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                if trayState == .speakerNaming {
                    // Naming tray is sticky — escape does nothing but don't swallow the event
                    return event
                }
                guard trayState == .transcripts else { return event }  // Don't swallow escape app-wide
                withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                    trayState = .none
                }
                return nil
            }
            return event
        }

        // Global monitor: catches Escape when another app is frontmost
        // (normal case — our panel has canBecomeKey=false)
        escapeGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                DispatchQueue.main.async {
                    guard self.trayState == .transcripts else { return }
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                        self.trayState = .none
                    }
                }
            }
        }
    }

    private func removeEscapeMonitor() {
        if let monitor = escapeLocalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeLocalMonitor = nil
        }
        if let monitor = escapeGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            escapeGlobalMonitor = nil
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
