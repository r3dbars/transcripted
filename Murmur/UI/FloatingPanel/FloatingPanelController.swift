import SwiftUI
import AppKit
import Combine

// MARK: - Window Controller

@available(macOS 26.0, *)
class FloatingPanelController: NSWindowController, NSWindowDelegate {
    private var taskManager: TranscriptionTaskManager
    private var audio: Audio
    private var failedTranscriptionManager: FailedTranscriptionManager
    let pillStateManager = PillStateManager()
    private var cancellables = Set<AnyCancellable>()

    // Position persistence keys
    private static let savedPositionXKey = "floatingPanelX"
    private static let savedPositionYKey = "floatingPanelY"

    // Maximum window dimensions (window stays fixed, content animates within)
    private let maxWindowWidth: CGFloat = PillDimensions.trayWidth + 40  // Extra padding for shadows
    private let maxWindowHeight: CGFloat = PillDimensions.trayMaxHeight + PillDimensions.recordingHeight + 40

    init(taskManager: TranscriptionTaskManager, audio: Audio, failedTranscriptionManager: FailedTranscriptionManager) {
        self.taskManager = taskManager
        self.audio = audio
        self.failedTranscriptionManager = failedTranscriptionManager

        let screen = NSScreen.main ?? NSScreen.screens.first!

        // Calculate position: use saved position if valid, otherwise center above dock
        let dockHeight = Self.detectDockHeight(for: screen)
        let x: CGFloat
        let y: CGFloat

        if let savedX = UserDefaults.standard.object(forKey: Self.savedPositionXKey) as? CGFloat,
           let savedY = UserDefaults.standard.object(forKey: Self.savedPositionYKey) as? CGFloat,
           Self.isOnScreen(x: savedX, y: savedY) {
            x = savedX
            y = savedY
        } else {
            x = (screen.frame.width - maxWindowWidth) / 2
            y = dockHeight + PillDimensions.dockPadding
        }

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
        window.isMovableByWindowBackground = true  // Allow dragging by clicking background
        window.delegate = self  // For position persistence
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
        // MVP: Pill returns to idle quickly so user can start a new recording
        // while previous transcription processes in background
        taskManager.$displayStatus
            .receive(on: DispatchQueue.main)
            .sink { [weak self] status in
                guard let self = self else { return }
                switch status {
                case .gettingReady:
                    // Brief processing flash, then return to idle so user can record again
                    if !self.audio.isRecording {
                        self.pillStateManager.transition(to: .processing)
                        self.scheduleReturnToIdle(delay: 1.5)
                    }
                case .transcribing, .findingActionItems, .finishing:
                    // Don't re-enter processing — pill should already be idle (or heading there)
                    // Background transcription continues silently
                    break
                case .pendingReview:
                    // Don't interrupt an active recording with a review from a background task
                    guard !self.audio.isRecording else { break }
                    // IMPORTANT: Transition BEFORE locking - lock() would block the transition
                    self.pillStateManager.transition(to: .reviewing)
                    self.pillStateManager.lock()
                case .completed, .transcriptSaved:
                    // Don't interrupt an active recording with success from a background task
                    guard !self.audio.isRecording else { break }
                    // Show success briefly in pill, then return to idle
                    self.pillStateManager.unlock(transitionToIdle: false)
                    if self.pillStateManager.state != .processing {
                        self.pillStateManager.transition(to: .processing)
                    }
                    // Quick return to idle after success animation
                    self.scheduleReturnToIdle(delay: 2.5)
                case .idle:
                    // Now transition to idle (triggered by scheduleStatusReset timer)
                    self.pillStateManager.unlock(transitionToIdle: !self.audio.isRecording)
                case .failed:
                    // Show error briefly in processing state, then return to idle
                    PillSounds.playError()
                    if !self.audio.isRecording {
                        self.pillStateManager.transition(to: .processing)
                        self.scheduleReturnToIdle(delay: 4.0)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Background Processing Quick Return

    /// Schedule a quick return to idle so user can start recording again
    /// The pill shows processing/success briefly, then morphs back to idle
    private func scheduleReturnToIdle(delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            // Only return to idle if not recording and not locked (reviewing)
            guard !self.audio.isRecording, !self.pillStateManager.isLocked else { return }
            self.pillStateManager.transition(to: .idle)
        }
    }

    /// Reposition window if screen changes (only if no saved position)
    func repositionIfNeeded() {
        guard let window = self.window, let screen = NSScreen.main else { return }

        // Only reposition if no saved position exists
        if UserDefaults.standard.object(forKey: Self.savedPositionXKey) != nil {
            return
        }

        let dockHeight = Self.detectDockHeight(for: screen)
        let x = (screen.frame.width - maxWindowWidth) / 2
        let y = dockHeight + PillDimensions.dockPadding

        var frame = window.frame
        frame.origin.x = x
        frame.origin.y = y
        window.setFrame(frame, display: true)
    }

    // MARK: - Position Persistence

    /// Check if a position is visible on any connected screen
    private static func isOnScreen(x: CGFloat, y: CGFloat) -> Bool {
        let point = NSPoint(x: x, y: y)
        return NSScreen.screens.contains { $0.frame.contains(point) }
    }

    // MARK: - NSWindowDelegate

    func windowDidMove(_ notification: Notification) {
        guard let window = self.window else { return }
        UserDefaults.standard.set(window.frame.origin.x, forKey: Self.savedPositionXKey)
        UserDefaults.standard.set(window.frame.origin.y, forKey: Self.savedPositionYKey)
    }
}

// MARK: - Floating Panel (NSPanel subclass)

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
