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
    private let micLabel = NSTextField(labelWithString: "Mic")
    private let systemLabel = NSTextField(labelWithString: "System audio")
    private let micWaveform = WaveformHostView(frame: .zero)
    private let systemWaveform = WaveformHostView(frame: .zero)
    private let closeButton = NSButton()
    private let chevronButton = NSButton()

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
        layer?.borderWidth = 1
        layer?.borderColor = MeetingOverlayTokens.panelStroke.cgColor

        // Record status dot (red during recording, orange while prep/transcribe, grey idle).
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MeetingOverlayTokens.dotSize / 2
        statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotIdle.cgColor
        addSubview(statusDot)

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MeetingOverlayTokens.textPrimary
        addSubview(titleLabel)

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timerLabel.textColor = MeetingOverlayTokens.textSecondary
        addSubview(timerLabel)

        micLabel.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        micLabel.textColor = MeetingOverlayTokens.textSecondary
        addSubview(micLabel)

        systemLabel.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        systemLabel.textColor = MeetingOverlayTokens.textSecondary
        addSubview(systemLabel)

        micWaveform.tintColor = MeetingOverlayTokens.waveformTint
        addSubview(micWaveform)

        systemWaveform.tintColor = MeetingOverlayTokens.waveformTint
        addSubview(systemWaveform)

        // Close/stop button — square X at the right edge.
        if let img = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Stop meeting") {
            closeButton.image = img
            closeButton.contentTintColor = MeetingOverlayTokens.textPrimary
        }
        closeButton.bezelStyle = .inline
        closeButton.isBordered = false
        closeButton.target = self
        closeButton.action = #selector(handleClose)
        addSubview(closeButton)

        // Chevron is intentionally hidden: meeting overlay is now status-only.
        if let img = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil) {
            chevronButton.image = img
            chevronButton.contentTintColor = MeetingOverlayTokens.textSecondary
        }
        chevronButton.bezelStyle = .inline
        chevronButton.isBordered = false
        chevronButton.isHidden = true
        addSubview(chevronButton)
    }

    override func layout() {
        super.layout()
        let pad: CGFloat = 12
        let dotSize = MeetingOverlayTokens.dotSize
        let headerHeight = MeetingOverlayTokens.panelHeight

        // Header row sits at the top of the view, even when the panel
        // grows to show the expanded transcript area. Using bounds.maxY
        // keeps it anchored to the top edge during the grow animation.
        let headerMidY = bounds.height - headerHeight / 2

        statusDot.frame = NSRect(
            x: pad,
            y: headerMidY - dotSize / 2,
            width: dotSize,
            height: dotSize
        )

        let titleX = statusDot.frame.maxX + 8
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(
            x: titleX,
            y: headerMidY - titleSize.height / 2,
            width: min(titleSize.width, 150),
            height: titleSize.height
        )

        let timerSize = timerLabel.fittingSize
        let timerX = titleLabel.frame.maxX + 8
        timerLabel.frame = NSRect(
            x: timerX,
            y: headerMidY - timerSize.height / 2,
            width: timerSize.width,
            height: timerSize.height
        )

        // Close button pinned to the right of the header.
        let closeSize: CGFloat = 18
        closeButton.frame = NSRect(
            x: bounds.width - pad - closeSize,
            y: headerMidY - closeSize / 2,
            width: closeSize,
            height: closeSize
        )

        // Chevron button remains hidden, but keep a frame for layout stability.
        let chevronSize: CGFloat = 16
        chevronButton.frame = NSRect(
            x: closeButton.frame.minX - chevronSize - 6,
            y: headerMidY - chevronSize / 2,
            width: chevronSize,
            height: chevronSize
        )

        // Two waveform strips (mic top, system bottom) mirror the dictation
        // visualizer language, with small source labels for clarity.
        let labelX = timerLabel.frame.maxX + 12
        let systemLabelSize = systemLabel.fittingSize
        let labelWidth = max(24, systemLabelSize.width)
        let levelBarRight = closeButton.frame.minX - 10
        let levelBarX = labelX + labelWidth + 8
        let levelBarWidth = max(0, levelBarRight - levelBarX)
        let levelBarHeight: CGFloat = 10
        let levelBarGap: CGFloat = 2
        let micY = headerMidY + 1
        let systemY = headerMidY + 1 - levelBarHeight - levelBarGap

        micLabel.frame = NSRect(
            x: labelX,
            y: micY + (levelBarHeight - micLabel.fittingSize.height) / 2,
            width: labelWidth,
            height: micLabel.fittingSize.height
        )
        systemLabel.frame = NSRect(
            x: labelX,
            y: systemY + (levelBarHeight - systemLabel.fittingSize.height) / 2,
            width: labelWidth,
            height: systemLabel.fittingSize.height
        )

        micWaveform.frame = NSRect(
            x: levelBarX,
            y: micY,
            width: levelBarWidth,
            height: levelBarHeight
        )
        systemWaveform.frame = NSRect(
            x: levelBarX,
            y: systemY,
            width: levelBarWidth,
            height: levelBarHeight
        )

    }

    // MARK: - Update API

    private var currentMicLevel: Float = 0
    private var currentSystemLevel: Float = 0

    func update(
        state: MeetingOverlayController.OverlayState,
        duration: TimeInterval,
        micLevel: Float,
        systemLevel: Float,
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
            statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotRecording.cgColor
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
        currentMicLevel = max(0, min(1, micLevel))
        currentSystemLevel = max(0, min(1, systemLevel))
        micWaveform.level = currentMicLevel
        systemWaveform.level = currentSystemLevel
        let shouldAnimate = state == .recording
        micWaveform.isActive = shouldAnimate
        systemWaveform.isActive = shouldAnimate

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
    static let panelBg       = OverlayTokens.panelBg
    static let panelStroke   = NSColor.white.withAlphaComponent(0.08)
    static let textPrimary   = OverlayTokens.textPrimary
    static let textSecondary = OverlayTokens.textSecondary
    static let waveformTint  = OverlayTokens.textPrimary
    static let dotIdle       = OverlayTokens.textMuted
    static let dotPrep       = OverlayTokens.textSecondary
    static let dotRecording  = NSColor(red: 0.95, green: 0.22, blue: 0.22, alpha: 1.0)
    static let dotSaved      = NSColor.systemGreen
    static let dotError      = NSColor.systemRed

    static let panelWidth: CGFloat  = 360
    static let panelHeight: CGFloat = 48
    static let cornerRadius: CGFloat = OverlayTokens.cornerRadius
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
    private var currentMicLevel: Float = 0
    private var currentSystemLevel: Float = 0
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
                self?.currentMicLevel = level
                self?.pushToView()
            }
            .store(in: &subscriptions)

        session.$systemLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.currentSystemLevel = level
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

        let desiredHeight = currentPanelHeight()

        // Position at top-center of the screen containing the mouse.
        let mousePos = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mousePos, $0.frame, false) })
            ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            let origin = NSPoint(
                x: visibleFrame.midX - MeetingOverlayTokens.panelWidth / 2,
                y: visibleFrame.maxY - desiredHeight - 12
            )
            panel.setFrameOrigin(origin)
        }
        panel.setContentSize(NSSize(
            width: MeetingOverlayTokens.panelWidth,
            height: desiredHeight
        ))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    /// Target height for the panel based on the current `isExpanded` flag.
    /// Kept as a helper so show/animate paths agree on the value.
    private func currentPanelHeight() -> CGFloat {
        MeetingOverlayTokens.panelHeight
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
            micLevel: currentMicLevel,
            systemLevel: currentSystemLevel,
            participants: currentParticipants
        )
    }
}
