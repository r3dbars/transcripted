import SwiftUI
import AppKit
import Combine

// MARK: - Window Controller

@available(macOS 26.0, *)
class FloatingPanelController: NSWindowController {
    private var taskManager: TranscriptionTaskManager
    private var audio: Audio
    private var failedTranscriptionManager: FailedTranscriptionManager
    let pillStateManager = PillStateManager()
    private var cancellables = Set<AnyCancellable>()

    // Maximum window dimensions (window stays fixed, content animates within)
    private let maxWindowWidth: CGFloat = PillDimensions.trayWidth + 40  // Extra padding for shadows
    private let maxWindowHeight: CGFloat = PillDimensions.trayMaxHeight + PillDimensions.recordingHeight + 40

    init(taskManager: TranscriptionTaskManager, audio: Audio, failedTranscriptionManager: FailedTranscriptionManager) {
        self.taskManager = taskManager
        self.audio = audio
        self.failedTranscriptionManager = failedTranscriptionManager

        let screen = NSScreen.main ?? NSScreen.screens.first!

        // Calculate position: centered above dock
        let dockHeight = Self.detectDockHeight(for: screen)
        let x = (screen.frame.width - maxWindowWidth) / 2
        let y = dockHeight + PillDimensions.dockPadding

        let initialFrame = NSRect(
            x: x,
            y: y,
            width: maxWindowWidth,
            height: maxWindowHeight
        )

        let window = FloatingPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init(window: window)

        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = false  // Fixed position above dock
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isOpaque = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.hidesOnDeactivate = false  // Stay visible when app loses focus
        window.acceptsMouseMovedEvents = true  // Enable tooltips on hover

        // Create view with pill state manager and failed transcription manager
        let view = FloatingPanelView(
            taskManager: taskManager,
            audio: audio,
            pillStateManager: pillStateManager,
            failedTranscriptionManager: failedTranscriptionManager
        )
        window.contentView = NSHostingView(rootView: view)

        // Wire up pill state transitions based on app events
        setupStateBindings()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not implemented")
    }

    // MARK: - Dock Height Detection

    /// Detect the height of the macOS dock
    private static func detectDockHeight(for screen: NSScreen) -> CGFloat {
        // The dock takes space from visibleFrame
        // Dock can be at bottom, left, or right
        // We detect bottom dock by comparing frame.height vs visibleFrame.height

        let screenFrame = screen.frame
        let visibleFrame = screen.visibleFrame

        // Bottom dock: difference between frame bottom and visible frame bottom
        let bottomDockHeight = visibleFrame.origin.y - screenFrame.origin.y

        // If dock is at bottom and has significant height, use it
        if bottomDockHeight > 20 {
            return bottomDockHeight
        }

        // Dock might be hidden or on sides - use default
        return PillDimensions.defaultDockHeight
    }

    // MARK: - State Bindings

    private func setupStateBindings() {
        // React to recording state changes
        // PHASE 1 FIX: Add debouncing to prevent rapid state changes from causing stuck states
        audio.$isRecording
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isRecording in
                guard let self = self else { return }
                if isRecording {
                    self.pillStateManager.transition(to: .recording)
                } else if self.taskManager.displayStatus.isProcessing {
                    self.pillStateManager.transition(to: .processing)
                } else if !self.pillStateManager.isLocked {
                    self.pillStateManager.transition(to: .idle)
                }
            }
            .store(in: &cancellables)

        // React to task manager status changes
        taskManager.$displayStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .preparing, .transcribing, .extractingActionItems, .saving:
                    if !self.audio.isRecording {
                        self.pillStateManager.transition(to: .processing)
                    }
                case .pendingReview:
                    // IMPORTANT: Transition BEFORE locking - lock() would block the transition
                    self.pillStateManager.transition(to: .reviewing)
                    self.pillStateManager.lock()
                case .completed, .transcriptSaved, .idle:
                    self.pillStateManager.unlock(transitionToIdle: !self.audio.isRecording)
                case .failed:
                    // Play error sound and stay in current state
                    PillSounds.playError()
                    break
                }
            }
            .store(in: &cancellables)
    }

    /// Reposition window if screen changes
    func repositionIfNeeded() {
        guard let window = self.window, let screen = NSScreen.main else { return }

        let dockHeight = Self.detectDockHeight(for: screen)
        let x = (screen.frame.width - maxWindowWidth) / 2
        let y = dockHeight + PillDimensions.dockPadding

        var frame = window.frame
        frame.origin.x = x
        frame.origin.y = y
        window.setFrame(frame, display: true)
    }
}

// MARK: - Floating Panel (NSPanel subclass)

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
