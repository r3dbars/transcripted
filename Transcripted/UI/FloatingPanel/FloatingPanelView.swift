import SwiftUI
import AppKit
import TranscriptedCore

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

    // Accessibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Toast notification state
    @State private var showErrorToast = false
    @State private var currentError: ContextualError?

    // Speaker naming dismiss guard — tracks when naming tray appeared
    @State private var speakerNamingAppearDate: Date?
    private var canDismissSpeakerNaming: Bool {
        guard let appeared = speakerNamingAppearDate else { return false }
        return Date().timeIntervalSince(appeared) >= 3.0
    }

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
    @State private var clickOutsideMonitor: Any?

    // Constant frame width — prevents position shift when toggling tray
    private let frameWidth: CGFloat = PillDimensions.trayWidth + 40

    var body: some View {
        mainStack
            .frame(width: frameWidth)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .animation(.spring(response: 0.25, dampingFraction: 0.85), value: trayState)
            .modifier(eventHandlers)
    }

    // MARK: - Event Handlers (extracted to avoid compiler type-check timeout)

    private var eventHandlers: some ViewModifier {
        FloatingPanelEventHandlers(
            audio: audio,
            taskManager: taskManager,
            pillStateManager: pillStateManager,
            silenceThresholdSeconds: silenceThresholdSeconds,
            showSilencePrompt: $showSilencePrompt,
            silencePromptDismissed: $silencePromptDismissed,
            trayState: $trayState,
            transcriptStore: transcriptStore,
            speakerNamingAppearDate: $speakerNamingAppearDate,
            clickOutsideMonitor: $clickOutsideMonitor,
            installEscapeMonitor: installEscapeMonitor,
            removeEscapeMonitor: removeEscapeMonitor,
            triggerErrorToast: triggerErrorToast
        )
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

    // MARK: - Main Stack (body broken up for type-checker)

    @ViewBuilder
    private var mainStack: some View {
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
                    },
                    onRecord: {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                            trayState = .none
                        }
                        audio.start()
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
                    .frame(height: trayState != .none ? 0 : 60)

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
                .contextMenu {
                    pillContextMenu
                }
                .animation(.pillMorph, value: pillStateManager.state)
                .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var pillContextMenu: some View {
        if pillStateManager.state == .recording {
            Button(action: { audio.stop() }) {
                Label("Stop Recording", systemImage: "stop.fill")
            }
        } else if pillStateManager.state == .idle {
            Button(action: { audio.start() }) {
                Label("Start Recording", systemImage: "mic.fill")
            }
        }

        Button(action: { toggleTranscriptTray() }) {
            Label("View Transcripts", systemImage: "clock.arrow.circlepath")
        }

        Button(action: { openTranscriptsFolder() }) {
            Label("Open Transcripts Folder", systemImage: "folder")
        }

        if failedTranscriptionManager.failedTranscriptions.count > 0 {
            Button(action: { toggleTranscriptTray() }) {
                Label("Failed Transcriptions (\(failedTranscriptionManager.failedTranscriptions.count))", systemImage: "exclamationmark.triangle")
            }
        }

        Divider()

        Button(action: {
            NSApp.sendAction(Selector(("openSettings")), to: nil, from: nil)
        }) {
            Label("Settings...", systemImage: "gear")
        }

        Divider()

        Button(action: {
            NSApplication.shared.terminate(nil)
        }) {
            Label("Quit Transcripted", systemImage: "power")
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
                forceExpanded: trayState != .none,
                showOnboardingGlow: pillStateManager.showOnboardingGlow
            )
        case .recording:
            AuroraRecordingView(audio: audio, onStop: {
                audio.stop()
            }, onTranscripts: {
                toggleTranscriptTray()
            })
        case .processing:
            AuroraProcessingView(status: taskManager.displayStatus)
        case .saved:
            SavedPillView(
                title: taskManager.lastSavedTitle,
                duration: taskManager.lastSavedDuration,
                speakerCount: taskManager.lastSavedSpeakerCount,
                transcriptURL: taskManager.lastSavedTranscriptURL,
                onCopyTranscript: {
                    guard let url = taskManager.lastSavedTranscriptURL else { return }
                    let summary = TranscriptSummary(
                        url: url,
                        title: url.deletingPathExtension().lastPathComponent,
                        date: Date(),
                        duration: "",
                        speakerCount: 0,
                        speakerNames: [],
                        timeOfDay: nil,
                        speakers: []
                    )
                    if let text = transcriptStore.copyableText(for: summary), !text.isEmpty {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                },
                onOpenTranscript: {
                    // Dismiss saved card, go to idle, and open transcript tray
                    pillStateManager.transition(to: .idle)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            trayState = .transcripts
                        }
                    }
                },
                onDismiss: {
                    pillStateManager.transition(to: .idle)
                }
            )
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
        escapeLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                if trayState == .speakerNaming {
                    // Allow escape dismiss after 3-second guard
                    guard canDismissSpeakerNaming else { return event }
                    if let request = taskManager.speakerNamingRequest {
                        request.onComplete([])
                    }
                    return nil
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
                    if self.trayState == .speakerNaming {
                        guard self.canDismissSpeakerNaming else { return }
                        if let request = self.taskManager.speakerNamingRequest {
                            request.onComplete([])
                        }
                    } else if self.trayState == .transcripts {
                        withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                            self.trayState = .none
                        }
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
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }

    // MARK: - Helper Functions

    private func openTranscriptsFolder() {
        let transcriptsFolder = TranscriptSaver.defaultSaveDirectory
        try? FileManager.default.createDirectory(at: transcriptsFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(transcriptsFolder)
    }
}

// MARK: - Event Handlers Modifier
//
// Extracted into its own ViewModifier because FloatingPanelView.body accumulated
// enough chained `.onChange` modifiers that the Swift 5.9 type checker hit its
// "unable to type-check in reasonable time" limit after the TranscriptedCore
// extraction (types now cross a module boundary, which inflates inference cost).
// Splitting the handler chain into a separate modifier gives the type checker a
// much smaller subproblem to solve and keeps compile times reasonable.

@available(macOS 26.0, *)
private struct FloatingPanelEventHandlers: ViewModifier {
    @ObservedObject var audio: Audio
    @ObservedObject var taskManager: TranscriptionTaskManager
    @ObservedObject var pillStateManager: PillStateManager

    let silenceThresholdSeconds: TimeInterval
    @Binding var showSilencePrompt: Bool
    @Binding var silencePromptDismissed: Bool
    @Binding var trayState: TrayState
    @ObservedObject var transcriptStore: TranscriptStore
    @Binding var speakerNamingAppearDate: Date?
    @Binding var clickOutsideMonitor: Any?

    let installEscapeMonitor: () -> Void
    let removeEscapeMonitor: () -> Void
    let triggerErrorToast: (String) -> Void

    func body(content: Content) -> some View {
        content
            .modifier(FloatingPanelSilenceHandlers(
                audio: audio,
                silenceThresholdSeconds: silenceThresholdSeconds,
                showSilencePrompt: $showSilencePrompt,
                silencePromptDismissed: $silencePromptDismissed
            ))
            .modifier(FloatingPanelTrayHandlers(
                audio: audio,
                taskManager: taskManager,
                pillStateManager: pillStateManager,
                trayState: $trayState,
                transcriptStore: transcriptStore,
                speakerNamingAppearDate: $speakerNamingAppearDate,
                clickOutsideMonitor: $clickOutsideMonitor,
                installEscapeMonitor: installEscapeMonitor,
                removeEscapeMonitor: removeEscapeMonitor
            ))
            .modifier(FloatingPanelErrorHandlers(
                audio: audio,
                taskManager: taskManager,
                removeEscapeMonitor: removeEscapeMonitor,
                triggerErrorToast: triggerErrorToast
            ))
    }
}

@available(macOS 26.0, *)
private struct FloatingPanelSilenceHandlers: ViewModifier {
    @ObservedObject var audio: Audio
    let silenceThresholdSeconds: TimeInterval
    @Binding var showSilencePrompt: Bool
    @Binding var silencePromptDismissed: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: audio.silenceDuration) { _, duration in
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
    }
}

@available(macOS 26.0, *)
private struct FloatingPanelTrayHandlers: ViewModifier {
    @ObservedObject var audio: Audio
    @ObservedObject var taskManager: TranscriptionTaskManager
    @ObservedObject var pillStateManager: PillStateManager
    @Binding var trayState: TrayState
    @ObservedObject var transcriptStore: TranscriptStore
    @Binding var speakerNamingAppearDate: Date?
    @Binding var clickOutsideMonitor: Any?
    let installEscapeMonitor: () -> Void
    let removeEscapeMonitor: () -> Void

    func body(content: Content) -> some View {
        content
            .onChange(of: pillStateManager.state) { _, newState in
                if newState == .processing && trayState == .transcripts {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                        trayState = .none
                    }
                }
            }
            .onChange(of: taskManager.speakerNamingRequest != nil) { _, hasRequest in
                if hasRequest {
                    if pillStateManager.state == .idle {
                        PillSounds.playComplete()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                                trayState = .speakerNaming
                            }
                        }
                    } else {
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
                            trayState = .speakerNaming
                        }
                    }
                } else {
                    withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                        trayState = .none
                    }
                    removeEscapeMonitor()
                }
            }
            .onChange(of: trayState) { _, newState in
                switch newState {
                case .transcripts:
                    transcriptStore.refresh()
                    installEscapeMonitor()
                    if clickOutsideMonitor == nil {
                        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
                            DispatchQueue.main.async {
                                guard trayState == .transcripts else { return }
                                withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                                    trayState = .none
                                }
                            }
                        }
                    }
                case .speakerNaming:
                    speakerNamingAppearDate = Date()
                    installEscapeMonitor()
                case .none:
                    speakerNamingAppearDate = nil
                    removeEscapeMonitor()
                }
            }
    }
}

@available(macOS 26.0, *)
private struct FloatingPanelErrorHandlers: ViewModifier {
    @ObservedObject var audio: Audio
    @ObservedObject var taskManager: TranscriptionTaskManager
    let removeEscapeMonitor: () -> Void
    let triggerErrorToast: (String) -> Void

    func body(content: Content) -> some View {
        content
            .onDisappear { removeEscapeMonitor() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { notification in
                guard let window = notification.object as? NSPanel,
                      window.level == .floating else { return }
                removeEscapeMonitor()
            }
            .onChange(of: taskManager.displayStatus) { _, newStatus in
                Task { @MainActor in
                    if case .failed(let message) = newStatus {
                        triggerErrorToast(message)
                    }
                }
            }
            .onChange(of: audio.error) { _, newError in
                if let message = newError {
                    triggerErrorToast(message)
                    audio.error = nil
                }
            }
    }
}
