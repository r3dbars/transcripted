// MeetingOverlayController.swift
// Second non-activating NSPanel for meeting-mode recording/transcription status.
// Separate from FloatingOverlayController (draft/dictation) by design — the
// meeting panel has its own lifecycle, state machine, and visual language.
// See merge-plan.md §5.3.
//
// Pure AppKit: NSPanel + NSView subclasses + Combine subscriptions on the
// controller only. Views are dumb renderers with `update()` methods — no
// @Published observation from views, no SwiftUI, no NSHostingView.

import AppKit
import Combine
import TranscriptedCore

// MARK: - Panel

/// Non-activating NSPanel for the meeting overlay. Distinct from
/// `FloatingOverlayPanel` so cross-feature regressions to one don't break the
/// other.
@available(macOS 14.0, *)
final class MeetingOverlayPanel: NSPanel {
    override init(
        contentRect: NSRect,
        styleMask style: NSWindow.StyleMask,
        backing backingStoreType: NSWindow.BackingStoreType,
        defer flag: Bool
    ) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .borderless],
            backing: .buffered,
            defer: true
        )
        self.level = .popUpMenu
        self.isFloatingPanel = true
        self.becomesKeyOnlyIfNeeded = true
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isMovableByWindowBackground = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    }

    // Never steals keyboard focus — meeting UI is read-only status.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

// MARK: - Root View

/// Single horizontal pill-style view for the meeting overlay. Shows a record
/// indicator, state title, elapsed timer, audio level bar, and (when known) a
/// participant list.
///
/// Pure AppKit — no observers, no bindings. `update(...)` is called explicitly
/// by `MeetingOverlayController` in response to Combine events.
@available(macOS 14.0, *)
@MainActor
final class MeetingOverlayRootView: NSView {
    private let statusDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "Meeting")
    private let timerLabel = NSTextField(labelWithString: "00:00")
    private let levelBar = NSView()
    private let levelFill = NSView()
    private let participantsLabel = NSTextField(labelWithString: "")
    private let closeButton = NSButton()

    /// Invoked when the user clicks the close/stop button.
    var onClose: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = MeetingOverlayTokens.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = MeetingOverlayTokens.panelBg.cgColor

        // Record status dot (red during recording, orange while prep/transcribe, grey idle).
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MeetingOverlayTokens.dotSize / 2
        statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotIdle.cgColor
        addSubview(statusDot)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = MeetingOverlayTokens.textPrimary
        addSubview(titleLabel)

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        timerLabel.textColor = MeetingOverlayTokens.textSecondary
        addSubview(timerLabel)

        // Audio level container + fill.
        levelBar.wantsLayer = true
        levelBar.layer?.cornerRadius = 2
        levelBar.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        addSubview(levelBar)

        levelFill.wantsLayer = true
        levelFill.layer?.cornerRadius = 2
        levelFill.layer?.backgroundColor = MeetingOverlayTokens.accentRed.cgColor
        levelBar.addSubview(levelFill)

        participantsLabel.font = NSFont.systemFont(ofSize: 11)
        participantsLabel.textColor = MeetingOverlayTokens.textSecondary
        participantsLabel.lineBreakMode = .byTruncatingTail
        addSubview(participantsLabel)

        // Close/stop button — square X at the right edge.
        if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop meeting") {
            closeButton.image = img
            closeButton.contentTintColor = MeetingOverlayTokens.textSecondary
        }
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let dotSize = MeetingOverlayTokens.dotSize

        statusDot.frame = NSRect(
            x: pad,
            y: (bounds.height - dotSize) / 2,
            width: dotSize,
            height: dotSize
        )

        let titleX = statusDot.frame.maxX + 8
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(
            x: titleX,
            y: (bounds.height - titleSize.height) / 2,
            width: min(titleSize.width, 140),
            height: titleSize.height
        )

        let timerSize = timerLabel.fittingSize
        let timerX = titleLabel.frame.maxX + 8
        timerLabel.frame = NSRect(
            x: timerX,
            y: (bounds.height - timerSize.height) / 2,
            width: timerSize.width,
            height: timerSize.height
        )

        // Close button on the right.
        let closeSize: CGFloat = 18
        closeButton.frame = NSRect(
            x: bounds.width - pad - closeSize,
            y: (bounds.height - closeSize) / 2,
            width: closeSize,
            height: closeSize
        )

        // Level bar occupies the space between timer and close button, minus a
        // participants strip below.
        let levelBarX = timerLabel.frame.maxX + 12
        let levelBarRight = closeButton.frame.minX - 8
        let levelBarWidth = max(0, levelBarRight - levelBarX)
        let levelBarHeight: CGFloat = 4
        levelBar.frame = NSRect(
            x: levelBarX,
            y: bounds.height / 2 + 2,
            width: levelBarWidth,
            height: levelBarHeight
        )

        // Participants label sits beneath the level bar, same horizontal span.
        let participantsHeight: CGFloat = 14
        participantsLabel.frame = NSRect(
            x: levelBarX,
            y: bounds.height / 2 - participantsHeight - 2,
            width: levelBarWidth,
            height: participantsHeight
        )

        // Fill width reflects latest audio level.
        let fillWidth = levelBar.bounds.width * CGFloat(currentLevel)
        levelFill.frame = NSRect(x: 0, y: 0, width: fillWidth, height: levelBar.bounds.height)
    }

    // MARK: - Update API

    private var currentLevel: Float = 0

    func update(
        state: MeetingOverlayController.OverlayState,
        duration: TimeInterval,
        audioLevel: Float,
        participants: [String]
    ) {
        switch state {
        case .idle:
            titleLabel.stringValue = "Meeting"
            statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotIdle.cgColor
        case .preparing:
            titleLabel.stringValue = "Loading models…"
            statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotPrep.cgColor
        case .recording:
            titleLabel.stringValue = "Recording meeting"
            statusDot.layer?.backgroundColor = MeetingOverlayTokens.accentRed.cgColor
        case .transcribing:
            titleLabel.stringValue = "Transcribing…"
            statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotPrep.cgColor
        case .saved:
            titleLabel.stringValue = "Saved"
            statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotSaved.cgColor
        case .error(let message):
            titleLabel.stringValue = message.isEmpty ? "Error" : message
            statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotError.cgColor
        }

        timerLabel.stringValue = formatDuration(duration)
        currentLevel = max(0, min(1, audioLevel))

        if participants.isEmpty {
            participantsLabel.stringValue = ""
        } else {
            participantsLabel.stringValue = participants.joined(separator: ", ")
        }

        needsLayout = true
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    @objc private func handleClose() {
        onClose?()
    }
}

// MARK: - Design tokens (local — keeps the meeting overlay visually distinct
// from the draft overlay without polluting OverlayTokens).

@available(macOS 14.0, *)
enum MeetingOverlayTokens {
    static let panelBg       = NSColor.black.withAlphaComponent(0.78)
    static let accentRed     = NSColor(red: 0.95, green: 0.22, blue: 0.22, alpha: 1.0)
    static let textPrimary   = NSColor.white
    static let textSecondary = NSColor(white: 0.65, alpha: 1.0)
    static let dotIdle       = NSColor(white: 0.45, alpha: 1.0)
    static let dotPrep       = NSColor.systemOrange
    static let dotSaved      = NSColor.systemGreen
    static let dotError      = NSColor.systemRed

    static let panelWidth: CGFloat  = 360
    static let panelHeight: CGFloat = 52
    static let cornerRadius: CGFloat = 14
    static let dotSize: CGFloat     = 8
}

// MARK: - Controller

/// Owns the `MeetingOverlayPanel`, subscribes to `MeetingSessionController`
/// @Published state, and pushes updates to `MeetingOverlayRootView`.
///
/// Also forwards the ⌥M hotkey intent (toggle meeting recording) through its
/// `toggleFromHotkey()` method — wired by the `DraftAppDelegate` onto
/// `ContextCaptureEngine.onMeetingToggle`.
@available(macOS 14.0, *)
@MainActor
final class MeetingOverlayController {

    enum OverlayState: Equatable {
        case idle
        case preparing
        case recording
        case transcribing
        case saved
        case error(String)
    }

    // MARK: - State

    private(set) var state: OverlayState = .idle
    private var currentDuration: TimeInterval = 0
    private var currentLevel: Float = 0
    private var currentParticipants: [String] = []

    // MARK: - Panel & views

    private var panel: MeetingOverlayPanel?
    private var rootView: MeetingOverlayRootView?
    private var subscriptions: Set<AnyCancellable> = []
    private var autoHideTask: Task<Void, Never>?

    // MARK: - Dependencies

    /// The session controller the overlay reflects and forwards hotkey events to.
    /// Set once by `DraftAppDelegate` during app launch.
    weak var meetingSession: MeetingSessionController?

    // MARK: - Setup

    /// Create the panel, wire subscriptions, and keep it hidden until state
    /// becomes non-idle. Safe to call once at app launch; re-calls are ignored.
    func setup(meetingSession: MeetingSessionController) {
        guard panel == nil else { return }
        self.meetingSession = meetingSession

        let frame = NSRect(
            x: 0, y: 0,
            width: MeetingOverlayTokens.panelWidth,
            height: MeetingOverlayTokens.panelHeight
        )

        let panel = MeetingOverlayPanel(
            contentRect: frame,
            styleMask: [],
            backing: .buffered,
            defer: true
        )

        let rootView = MeetingOverlayRootView(frame: panel.contentView?.bounds ?? frame)
        rootView.autoresizingMask = [.width, .height]
        rootView.onClose = { [weak self] in self?.handleCloseTapped() }
        panel.contentView?.addSubview(rootView)

        self.panel = panel
        self.rootView = rootView

        wireSubscriptions(to: meetingSession)
    }

    // MARK: - Hotkey entry point

    /// Called from `ContextCaptureEngine.onMeetingToggle` when ⌥M fires.
    /// Toggles recording start/stop based on current session state.
    func toggleFromHotkey() {
        guard let session = meetingSession else { return }
        Task { [weak session] in
            guard let session else { return }
            switch session.state {
            case .idle, .ready, .error:
                await session.startRecording()
            case .loadingModels:
                // Still loading — ignore to avoid double-starts.
                break
            case .recording:
                await session.stopRecording()
            case .transcribing:
                // Already processing — leave it alone.
                break
            }
        }
    }

    // MARK: - Subscriptions

    private func wireSubscriptions(to session: MeetingSessionController) {
        session.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] sessionState in
                self?.applySessionState(sessionState)
            }
            .store(in: &subscriptions)

        session.$recordingDuration
            .receive(on: RunLoop.main)
            .sink { [weak self] duration in
                self?.currentDuration = duration
                self?.pushToView()
            }
            .store(in: &subscriptions)

        session.$audioLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.currentLevel = level
                self?.pushToView()
            }
            .store(in: &subscriptions)
    }

    private func applySessionState(_ sessionState: MeetingSessionController.State) {
        switch sessionState {
        case .idle:
            state = .idle
            hidePanel()
        case .loadingModels:
            state = .preparing
            showPanel()
        case .ready:
            // Ready but not recording — hide unless we're already showing a
            // terminal state (saved/error); the auto-hide task handles those.
            if case .saved = state { break }
            if case .error = state { break }
            state = .idle
            hidePanel()
        case .recording:
            state = .recording
            autoHideTask?.cancel()
            showPanel()
        case .transcribing:
            state = .transcribing
            showPanel()
        case .error(let message):
            state = .error(message)
            showPanel()
            scheduleAutoHide(after: 5)
        }
        pushToView()
    }

    // MARK: - Panel show/hide

    private func showPanel() {
        guard let panel = panel else { return }
        if panel.isVisible { return }

        // Position at top-center of the screen containing the mouse.
        let mousePos = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mousePos, $0.frame, false) })
            ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            let origin = NSPoint(
                x: visibleFrame.midX - MeetingOverlayTokens.panelWidth / 2,
                y: visibleFrame.maxY - MeetingOverlayTokens.panelHeight - 12
            )
            panel.setFrameOrigin(origin)
        }
        panel.setContentSize(NSSize(
            width: MeetingOverlayTokens.panelWidth,
            height: MeetingOverlayTokens.panelHeight
        ))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    private func hidePanel() {
        guard let panel = panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    private func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.hidePanel()
        }
    }

    private func handleCloseTapped() {
        guard let session = meetingSession else { hidePanel(); return }
        Task { [weak session] in
            guard let session else { return }
            switch session.state {
            case .recording:
                await session.stopRecording()
            case .transcribing:
                session.cancelActiveTranscription()
            default:
                break
            }
        }
        hidePanel()
    }

    // MARK: - View push

    private func pushToView() {
        rootView?.update(
            state: state,
            duration: currentDuration,
            audioLevel: currentLevel,
            participants: currentParticipants
        )
    }
}
