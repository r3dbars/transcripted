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
        self.acceptsMouseMovedEvents = true
        self.allowsToolTipsWhenApplicationIsInactive = true
    }

    // Never steals keyboard focus — meeting UI is read-only status.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@available(macOS 14.0, *)
@MainActor
final class MeetingOverlayTooltipPanel: NSPanel {
    private let tooltipView = MeetingOverlayTooltipView()

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 80, height: 26),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        self.level = .statusBar
        self.backgroundColor = .clear
        self.isOpaque = false
        self.hasShadow = true
        self.ignoresMouseEvents = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        self.contentView = tooltipView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(text: String) -> NSSize {
        tooltipView.update(text: text)
    }
}

@available(macOS 14.0, *)
@MainActor
final class MeetingOverlayTooltipView: NSView {
    private let label = NSTextField(labelWithString: "")
    private let horizontalPadding: CGFloat = 10
    private let verticalPadding: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 0.98).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor

        label.font = .systemFont(ofSize: 11, weight: .medium)
        label.textColor = MeetingOverlayTokens.textPrimary
        label.lineBreakMode = .byClipping
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let labelSize = label.fittingSize
        label.frame = NSRect(
            x: horizontalPadding,
            y: (bounds.height - labelSize.height) / 2,
            width: max(0, bounds.width - horizontalPadding * 2),
            height: labelSize.height
        )
    }

    func update(text: String) -> NSSize {
        label.stringValue = text
        let labelSize = label.fittingSize
        let size = NSSize(
            width: ceil(labelSize.width + horizontalPadding * 2),
            height: max(24, ceil(labelSize.height + verticalPadding * 2))
        )
        frame = NSRect(origin: .zero, size: size)
        needsLayout = true
        return size
    }
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
    private let detailLabel = NSTextField(labelWithString: "")
    private let micLabel = NSTextField(labelWithString: "Mic")
    private let systemLabel = NSTextField(labelWithString: "System audio")
    private let audioWaveform = DualWaveformHostView(frame: .zero)
    private let recordButton = NSButton()
    private let remindButton = NSButton()
    private let closeButton = NSButton()
    private let pillBodyView = MeetingPillBodyView(frame: .zero)
    private let transcriptDrawer = MeetingLiveTranscriptDrawerView(frame: .zero)
    private let warmupTitleLabel = NSTextField(labelWithString: "Getting Transcripted ready")
    private let warmupSubtitleLabel = NSTextField(labelWithString: "Loading dictation and meeting models")
    private let warmupProgress = NSProgressIndicator()
    private var currentState: MeetingOverlayController.OverlayState = .idle
    private var currentWarmupStatus: MeetingSessionController.ModelWarmupStatus = .ready
    private let finishTooltip = "Finish and transcribe"
    private let dismissPromptTooltip = "Dismiss meeting prompt"
    private let remindPromptTooltip = "Remind me soon"
    private let startTooltip = "Start meeting recording"
    private var tooltipPanel: MeetingOverlayTooltipPanel?
    private var tooltipTask: Task<Void, Never>?
    private var tooltipTrackingAreas: [NSTrackingArea] = []
    private var lastTooltipAreaSignature: String?
    private var panelHoverTrackingArea: NSTrackingArea?
    private var isCondensed = false
    private var lastStripFadeAt = Date.distantPast
    private var currentLiveViewAffordance: MeetingLiveViewAffordancePolicy.Affordance?
    private var isTranscriptExpanded = false
    private var isDrawerVisible = false

    /// Invoked when the user clicks the close/stop button.
    var onSecondaryAction: (() -> Void)?
    var onRemindAction: (() -> Void)?
    var onPrimaryAction: (() -> Void)?
    var onLiveViewAction: (() -> Void)?
    var onLiveViewBrowserAction: (() -> Void)?
    var onCopyTranscriptAction: (() -> Void)?
    var onDrawerResizeBegan: (() -> Void)?
    var onDrawerResizeChanged: ((CGFloat) -> Void)?
    var onDrawerResizeEnded: (() -> Void)?
    var onPanelHoverChanged: ((Bool) -> Void)?
    var onStripMenuRequested: (() -> NSMenu?)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    deinit {
        tooltipTask?.cancel()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        wantsLayer = true
        layer?.cornerRadius = MeetingOverlayTokens.cornerRadius
        layer?.masksToBounds = true
        layer?.backgroundColor = MeetingOverlayTokens.panelBg.cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = MeetingOverlayTokens.panelStroke.cgColor

        // Record status dot (red during recording, orange while prep/transcribe, grey idle).
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MeetingOverlayTokens.dotSize / 2
        statusDot.layer?.shadowOffset = .zero
        statusDot.layer?.backgroundColor = MeetingOverlayTokens.dotIdle.cgColor
        addSubview(statusDot)

        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MeetingOverlayTokens.textPrimary
        addSubview(titleLabel)

        timerLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timerLabel.textColor = MeetingOverlayTokens.textSecondary
        addSubview(timerLabel)

        detailLabel.font = NSFont.systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = MeetingOverlayTokens.textSecondary
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.isHidden = true
        addSubview(detailLabel)

        micLabel.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        micLabel.textColor = MeetingOverlayTokens.textSecondary
        addSubview(micLabel)

        systemLabel.font = NSFont.systemFont(ofSize: 8, weight: .medium)
        systemLabel.textColor = MeetingOverlayTokens.textSecondary
        addSubview(systemLabel)

        audioWaveform.primaryTintColor = MeetingOverlayTokens.waveformMicTint
        audioWaveform.secondaryTintColor = MeetingOverlayTokens.waveformSystemTint
        addSubview(audioWaveform)

        warmupTitleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        warmupTitleLabel.textColor = MeetingOverlayTokens.textPrimary
        warmupTitleLabel.isHidden = true
        addSubview(warmupTitleLabel)

        warmupSubtitleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        warmupSubtitleLabel.textColor = MeetingOverlayTokens.textSecondary
        warmupSubtitleLabel.isHidden = true
        addSubview(warmupSubtitleLabel)

        warmupProgress.style = .bar
        warmupProgress.isIndeterminate = false
        warmupProgress.minValue = 0
        warmupProgress.maxValue = 1
        warmupProgress.doubleValue = 0
        warmupProgress.isHidden = true
        addSubview(warmupProgress)

        recordButton.attributedTitle = NSAttributedString(
            string: "Record",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
        )
        recordButton.isBordered = false
        recordButton.wantsLayer = true
        recordButton.layer?.cornerRadius = 8
        recordButton.layer?.backgroundColor = OverlayTokens.accentGreen.cgColor
        recordButton.target = self
        recordButton.action = #selector(handlePrimaryAction)
        recordButton.toolTip = nil
        recordButton.setAccessibilityLabel(startTooltip)
        recordButton.isHidden = true
        addSubview(recordButton)

        remindButton.attributedTitle = buttonTitle("Remind me soon", size: 11, weight: .semibold)
        remindButton.isBordered = false
        remindButton.wantsLayer = true
        remindButton.layer?.cornerRadius = 8
        remindButton.layer?.backgroundColor = MeetingOverlayTokens.quietActionBg.cgColor
        remindButton.layer?.borderWidth = 0.5
        remindButton.layer?.borderColor = MeetingOverlayTokens.quietActionBorder.cgColor
        remindButton.target = self
        remindButton.action = #selector(handleRemindAction)
        remindButton.toolTip = nil
        remindButton.setAccessibilityLabel(remindPromptTooltip)
        remindButton.setAccessibilityHelp("Dismisses this prompt and asks again in a little bit.")
        remindButton.isHidden = true
        addSubview(remindButton)

        // The pill body sits above the passive strip content (dot, timer,
        // waveform) and below the real buttons, so clicking anywhere on the
        // strip toggles the transcript while small drags still move the
        // panel and the buttons stay clickable.
        pillBodyView.onClick = { [weak self] in self?.onLiveViewAction?() }
        pillBodyView.menuProvider = { [weak self] in self?.onStripMenuRequested?() }
        pillBodyView.setAccessibilityIdentifier(MeetingLiveViewAffordancePolicy.automationIdentifier)
        pillBodyView.isHidden = true
        addSubview(pillBodyView)

        closeButton.attributedTitle = NSAttributedString(
            string: "Stop",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: MeetingOverlayTokens.textPrimary
            ]
        )
        closeButton.isBordered = false
        closeButton.wantsLayer = true
        closeButton.layer?.cornerRadius = 8
        closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        closeButton.layer?.borderWidth = 0
        closeButton.imageScaling = .scaleProportionallyDown
        closeButton.setAccessibilityLabel(finishTooltip)
        closeButton.setAccessibilityHelp("Stops recording, saves the audio, and starts transcription.")
        closeButton.target = self
        closeButton.action = #selector(handleSecondaryAction)
        closeButton.isHidden = true
        addSubview(closeButton)

        transcriptDrawer.isHidden = true
        transcriptDrawer.alphaValue = 0
        transcriptDrawer.onOpenInBrowser = { [weak self] in self?.onLiveViewBrowserAction?() }
        transcriptDrawer.onCopyTranscript = { [weak self] in self?.onCopyTranscriptAction?() }
        transcriptDrawer.onResizeDragBegan = { [weak self] in self?.onDrawerResizeBegan?() }
        transcriptDrawer.onResizeDragChanged = { [weak self] delta in self?.onDrawerResizeChanged?(delta) }
        transcriptDrawer.onResizeDragEnded = { [weak self] in self?.onDrawerResizeEnded?() }
        addSubview(transcriptDrawer)

        // Persistent whole-panel hover tracking drives the rest/bloom
        // behavior; .inVisibleRect keeps it sized automatically across
        // every panel resize so it never needs rebuilding.
        let hoverArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(hoverArea)
        panelHoverTrackingArea = hoverArea
    }

    func flashTranscriptCopyFeedback() {
        transcriptDrawer.flashCopyFeedback()
    }

    override func layout() {
        super.layout()
        if currentState == .preparing {
            layoutWarmup()
            return
        }
        if currentState == .prompt {
            layoutPrompt()
            return
        }
        if case .error = currentState {
            layoutError()
            return
        }
        if currentState == .recording {
            layoutRecording()
            return
        }

        layoutStandardStatus()
    }

    private func layoutStandardStatus() {
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
        var nextX = titleX
        if !titleLabel.isHidden {
            let titleSize = titleLabel.fittingSize
            titleLabel.frame = NSRect(
                x: titleX,
                y: headerMidY - titleSize.height / 2,
                width: min(titleSize.width, 150),
                height: titleSize.height
            )
            nextX = titleLabel.frame.maxX + 8
        }

        let timerSize = timerLabel.fittingSize
        timerLabel.frame = NSRect(
            x: nextX,
            y: headerMidY - timerSize.height / 2,
            width: timerSize.width,
            height: timerSize.height
        )

        // Explicit Stop action while recording.
        let closeHeight: CGFloat = 22
        let closeWidth = max(44, closeButton.fittingSize.width + 16)
        closeButton.frame = NSRect(
            x: bounds.width - pad - closeWidth,
            y: headerMidY - closeHeight / 2,
            width: closeWidth,
            height: closeHeight
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

        audioWaveform.frame = NSRect(
            x: levelBarX,
            y: systemY,
            width: levelBarWidth,
            height: levelBarHeight * 2 + levelBarGap
        )
        refreshTooltipTrackingAreas()
    }

    private func layoutRecording() {
        let tokens = MeetingOverlayTokens.self

        if isCondensed {
            // Top-anchored like the full strip, so resting while the panel
            // is still tall mid-animation stays continuous.
            layoutCondensedRecording(
                midY: bounds.height - tokens.condensedPillHeight / 2
            )
            return
        }

        // The recording strip always anchors to the top of the panel. When
        // collapsed the panel *is* the strip, so the anchors coincide — and
        // never branching on the drawer flag means the strip can't jump when
        // the flag flips while the panel is still tall mid-animation.
        let midY = bounds.height - tokens.panelHeight / 2

        statusDot.frame = NSRect(
            x: tokens.padLeft + 2,
            y: midY - tokens.dotSize / 2,
            width: tokens.dotSize,
            height: tokens.dotSize
        )

        let timerSize = timerLabel.fittingSize
        timerLabel.frame = NSRect(
            x: statusDot.frame.maxX + tokens.headerGap,
            y: midY - timerSize.height / 2,
            width: timerSize.width,
            height: timerSize.height
        )

        closeButton.frame = NSRect(
            x: bounds.width - tokens.padRight - tokens.stopHeight,
            y: midY - tokens.stopHeight / 2,
            width: tokens.stopHeight,
            height: tokens.stopHeight
        )

        let barsLeft = timerLabel.frame.maxX + tokens.headerGap
        let barsRight = closeButton.frame.minX - tokens.headerGap
        let availableBarsWidth = max(0, barsRight - barsLeft)
        let barsWidth = min(tokens.recordingWaveformWidth, availableBarsWidth)
        let barsHeight: CGFloat = 22
        let barsY = midY - barsHeight / 2
        audioWaveform.frame = NSRect(
            x: barsLeft + (availableBarsWidth - barsWidth) / 2,
            y: barsY,
            width: barsWidth,
            height: barsHeight
        )

        // The body covers the strip below the stop button so any click on
        // the pill itself toggles the transcript.
        pillBodyView.frame = NSRect(
            x: 0,
            y: bounds.height - tokens.panelHeight,
            width: bounds.width,
            height: tokens.panelHeight
        )

        titleLabel.frame = .zero
        detailLabel.frame = .zero
        micLabel.frame = .zero
        systemLabel.frame = .zero

        // The drawer fills everything below the recording strip; it stays in
        // the tree during the height animation so it can fade and clip while
        // the panel grows or shrinks. Its width is pinned to the expanded
        // panel width so transcript text never re-wraps mid-animation — the
        // panel's corner mask clips the overhang while narrower.
        transcriptDrawer.frame = NSRect(
            x: 0,
            y: 0,
            width: tokens.expandedRecordingPanelWidth,
            height: max(0, bounds.height - tokens.panelHeight)
        )
        refreshTooltipTrackingAreas()
    }

    private func layoutCondensedRecording(midY: CGFloat) {
        let tokens = MeetingOverlayTokens.self

        // Centered capsule content: just the dot and the timer.
        let timerSize = timerLabel.fittingSize
        let contentWidth = tokens.dotSize + tokens.condensedGap + timerSize.width
        let startX = max(tokens.condensedPadLeft, (bounds.width - contentWidth) / 2)

        statusDot.frame = NSRect(
            x: startX,
            y: midY - tokens.dotSize / 2,
            width: tokens.dotSize,
            height: tokens.dotSize
        )
        timerLabel.frame = NSRect(
            x: statusDot.frame.maxX + tokens.condensedGap,
            y: midY - timerSize.height / 2,
            width: timerSize.width,
            height: timerSize.height
        )

        pillBodyView.frame = bounds

        // Keep real frames for the stop button and waveform: while the
        // condense/wake animation runs they cross-fade and ride the moving
        // edges instead of vanishing on the first layout tick. At capsule
        // width the waveform's available span collapses to zero naturally,
        // and both views end the transition hidden.
        closeButton.frame = NSRect(
            x: bounds.width - tokens.padRight - tokens.stopHeight,
            y: midY - tokens.stopHeight / 2,
            width: tokens.stopHeight,
            height: tokens.stopHeight
        )
        let barsLeft = timerLabel.frame.maxX + tokens.headerGap
        let barsRight = closeButton.frame.minX - tokens.headerGap
        let barsWidth = max(0, min(tokens.recordingWaveformWidth, barsRight - barsLeft))
        audioWaveform.frame = NSRect(x: barsLeft, y: midY - 11, width: barsWidth, height: 22)

        titleLabel.frame = .zero
        detailLabel.frame = .zero
        micLabel.frame = .zero
        systemLabel.frame = .zero
        transcriptDrawer.frame = .zero
        refreshTooltipTrackingAreas()
    }

    private func layoutPrompt() {
        let pad: CGFloat = 12
        let dotSize = MeetingOverlayTokens.dotSize
        let topY = bounds.height - 22

        statusDot.frame = NSRect(x: pad, y: topY - dotSize / 2, width: dotSize, height: dotSize)

        let timerSize = timerLabel.fittingSize
        timerLabel.frame = NSRect(
            x: bounds.width - pad - timerSize.width,
            y: topY - timerSize.height / 2,
            width: timerSize.width,
            height: timerSize.height
        )

        let titleX = statusDot.frame.maxX + 8
        let titleWidth = max(0, timerLabel.frame.minX - titleX - 8)
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(
            x: titleX,
            y: topY - titleSize.height / 2,
            width: min(titleWidth, titleSize.width),
            height: titleSize.height
        )

        detailLabel.frame = NSRect(
            x: pad,
            y: 34,
            width: bounds.width - pad * 2,
            height: 16
        )

        let secondaryWidth = max(68, closeButton.fittingSize.width + 18)
        let showsRemind = !remindButton.isHidden
        let remindWidth = showsRemind ? max(118, remindButton.fittingSize.width + 18) : 0
        let primaryWidth = max(74, recordButton.fittingSize.width + 18)
        let buttonHeight: CGFloat = 24
        let buttonGap: CGFloat = 8
        let visibleGapCount: CGFloat = showsRemind ? 2 : 1
        let totalButtonWidth = secondaryWidth + remindWidth + primaryWidth + buttonGap * visibleGapCount
        let buttonStartX = max(pad, bounds.width - pad - totalButtonWidth)

        closeButton.frame = NSRect(
            x: buttonStartX,
            y: 10,
            width: secondaryWidth,
            height: buttonHeight
        )
        if showsRemind {
            remindButton.frame = NSRect(
                x: closeButton.frame.maxX + buttonGap,
                y: 10,
                width: remindWidth,
                height: buttonHeight
            )
        } else {
            remindButton.frame = .zero
        }
        recordButton.frame = NSRect(
            x: bounds.width - pad - primaryWidth,
            y: 10,
            width: primaryWidth,
            height: buttonHeight
        )
        refreshTooltipTrackingAreas()
    }

    private func layoutError() {
        let pad: CGFloat = 12
        let dotSize = MeetingOverlayTokens.dotSize
        let topY = bounds.height - 22

        statusDot.frame = NSRect(x: pad, y: topY - dotSize / 2, width: dotSize, height: dotSize)

        let titleX = statusDot.frame.maxX + 8
        let titleWidth = max(0, bounds.width - titleX - pad)
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(
            x: titleX,
            y: topY - titleSize.height / 2,
            width: min(titleWidth, titleSize.width),
            height: titleSize.height
        )

        detailLabel.frame = NSRect(
            x: pad,
            y: 16,
            width: bounds.width - pad * 2,
            height: 16
        )
        refreshTooltipTrackingAreas()
    }

    private func layoutWarmup() {
        let pad: CGFloat = 16
        let contentWidth = bounds.width - pad * 2

        warmupTitleLabel.frame = NSRect(x: pad, y: bounds.height - 36, width: contentWidth, height: 22)
        warmupSubtitleLabel.frame = NSRect(x: pad, y: bounds.height - 61, width: contentWidth, height: 18)
        warmupProgress.frame = NSRect(x: pad, y: 18, width: contentWidth, height: 10)
        refreshTooltipTrackingAreas()
    }

    // MARK: - Update API

    private var currentMicLevel: Float = 0
    private var currentSystemLevel: Float = 0

    func update(
        state: MeetingOverlayController.OverlayState,
        duration: TimeInterval,
        micLevel: Float,
        systemLevel: Float,
        participants: [String],
        warmupStatus: MeetingSessionController.ModelWarmupStatus?,
        prompt: MeetingOverlayController.PromptDisplay?,
        isCondensed: Bool,
        liveView: MeetingLiveViewAffordancePolicy.Affordance?,
        isTranscriptExpanded: Bool
    ) {
        currentState = state
        currentLiveViewAffordance = liveView
        self.isTranscriptExpanded = state == .recording && !isCondensed && isTranscriptExpanded
        let wasCondensed = self.isCondensed
        self.isCondensed = state == .recording && isCondensed
        if wasCondensed != self.isCondensed {
            hideTooltip()
        }
        layer?.cornerRadius = self.isCondensed
            ? MeetingOverlayTokens.condensedCornerRadius
            : MeetingOverlayTokens.cornerRadius
        if let warmupStatus {
            currentWarmupStatus = warmupStatus
        }

        let isPreparing = state == .preparing
        let isPrompting = state == .prompt
        let isErrorState: Bool
        if case .error = state {
            isErrorState = true
        } else {
            isErrorState = false
        }
        statusDot.isHidden = isPreparing
        titleLabel.isHidden = isPreparing || state == .recording
        timerLabel.isHidden = isPreparing || (state != .recording && !isPrompting)
        detailLabel.isHidden = !(isPrompting || isErrorState)
        micLabel.isHidden = true
        systemLabel.isHidden = true
        recordButton.isHidden = !isPrompting
        remindButton.isHidden = !isPrompting || prompt?.remindTitle == nil
        if state == .recording {
            applyStripContentFade(wasCondensed: wasCondensed)
        } else {
            audioWaveform.isHidden = true
            audioWaveform.alphaValue = 1
            closeButton.isHidden = isPreparing || !isPrompting
            closeButton.alphaValue = 1
        }
        pillBodyView.isHidden = state != .recording || liveView == nil
        if let liveView {
            pillBodyView.setAccessibilityLabel(liveView.accessibilityLabel)
            pillBodyView.setAccessibilityHelp(liveView.accessibilityHelp)
        }
        refreshTranscriptDrawerVisibility()
        warmupTitleLabel.isHidden = !isPreparing
        warmupSubtitleLabel.isHidden = !isPreparing
        warmupProgress.isHidden = !isPreparing

        if isPreparing {
            hideTooltip()
            warmupTitleLabel.stringValue = currentWarmupStatus.title
            warmupSubtitleLabel.stringValue = currentWarmupStatus.subtitle
            warmupProgress.doubleValue = currentWarmupStatus.progress
            needsLayout = true
            return
        }

        applyBaseVisualStyle()

        switch state {
        case .idle:
            titleLabel.stringValue = "Meeting"
            updateStatusDot(color: MeetingOverlayTokens.dotIdle)
            detailLabel.stringValue = ""
        case .preparing:
            titleLabel.stringValue = "Loading models…"
            updateStatusDot(color: MeetingOverlayTokens.dotPrep)
            detailLabel.stringValue = ""
        case .prompt:
            titleLabel.stringValue = prompt?.title ?? "Meeting detected"
            detailLabel.stringValue = prompt?.detail ?? "Record this meeting?"
            timerLabel.stringValue = prompt?.countdownText ?? ""
            updateStatusDot(color: MeetingOverlayTokens.dotPrompt)
            closeButton.attributedTitle = buttonTitle(prompt?.secondaryTitle ?? "Not now", size: 11, weight: .semibold)
            closeButton.toolTip = nil
            closeButton.setAccessibilityLabel(prompt?.secondaryAccessibilityLabel ?? dismissPromptTooltip)
            closeButton.setAccessibilityHelp("Dismisses this meeting recording prompt.")
            closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            if let remindTitle = prompt?.remindTitle {
                remindButton.attributedTitle = buttonTitle(remindTitle, size: 11, weight: .semibold)
                remindButton.setAccessibilityLabel(prompt?.remindAccessibilityLabel ?? remindPromptTooltip)
                remindButton.setAccessibilityHelp("Dismisses this prompt and asks again in a little bit.")
            }
            remindButton.layer?.backgroundColor = MeetingOverlayTokens.quietActionBg.cgColor
            remindButton.layer?.borderWidth = 0.5
            remindButton.layer?.borderColor = MeetingOverlayTokens.quietActionBorder.cgColor
            recordButton.attributedTitle = primaryButtonTitle(prompt?.primaryTitle ?? "Record")
            recordButton.setAccessibilityLabel(prompt?.primaryAccessibilityLabel ?? startTooltip)
        case .recording:
            titleLabel.stringValue = "Recording meeting"
            updateStatusDot(color: MeetingOverlayTokens.dotRecording, haloOpacity: 0.24, haloRadius: 3)
            timerLabel.font = .monospacedDigitSystemFont(ofSize: MeetingOverlayTokens.timerFontSize, weight: .medium)
            timerLabel.textColor = MeetingOverlayTokens.textPrimary
            closeButton.attributedTitle = buttonTitle("", size: 12, weight: .semibold)
            closeButton.image = stopButtonImage()
            closeButton.imagePosition = .imageOnly
            closeButton.contentTintColor = MeetingOverlayTokens.finishActionForeground
            closeButton.toolTip = nil
            closeButton.setAccessibilityLabel(finishTooltip)
            closeButton.setAccessibilityHelp("Stops recording, saves the audio, and starts transcription.")
            closeButton.layer?.backgroundColor = MeetingOverlayTokens.stopActionColor.cgColor
            closeButton.layer?.cornerRadius = MeetingOverlayTokens.stopHeight / 2
            closeButton.layer?.borderWidth = 0
            closeButton.layer?.borderColor = nil
        case .transcribing:
            titleLabel.stringValue = "Saving transcript"
            updateStatusDot(color: MeetingOverlayTokens.dotPrep)
            detailLabel.stringValue = ""
        case .saved:
            titleLabel.stringValue = "Saved to Markdown"
            updateStatusDot(color: MeetingOverlayTokens.dotSaved)
            detailLabel.stringValue = ""
        case .error(let message):
            let failureKind = MeetingFailureKind.classify(message: message)
            let copy = MeetingFailureCopy.make(
                forMessage: message,
                shortErrorMessage: message,
                isRetryable: true
            )
            titleLabel.stringValue = copy.title
            updateStatusDot(
                color: failureKind == .recordingTooShort
                    ? MeetingOverlayTokens.dotIdle
                    : MeetingOverlayTokens.dotError
            )
            detailLabel.stringValue = copy.detail
        }

        if state == .recording {
            timerLabel.stringValue = formatDuration(duration)
        }
        currentMicLevel = max(0, min(1, micLevel))
        currentSystemLevel = max(0, min(1, systemLevel))
        audioWaveform.primaryLevel = currentMicLevel
        audioWaveform.secondaryLevel = currentSystemLevel
        let shouldAnimate = state == .recording && !self.isCondensed
        audioWaveform.isActive = shouldAnimate

        needsLayout = true
    }

    /// Cross-fades the waveform and stop button through rest/wake
    /// transitions so the capsule morph reads as one motion instead of
    /// content popping out on the first frame.
    private func applyStripContentFade(wasCondensed: Bool) {
        let fadeViews: [NSView] = [audioWaveform, closeButton]

        guard wasCondensed != isCondensed else {
            // Steady state: pin final values without animating — but give an
            // in-flight fade time to finish, or the per-second duration tick
            // clips it partway through.
            guard Date().timeIntervalSince(lastStripFadeAt) > 0.3 else { return }
            for view in fadeViews {
                view.isHidden = isCondensed
                view.alphaValue = isCondensed ? 0 : 1
            }
            return
        }

        lastStripFadeAt = Date()
        let fadeOut = isCondensed
        if !fadeOut {
            for view in fadeViews {
                view.isHidden = false
            }
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = fadeOut ? 0.12 : 0.18
            ctx.timingFunction = CAMediaTimingFunction(name: fadeOut ? .easeIn : .easeOut)
            for view in fadeViews {
                view.animator().alphaValue = fadeOut ? 0 : 1
            }
        }, completionHandler: { [weak self] in
            guard let self, self.isCondensed == fadeOut else { return }
            if fadeOut {
                for view in fadeViews {
                    view.isHidden = true
                }
            }
        })
    }

    func updateAudioLevels(micLevel: Float, systemLevel: Float) {
        currentMicLevel = max(0, min(1, micLevel))
        currentSystemLevel = max(0, min(1, systemLevel))
        audioWaveform.primaryLevel = currentMicLevel
        audioWaveform.secondaryLevel = currentSystemLevel
    }

    /// Separate push channel for live transcript content so per-entry updates
    /// do not re-run the full state update path.
    func updateLiveTranscript(
        _ attributed: NSAttributedString,
        statusText: String?,
        hasEntries: Bool
    ) {
        transcriptDrawer.update(
            transcript: attributed,
            statusText: statusText,
            hasEntries: hasEntries
        )
    }

    /// Fades the drawer in or out as one unit. The panel height animates in
    /// the same breath (driven by the controller's resize), so the drawer is
    /// clipped to the space below the recording strip while it appears.
    private func refreshTranscriptDrawerVisibility() {
        let drawerVisible = currentState == .recording && !isCondensed && isTranscriptExpanded
        guard drawerVisible != isDrawerVisible else { return }
        isDrawerVisible = drawerVisible

        if drawerVisible {
            transcriptDrawer.isHidden = false
            transcriptDrawer.prepareForReveal()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                transcriptDrawer.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                transcriptDrawer.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self, !self.isDrawerVisible else { return }
                self.transcriptDrawer.isHidden = true
            })
        }
    }

    private func applyBaseVisualStyle() {
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MeetingOverlayTokens.textPrimary
        timerLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timerLabel.textColor = MeetingOverlayTokens.textSecondary
        detailLabel.font = .systemFont(ofSize: 11, weight: .medium)
        detailLabel.textColor = MeetingOverlayTokens.textSecondary
        closeButton.attributedTitle = buttonTitle("Stop", size: 11, weight: .semibold)
        closeButton.image = nil
        closeButton.imagePosition = .noImage
        closeButton.contentTintColor = MeetingOverlayTokens.textPrimary
        closeButton.toolTip = nil
        closeButton.layer?.cornerRadius = 8
        closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.12).cgColor
        closeButton.layer?.borderWidth = 0
        closeButton.layer?.borderColor = nil
        remindButton.attributedTitle = buttonTitle("Remind me soon", size: 11, weight: .semibold)
        remindButton.image = nil
        remindButton.imagePosition = .noImage
        remindButton.contentTintColor = MeetingOverlayTokens.textPrimary
        remindButton.toolTip = nil
        remindButton.layer?.cornerRadius = 8
        remindButton.layer?.backgroundColor = MeetingOverlayTokens.quietActionBg.cgColor
        remindButton.layer?.borderWidth = 0.5
        remindButton.layer?.borderColor = MeetingOverlayTokens.quietActionBorder.cgColor
    }

    private func buttonTitle(_ title: String, size: CGFloat, weight: NSFont.Weight) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: size, weight: weight),
                .foregroundColor: MeetingOverlayTokens.textPrimary
            ]
        )
    }

    private func primaryButtonTitle(_ title: String) -> NSAttributedString {
        NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.black
            ]
        )
    }

    private func updateStatusDot(color: NSColor, haloOpacity: Float = 0, haloRadius: CGFloat = 0) {
        statusDot.layer?.backgroundColor = color.cgColor
        statusDot.layer?.shadowColor = color.cgColor
        statusDot.layer?.shadowOpacity = haloOpacity
        statusDot.layer?.shadowRadius = haloRadius
    }

    private func stopButtonImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        return NSImage(systemSymbolName: "stop.fill", accessibilityDescription: finishTooltip)?
            .withSymbolConfiguration(config)
    }

    private func refreshTooltipTrackingAreas() {
        // Layout runs every duration tick and every animation frame;
        // removing and re-adding tracking areas while the cursor sits inside
        // one re-fires synthetic enter events and churns tooltips. Only
        // rebuild when a tracked rect or text actually changed.
        let signature = tooltipAreaSignature()
        if signature == lastTooltipAreaSignature { return }
        lastTooltipAreaSignature = signature

        for area in tooltipTrackingAreas {
            removeTrackingArea(area)
        }
        tooltipTrackingAreas.removeAll()

        addTooltipTrackingArea(for: closeButton, text: currentState == .recording ? finishTooltip : dismissPromptTooltip)
        addTooltipTrackingArea(for: remindButton, text: remindPromptTooltip)
        addTooltipTrackingArea(for: recordButton, text: startTooltip)
        if let stripTooltip = currentLiveViewAffordance?.tooltip, !pillBodyView.isHidden {
            // The body sits underneath the stop button; trim its tooltip
            // rect so hovering stop never shows the transcript tooltip.
            var rect = convert(pillBodyView.bounds, from: pillBodyView)
            if !closeButton.isHidden {
                let stopRect = convert(closeButton.bounds, from: closeButton)
                rect.size.width = max(0, stopRect.minX - rect.minX - 4)
            }
            addTooltipTrackingArea(rect: rect, anchorView: pillBodyView, text: stripTooltip)
        }
        if isDrawerVisible {
            addTooltipTrackingArea(
                for: transcriptDrawer.copyActionView,
                text: MeetingLiveViewAffordancePolicy.copyTooltip
            )
            addTooltipTrackingArea(
                for: transcriptDrawer.moreActionView,
                text: MeetingLiveViewAffordancePolicy.moreTooltip
            )
        }

        if tooltipTrackingAreas.isEmpty {
            hideTooltip()
        }
    }

    /// Mirrors exactly the rect/text pairs `refreshTooltipTrackingAreas`
    /// would install, so steady-state layout passes can skip the rebuild.
    private func tooltipAreaSignature() -> String {
        var parts: [String] = []
        func sig(_ view: NSView, _ text: String) {
            guard !view.isHidden, view.frame.width > 0, view.frame.height > 0 else { return }
            let rect = convert(view.bounds, from: view)
            parts.append("\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))|\(text)")
        }
        sig(closeButton, currentState == .recording ? finishTooltip : dismissPromptTooltip)
        sig(remindButton, remindPromptTooltip)
        sig(recordButton, startTooltip)
        if let stripTooltip = currentLiveViewAffordance?.tooltip, !pillBodyView.isHidden {
            var rect = convert(pillBodyView.bounds, from: pillBodyView)
            if !closeButton.isHidden {
                let stopRect = convert(closeButton.bounds, from: closeButton)
                rect.size.width = max(0, stopRect.minX - rect.minX - 4)
            }
            if rect.width > 0, rect.height > 0 {
                parts.append("\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))|\(stripTooltip)")
            }
        }
        if isDrawerVisible {
            sig(transcriptDrawer.copyActionView, MeetingLiveViewAffordancePolicy.copyTooltip)
            sig(transcriptDrawer.moreActionView, MeetingLiveViewAffordancePolicy.moreTooltip)
        }
        return parts.joined(separator: ";")
    }

    private func addTooltipTrackingArea(for view: NSView, text: String) {
        guard !view.isHidden, view.frame.width > 0, view.frame.height > 0 else { return }
        // Convert from the anchor's superview so nested views (drawer
        // children) track correctly, not just direct siblings.
        addTooltipTrackingArea(rect: convert(view.bounds, from: view), anchorView: view, text: text)
    }

    private func addTooltipTrackingArea(rect: NSRect, anchorView: NSView, text: String) {
        guard rect.width > 0, rect.height > 0 else { return }
        let area = NSTrackingArea(
            rect: rect,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: ["tooltipText": text, "anchorView": anchorView]
        )
        tooltipTrackingAreas.append(area)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        if event.trackingArea === panelHoverTrackingArea {
            onPanelHoverChanged?(true)
            return
        }
        guard
            let text = event.trackingArea?.userInfo?["tooltipText"] as? String,
            let anchorView = event.trackingArea?.userInfo?["anchorView"] as? NSView
        else { return }
        scheduleTooltip(text, anchoredTo: anchorView)
    }

    override func mouseExited(with event: NSEvent) {
        if event.trackingArea === panelHoverTrackingArea {
            onPanelHoverChanged?(false)
        }
        hideTooltip()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            hideTooltip()
        }
    }

    private func scheduleTooltip(_ text: String, anchoredTo anchorView: NSView) {
        tooltipTask?.cancel()
        tooltipTask = Task { @MainActor [weak self, weak anchorView] in
            try? await Task.sleep(nanoseconds: MeetingOverlayTokens.tooltipDelayNanoseconds)
            guard !Task.isCancelled, let self, let anchorView else { return }
            self.showTooltip(text, anchoredTo: anchorView)
        }
    }

    private func showTooltip(_ text: String, anchoredTo anchorView: NSView) {
        guard let anchorWindow = window else { return }
        let panel = tooltipPanel ?? MeetingOverlayTooltipPanel()
        tooltipPanel = panel

        let size = panel.update(text: text)
        let anchorRect = anchorView.convert(anchorView.bounds, to: nil)
        let anchorScreenRect = anchorWindow.convertToScreen(anchorRect)
        let screenFrame = anchorWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero

        var x = anchorScreenRect.midX - size.width / 2
        var y = anchorScreenRect.maxY + MeetingOverlayTokens.tooltipOffset
        if y + size.height > screenFrame.maxY - MeetingOverlayTokens.tooltipScreenInset {
            y = anchorScreenRect.minY - size.height - MeetingOverlayTokens.tooltipOffset
        }

        x = min(max(x, screenFrame.minX + MeetingOverlayTokens.tooltipScreenInset),
                screenFrame.maxX - size.width - MeetingOverlayTokens.tooltipScreenInset)
        y = min(max(y, screenFrame.minY + MeetingOverlayTokens.tooltipScreenInset),
                screenFrame.maxY - size.height - MeetingOverlayTokens.tooltipScreenInset)

        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: size), display: true)
        panel.orderFrontRegardless()
    }

    private func hideTooltip() {
        tooltipTask?.cancel()
        tooltipTask = nil
        tooltipPanel?.orderOut(nil)
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }

    // Clicking a tracked button while its tooltip is up would otherwise
    // leave the old tooltip text floating over the new state.
    @objc private func handleSecondaryAction() {
        hideTooltip()
        onSecondaryAction?()
    }

    @objc private func handleRemindAction() {
        hideTooltip()
        onRemindAction?()
    }

    @objc private func handlePrimaryAction() {
        hideTooltip()
        onPrimaryAction?()
    }
}

// MARK: - Pill body

/// Transparent click surface covering the recording strip. Clicking toggles
/// the transcript drawer; a small drag still moves the panel (re-handed to
/// the window once movement exceeds a threshold); right-click shows the
/// pill's context menu.
@available(macOS 14.0, *)
@MainActor
final class MeetingPillBodyView: NSView {
    var onClick: (() -> Void)?
    var menuProvider: (() -> NSMenu?)?

    private var pendingDownEvent: NSEvent?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        pendingDownEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downEvent = pendingDownEvent else { return }
        let dx = abs(event.locationInWindow.x - downEvent.locationInWindow.x)
        let dy = abs(event.locationInWindow.y - downEvent.locationInWindow.y)
        guard dx > 4 || dy > 4 else { return }
        // Past the click threshold: this is a move, hand the gesture to the
        // window so the panel drags exactly like its other background areas.
        pendingDownEvent = nil
        window?.performDrag(with: downEvent)
    }

    override func mouseUp(with event: NSEvent) {
        guard pendingDownEvent != nil else { return }
        pendingDownEvent = nil
        onClick?()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        menuProvider?() ?? super.menu(for: event)
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

// MARK: - Design tokens (local — keeps the meeting overlay visually distinct
// from the draft overlay without polluting OverlayTokens).

@available(macOS 14.0, *)
enum MeetingOverlayTokens {
    static let panelBg       = NSColor(calibratedRed: 0.07, green: 0.07, blue: 0.08, alpha: 0.92)
    static let panelStroke   = NSColor.white.withAlphaComponent(0.08)
    static let textPrimary   = NSColor(calibratedWhite: 0.98, alpha: 1.0)
    static let textSecondary = NSColor.white.withAlphaComponent(0.55)
    static let waveformMicTint = NSColor(calibratedRed: 0.84, green: 0.69, blue: 0.48, alpha: 1.0)
    static let waveformSystemTint = NSColor(calibratedRed: 0.57, green: 0.66, blue: 0.85, alpha: 1.0)
    static let dotIdle       = OverlayTokens.textMuted
    static let dotPrep       = OverlayTokens.textSecondary
    static let dotPrompt     = OverlayTokens.accentGreen
    static let dotRecording  = NSColor(calibratedRed: 1.00, green: 0.27, blue: 0.23, alpha: 1.0)
    static let dotSaved      = NSColor.systemGreen
    static let dotError      = NSColor.systemRed
    static let quietActionBg = NSColor.white.withAlphaComponent(0.08)
    static let quietActionBorder = NSColor.white.withAlphaComponent(0.14)
    static let quietActionTint = NSColor.white.withAlphaComponent(0.70)
    // Stop is the one strong-colored control on the pill: the action every
    // meeting ends with should never need a second look.
    static let stopActionColor = NSColor(calibratedRed: 0.79, green: 0.24, blue: 0.26, alpha: 1.0)
    static let finishActionForeground = NSColor.white.withAlphaComponent(0.96)

    static let panelWidth: CGFloat  = 360
    // Tight fit for dot + timer + waveform + stop; the wide layout only
    // returns while the transcript drawer is open.
    static let recordingPanelWidth: CGFloat = 256
    static let expandedRecordingPanelWidth: CGFloat = 324
    static let condensedPillWidth: CGFloat = 120
    static let panelHeight: CGFloat = 44
    static let condensedPillHeight: CGFloat = 32
    static let promptHeight: CGFloat = 88
    static let warmupHeight: CGFloat = 96
    static let errorHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 22
    static let condensedCornerRadius: CGFloat = 16
    static let dotSize: CGFloat     = 8
    static let padLeft: CGFloat     = 12
    static let padRight: CGFloat    = 8
    static let headerGap: CGFloat   = 8
    static let condensedPadLeft: CGFloat = 12
    static let condensedGap: CGFloat = 7
    static let timerFontSize: CGFloat = 13
    static let drawerPad: CGFloat = 12
    static let drawerBrowserButtonSize: CGFloat = 20
    static let drawerResizeHandleHeight: CGFloat = 12
    static let stopHeight: CGFloat  = 28
    static let recordingWaveformWidth: CGFloat = 124
    static let tooltipOffset: CGFloat = 8
    static let tooltipScreenInset: CGFloat = 6
    static let tooltipDelayNanoseconds: UInt64 = 80_000_000
    static let defaultDetectedMeetingPromptTimeoutSeconds = 30
}

// MARK: - Controller

/// Owns the `MeetingOverlayPanel`, subscribes to `MeetingSessionController`
/// @Published state, and pushes updates to `MeetingOverlayRootView`.
///
/// Also forwards the ⌥M hotkey intent (toggle meeting recording) through its
/// `toggleFromHotkey()` method — wired by the `TranscriptedAppDelegate` onto
/// `ContextCaptureEngine.onMeetingToggle`.
@available(macOS 14.0, *)
@MainActor
final class MeetingOverlayController: NSObject {

    enum OverlayState: Equatable {
        case idle
        case prompt
        case preparing
        case recording
        case transcribing
        case saved
        case error(String)
    }

    struct PromptDisplay: Equatable {
        let title: String
        let detail: String
        let countdownText: String
        let secondaryTitle: String
        let secondaryAccessibilityLabel: String
        let remindTitle: String?
        let remindAccessibilityLabel: String?
        let primaryTitle: String
        let primaryAccessibilityLabel: String
    }

    // MARK: - State

    private(set) var state: OverlayState = .idle
    private var currentDuration: TimeInterval = 0
    private var currentMicLevel: Float = 0
    private var currentSystemLevel: Float = 0
    private var currentParticipants: [String] = []
    private var currentWarmupStatus: MeetingSessionController.ModelWarmupStatus = .ready
    private var currentPrompt: PromptDisplay?
    private var promptCandidate: MeetingPromptDetector.Candidate?
    private var promptKind: PromptKind?
    private var promptCountdownTask: Task<Void, Never>?
    private var promptSecondsRemaining = 0

    // MARK: - Panel & views

    private var panel: MeetingOverlayPanel?
    private var rootView: MeetingOverlayRootView?
    private var subscriptions: Set<AnyCancellable> = []
    private var autoHideTask: Task<Void, Never>?
    private var isShowingCancelConfirmation = false
    private var isRestingCondensed = false
    private var isPanelHovered = false
    private var restTask: Task<Void, Never>?
    private var isTranscriptExpanded = false
    private var lastRequestedPanelSize: NSSize?
    private var drawerResizeBaseHeight: CGFloat?
    private var activeDrawerHeightOverride: CGFloat?
    private var latestTranscriptFinals: [LiveMeetingCodexTranscriptEntry] = []
    private var latestTranscriptPartials: [LiveMeetingCodexSource: LiveMeetingCodexTranscriptEntry] = [:]
    private var latestTranscriptPhase: LiveMeetingTranscriptFeedPhase = .idle
    private var transcriptPushPending = false

    private enum PromptKind {
        case detectedMeeting
        case audioInactivity
        case micBoost
    }

    deinit {
        autoHideTask?.cancel()
        promptCountdownTask?.cancel()
        restTask?.cancel()
    }

    // MARK: - Dependencies

    /// The session controller the overlay reflects and forwards hotkey events to.
    /// Set once by `TranscriptedAppDelegate` during app launch.
    weak var meetingSession: MeetingSessionController?
    var onPromptRecord: ((MeetingPromptDetector.Candidate) -> Void)?
    var onPromptDismiss: ((MeetingPromptDetector.Candidate) -> Void)?
    var onPromptRemindSoon: ((MeetingPromptDetector.Candidate) -> Void)?

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
        rootView.onSecondaryAction = { [weak self] in self?.handleSecondaryActionTapped() }
        rootView.onRemindAction = { [weak self] in self?.handleRemindActionTapped() }
        rootView.onPrimaryAction = { [weak self] in self?.handlePrimaryActionTapped() }
        rootView.onLiveViewAction = { [weak self] in self?.handleLiveViewTapped() }
        rootView.onLiveViewBrowserAction = { [weak self] in self?.handleLiveViewBrowserTapped() }
        rootView.onPanelHoverChanged = { [weak self] hovered in self?.handlePanelHoverChanged(hovered) }
        rootView.onStripMenuRequested = { [weak self] in self?.makeStripMenu() }
        rootView.onCopyTranscriptAction = { [weak self] in self?.handleCopyTranscriptTapped() }
        rootView.onDrawerResizeBegan = { [weak self] in self?.handleDrawerResizeBegan() }
        rootView.onDrawerResizeChanged = { [weak self] delta in self?.handleDrawerResizeChanged(delta) }
        rootView.onDrawerResizeEnded = { [weak self] in self?.handleDrawerResizeEnded() }
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
            case .idle, .ready, .transcribing, .error:
                await session.startRecording(trigger: .hotkey)
            case .loadingModels:
                // Still loading — ignore to avoid double-starts.
                break
            case .recording:
                await session.stopRecording(reason: .hotkeyToggle)
            }
        }
    }

    @discardableResult
    func presentDetectedMeetingPrompt(
        _ candidate: MeetingPromptDetector.Candidate,
        timeout seconds: Int = MeetingOverlayTokens.defaultDetectedMeetingPromptTimeoutSeconds
    ) -> Bool {
        guard let session = meetingSession else { return false }

        switch session.state {
        case .recording, .transcribing, .loadingModels:
            return false
        case .idle, .ready, .error:
            break
        }

        guard state == .idle || state == .saved else { return false }

        autoHideTask?.cancel()
        promptCountdownTask?.cancel()

        promptCandidate = candidate
        promptKind = .detectedMeeting
        promptSecondsRemaining = max(1, seconds)
        currentPrompt = detectedMeetingPromptDisplay(countdownSeconds: promptSecondsRemaining)
        state = .prompt
        showPanel()
        pushToView()
        schedulePromptCountdown()
        return true
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
                self?.pushAudioLevelsToView()
            }
            .store(in: &subscriptions)

        session.$systemLevel
            .receive(on: RunLoop.main)
            .sink { [weak self] level in
                self?.currentSystemLevel = level
                self?.pushAudioLevelsToView()
            }
            .store(in: &subscriptions)

        session.$warmupStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.currentWarmupStatus = status
                self?.pushToView()
            }
            .store(in: &subscriptions)

        session.$audioInactivityWarning
            .receive(on: RunLoop.main)
            .sink { [weak self] warning in
                self?.applyAudioInactivityWarning(warning)
            }
            .store(in: &subscriptions)

        session.$isMicBoostPromptVisible
            .receive(on: RunLoop.main)
            .sink { [weak self] visible in
                self?.applyMicBoostPrompt(visible)
            }
            .store(in: &subscriptions)

        let feed = session.liveTranscriptFeed
        feed.$finalEntries
            .combineLatest(feed.$partialEntries, feed.$phase)
            .receive(on: RunLoop.main)
            .sink { [weak self] finals, partials, phase in
                self?.latestTranscriptFinals = finals
                self?.latestTranscriptPartials = partials
                self?.latestTranscriptPhase = phase
                self?.pushTranscriptToView()
            }
            .store(in: &subscriptions)
    }

    private func pushTranscriptToView() {
        // Word-rate updates arrive for the whole meeting; building the
        // attributed string and re-laying-out the text view is only worth
        // doing while the drawer can actually be seen. Hidden updates mark
        // the view dirty and get flushed once on reveal.
        guard isTranscriptExpanded, state == .recording else {
            transcriptPushPending = true
            return
        }
        transcriptPushPending = false

        let hasEntries = !latestTranscriptFinals.isEmpty || !latestTranscriptPartials.isEmpty
        rootView?.updateLiveTranscript(
            makeTranscriptAttributedText(
                finals: latestTranscriptFinals,
                partials: latestTranscriptPartials
            ),
            statusText: MeetingLiveViewAffordancePolicy.drawerStatus(
                phase: latestTranscriptPhase,
                hasEntries: hasEntries
            ),
            hasEntries: hasEntries
        )
    }

    private func flushPendingTranscriptIfNeeded() {
        guard transcriptPushPending else { return }
        pushTranscriptToView()
    }

    private func makeTranscriptAttributedText(
        finals: [LiveMeetingCodexTranscriptEntry],
        partials: [LiveMeetingCodexSource: LiveMeetingCodexTranscriptEntry]
    ) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        paragraph.paragraphSpacing = 7

        func append(_ entry: LiveMeetingCodexTranscriptEntry, isPartial: Bool) {
            if result.length > 0 {
                result.append(NSAttributedString(string: "\n"))
            }
            let isMic = entry.source == .microphone
            let tag = isMic ? "You" : "Them"
            let tagColor = isMic
                ? MeetingOverlayTokens.waveformMicTint
                : MeetingOverlayTokens.waveformSystemTint
            result.append(NSAttributedString(
                string: "\(tag)  ",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                    .foregroundColor: isPartial ? tagColor.withAlphaComponent(0.55) : tagColor,
                    .paragraphStyle: paragraph,
                ]
            ))
            result.append(NSAttributedString(
                string: entry.text,
                attributes: [
                    .font: NSFont.systemFont(ofSize: 12, weight: .regular),
                    .foregroundColor: isPartial
                        ? MeetingOverlayTokens.textSecondary
                        : MeetingOverlayTokens.textPrimary,
                    .paragraphStyle: paragraph,
                ]
            ))
        }

        for entry in finals {
            append(entry, isPartial: false)
        }
        for source in [LiveMeetingCodexSource.microphone, .system] {
            if let partial = partials[source] {
                append(partial, isPartial: true)
            }
        }
        return result
    }

    private func applyAudioInactivityWarning(_ warning: MeetingAudioInactivityWarning?) {
        guard let warning else {
            clearAudioInactivityPrompt()
            return
        }

        guard meetingSession?.state == .recording else { return }

        autoHideTask?.cancel()
        promptCountdownTask?.cancel()

        promptCandidate = nil
        promptKind = .audioInactivity
        promptSecondsRemaining = warning.automaticStopAllowed ? max(1, warning.countdownSeconds) : 0
        currentPrompt = audioInactivityPromptDisplay(
            warning: warning,
            countdownSeconds: promptSecondsRemaining
        )
        bloomFromRest()
        state = .prompt
        showPanel()
        pushToView()
        if warning.automaticStopAllowed {
            schedulePromptCountdown()
        }
    }

    private func applyMicBoostPrompt(_ visible: Bool) {
        guard visible else {
            clearMicBoostPrompt()
            return
        }
        guard meetingSession?.state == .recording else { return }
        // Precedence: never replace an active audio-inactivity prompt (it can
        // auto-stop the recording). The post-meeting Home hint is the backstop.
        if state == .prompt, promptKind == .audioInactivity { return }

        autoHideTask?.cancel()
        promptCountdownTask?.cancel()

        promptCandidate = nil
        promptKind = .micBoost
        promptSecondsRemaining = 0
        currentPrompt = micBoostPromptDisplay()
        bloomFromRest()
        state = .prompt
        showPanel()
        pushToView()
        // No schedulePromptCountdown(): expiry must never auto-enable VPIO.
    }

    private func clearMicBoostPrompt() {
        guard promptKind == .micBoost else { return }

        promptCountdownTask?.cancel()
        promptKind = nil
        currentPrompt = nil

        if meetingSession?.state == .recording {
            state = .recording
            showPanel()
            pushToView()
            scheduleRestIfNeeded()
        } else {
            state = .idle
            hidePanel()
        }
    }

    private func applySessionState(_ sessionState: MeetingSessionController.State) {
        switch sessionState {
        case .idle:
            cancelRest()
            isTranscriptExpanded = false
            if state == .prompt {
                pushToView()
                break
            }
            promptKind = nil
            state = .idle
            hidePanel()
        case .loadingModels:
            cancelRest()
            isTranscriptExpanded = false
            state = .preparing
            currentPrompt = nil
            promptCandidate = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            showPanel()
        case .ready:
            cancelRest()
            isTranscriptExpanded = false
            if state == .prompt {
                pushToView()
                break
            }
            // Ready but not recording — hide unless we're already showing a
            // terminal state (saved/error); the auto-hide task handles those.
            if case .transcribing = state {
                state = .saved
                showPanel()
                scheduleAutoHide(after: 1.5)
                break
            }
            if case .saved = state { break }
            if case .error = state { break }
            state = .idle
            hidePanel()
        case .recording:
            if state != .recording {
                // New recording: restore the user's last drawer choice so a
                // transcript they kept open last meeting opens itself, and
                // start from a clean hover state — enter events re-arm it.
                isTranscriptExpanded = LiveMeetingCodexPreferences.isEnabled()
                    && LiveMeetingCodexPreferences.isDrawerOpenPreferred()
                isPanelHovered = false
            }
            isRestingCondensed = false
            state = .recording
            currentPrompt = nil
            promptCandidate = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            autoHideTask?.cancel()
            showPanel()
            flushPendingTranscriptIfNeeded()
            scheduleRestIfNeeded()
        case .transcribing:
            cancelRest()
            isTranscriptExpanded = false
            state = .transcribing
            currentPrompt = nil
            promptCandidate = nil
            promptKind = nil
            promptCountdownTask?.cancel()
            showPanel()
        case .error(let message):
            cancelRest()
            isTranscriptExpanded = false
            state = .error(message)
            currentPrompt = nil
            promptCandidate = nil
            promptKind = nil
            promptCountdownTask?.cancel()
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
        let desiredWidth = currentPanelWidth()

        // Position at top-center of the screen containing the mouse.
        let mousePos = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mousePos, $0.frame, false) })
            ?? NSScreen.main
        if let visibleFrame = screen?.visibleFrame {
            let origin = NSPoint(
                x: visibleFrame.midX - desiredWidth / 2,
                y: visibleFrame.maxY - desiredHeight - 12
            )
            panel.setFrameOrigin(origin)
        }
        panel.setContentSize(NSSize(
            width: desiredWidth,
            height: desiredHeight
        ))
        lastRequestedPanelSize = NSSize(width: desiredWidth, height: desiredHeight)
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
        switch state {
        case .preparing:
            return MeetingOverlayTokens.warmupHeight
        case .prompt:
            return MeetingOverlayTokens.promptHeight
        case .recording where isVisuallyCondensed:
            return MeetingOverlayTokens.condensedPillHeight
        case .recording where isTranscriptExpanded:
            return MeetingOverlayTokens.panelHeight + currentDrawerHeight()
        case .error:
            return MeetingOverlayTokens.errorHeight
        default:
            return MeetingOverlayTokens.panelHeight
        }
    }

    // The transcript drawer reuses the recording pill's width on purpose:
    // expansion is a pure downward slide, so the header strip never moves
    // and text never re-wraps mid-animation.
    private func currentPanelWidth() -> CGFloat {
        switch state {
        case .recording where isVisuallyCondensed:
            return MeetingOverlayTokens.condensedPillWidth
        case .recording where isTranscriptExpanded:
            return MeetingOverlayTokens.expandedRecordingPanelWidth
        case .recording:
            return MeetingOverlayTokens.recordingPanelWidth
        default:
            return MeetingOverlayTokens.panelWidth
        }
    }

    private func hidePanel() {
        guard let panel = panel, panel.isVisible else { return }
        lastRequestedPanelSize = nil
        // A panel hidden under the cursor never delivers mouseExited; a
        // stale hover flag would silently block resting next recording.
        isPanelHovered = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.14
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        })
    }

    /// Discard lives behind the pill's context menu (with this confirmation)
    /// rather than as a permanent button: deleting a recording is a rare,
    /// deliberate act and must never sit one mis-click from Stop.
    private func handleDiscardRequested() {
        guard !isShowingCancelConfirmation else { return }
        guard let session = meetingSession else { return }
        guard case .recording = session.state else { return }

        isShowingCancelConfirmation = true
        defer {
            isShowingCancelConfirmation = false
        }

        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard this meeting recording?"
        alert.informativeText = "This will stop the meeting recording and delete the captured audio. No transcript will be saved."
        alert.addButton(withTitle: "Keep Recording")
        alert.addButton(withTitle: "Discard Recording")
        alert.buttons.last?.hasDestructiveAction = true

        let response = alert.runModal()
        guard response == .alertSecondButtonReturn else { return }

        Task { [weak session] in
            await session?.cancelRecording(reason: .discardButton)
        }
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
            if case .recording = session.state {
                await session.stopRecording(reason: .overlayStopButton)
            }
        }
    }

    private func handleSecondaryActionTapped() {
        switch state {
        case .prompt:
            switch promptKind {
            case .audioInactivity:
                meetingSession?.dismissAudioInactivityWarning()
            case .micBoost:
                meetingSession?.declineMicBoostPrompt()
            case .detectedMeeting, .none:
                dismissPrompt(notifyDetector: true)
            }
        case .recording:
            handleCloseTapped()
        default:
            hidePanel()
        }
    }

    private func handlePrimaryActionTapped() {
        guard case .prompt = state else { return }
        promptCountdownTask?.cancel()

        switch promptKind {
        case .audioInactivity:
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.endRecordingFromAudioInactivityPrompt(automatic: false)
            }
        case .micBoost:
            // Session clears the published flag, which routes back through
            // applyMicBoostPrompt(false) -> clearMicBoostPrompt -> .recording.
            meetingSession?.acceptMicBoostPrompt()
        case .detectedMeeting, .none:
            guard let candidate = promptCandidate else { return }
            onPromptRecord?(candidate)
        }
    }

    private func handleRemindActionTapped() {
        guard case .prompt = state, let candidate = promptCandidate else { return }
        promptCountdownTask?.cancel()
        onPromptRemindSoon?(candidate)
        promptCandidate = nil
        currentPrompt = nil
        state = .idle
        hidePanel()
    }

    /// Point-of-use live transcript action. With the preference already on
    /// this toggles the embedded transcript drawer; with it off this is the
    /// one-click enable: persist the preference, prepare the workspace and
    /// preview server (so the browser/agent views work too), late-join the
    /// sidecar to the in-flight recording, and open the drawer. None of
    /// these steps can raise a TCC prompt. Failure rolls the enable back,
    /// mirroring Settings' disable-after-failure behavior.
    private func handleLiveViewTapped() {
        guard state == .recording else { return }

        if LiveMeetingCodexPreferences.isEnabled() {
            isTranscriptExpanded.toggle()
            LiveMeetingCodexPreferences.setDrawerOpenPreferred(isTranscriptExpanded)
            if isTranscriptExpanded {
                bloomFromRest()
                flushPendingTranscriptIfNeeded()
            } else {
                scheduleRestIfNeeded()
            }
            pushToView()
            return
        }

        LiveMeetingCodexPreferences.setEnabled(true)
        do {
            let workspaceURL = try AgentConnectionGuide.ensureLiveMeetingCodexWorkspace()
            meetingSession?.connectLiveSidecarToActiveRecording()
            _ = try LiveMeetingPreviewServer.shared.start(workspaceURL: workspaceURL)
            isTranscriptExpanded = true
            LiveMeetingCodexPreferences.setDrawerOpenPreferred(true)
            bloomFromRest()
            flushPendingTranscriptIfNeeded()
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .liveSidecar,
                agentTarget: .localAgent,
                surface: .meetingOverlay
            )
        } catch {
            LiveMeetingCodexPreferences.setEnabled(false)
            meetingSession?.stopLiveCodexSessionFromSettings()
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .liveSidecar,
                agentTarget: .localAgent,
                surface: .meetingOverlay,
                result: .failed
            )
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "live_view_enable_from_overlay_failed",
                message: "Live transcript could not be enabled from the meeting overlay",
                context: ["error": error.localizedDescription]
            )
        }

        pushToView()
    }

    // MARK: - Rest / wake

    /// True when the pill should currently render as the compact capsule.
    /// Hovering wakes the pill (clears the resting state) rather than
    /// temporarily overriding rendering, so hover-out never resizes anything
    /// directly — only the countdown does. That asymmetry is what makes the
    /// interaction immune to spurious enter/exit events during animations.
    private var isVisuallyCondensed: Bool {
        MeetingPillRestPolicy.isCondensedRendered(
            isResting: isRestingCondensed,
            isRecording: state == .recording,
            isTranscriptVisible: isTranscriptExpanded
        )
    }

    private func scheduleRestIfNeeded() {
        restTask?.cancel()
        guard !isRestingCondensed,
              MeetingPillRestPolicy.canRest(
                isRecording: state == .recording,
                isTranscriptVisible: isTranscriptExpanded,
                keepControlsVisible: MeetingOverlayPillPreferences.keepControlsVisible(),
                isHovered: isPanelHovered
              ) else { return }

        restTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(MeetingPillRestPolicy.restDelaySeconds * 1_000_000_000)
            )
            guard !Task.isCancelled, let self else { return }
            guard MeetingPillRestPolicy.canRest(
                isRecording: self.state == .recording,
                isTranscriptVisible: self.isTranscriptExpanded,
                keepControlsVisible: MeetingOverlayPillPreferences.keepControlsVisible(),
                isHovered: self.isPanelHovered
            ) else { return }
            // Belt and braces against a lost exit/enter pair: never rest
            // while the pointer is physically over the panel, even if the
            // hover flag went stale.
            guard !self.pointerIsOverPanel() else {
                self.scheduleRestIfNeeded()
                return
            }
            self.isRestingCondensed = true
            self.pushToView()
        }
    }

    private func pointerIsOverPanel() -> Bool {
        guard let panel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
    }

    /// Leaving the recording flow entirely: stop the countdown and forget
    /// the resting state.
    private func cancelRest() {
        restTask?.cancel()
        restTask = nil
        isRestingCondensed = false
    }

    /// Wake the pill back to its full strip (prompts, drawer opens, pin).
    private func bloomFromRest() {
        restTask?.cancel()
        restTask = nil
        isRestingCondensed = false
    }

    private func handlePanelHoverChanged(_ hovered: Bool) {
        guard hovered != isPanelHovered else { return }
        isPanelHovered = hovered
        if hovered {
            restTask?.cancel()
            if isRestingCondensed {
                // Wake: hovering restores the full pill, which then stays
                // until the next quiet stretch passes — no peek-and-snap.
                isRestingCondensed = false
                pushToView()
            }
        } else {
            scheduleRestIfNeeded()
        }
    }

    // MARK: - Pill context menu

    private func makeStripMenu() -> NSMenu? {
        guard state == .recording else { return nil }

        // An open menu is attention: pause the rest countdown so the pill
        // cannot shrink underneath it. The next hover-out reschedules.
        restTask?.cancel()

        let menu = NSMenu()

        let toggleItem = NSMenuItem(
            title: MeetingLiveViewAffordancePolicy.transcriptToggleMenuTitle(
                isLiveMeetingSidecarEnabled: LiveMeetingCodexPreferences.isEnabled(),
                isTranscriptVisible: isTranscriptExpanded
            ),
            action: #selector(handleMenuToggleTranscript),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let pinItem = NSMenuItem(
            title: MeetingLiveViewAffordancePolicy.keepControlsVisibleMenuTitle,
            action: #selector(handleMenuTogglePin),
            keyEquivalent: ""
        )
        pinItem.target = self
        pinItem.state = MeetingOverlayPillPreferences.keepControlsVisible() ? .on : .off
        menu.addItem(pinItem)

        if LiveMeetingCodexPreferences.isEnabled() {
            let browserItem = NSMenuItem(
                title: MeetingLiveViewAffordancePolicy.openInBrowserMenuTitle,
                action: #selector(handleMenuOpenInBrowser),
                keyEquivalent: ""
            )
            browserItem.target = self
            menu.addItem(browserItem)
        }

        menu.addItem(.separator())

        let discardItem = NSMenuItem(
            title: MeetingLiveViewAffordancePolicy.discardRecordingMenuTitle,
            action: #selector(handleMenuDiscard),
            keyEquivalent: ""
        )
        discardItem.target = self
        menu.addItem(discardItem)

        return menu
    }

    @objc private func handleMenuToggleTranscript() {
        handleLiveViewTapped()
    }

    @objc private func handleMenuTogglePin() {
        let pinned = !MeetingOverlayPillPreferences.keepControlsVisible()
        MeetingOverlayPillPreferences.setKeepControlsVisible(pinned)
        if pinned {
            bloomFromRest()
        } else {
            scheduleRestIfNeeded()
        }
        pushToView()
    }

    @objc private func handleMenuOpenInBrowser() {
        handleLiveViewBrowserTapped()
    }

    @objc private func handleMenuDiscard() {
        handleDiscardRequested()
    }

    private func currentDrawerHeight() -> CGFloat {
        activeDrawerHeightOverride ?? CGFloat(LiveMeetingCodexPreferences.preferredDrawerHeight())
    }

    private func handleDrawerResizeBegan() {
        guard state == .recording, isTranscriptExpanded else { return }
        let height = currentDrawerHeight()
        drawerResizeBaseHeight = height
        activeDrawerHeightOverride = height
    }

    private func handleDrawerResizeChanged(_ delta: CGFloat) {
        guard let base = drawerResizeBaseHeight, let panel, panel.isVisible else { return }
        var height = CGFloat(LiveMeetingCodexPreferences.clampedDrawerHeight(Double(base + delta)))

        var frame = panel.frame
        let top = frame.origin.y + frame.height
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            height = min(height, top - visible.minY - 8 - MeetingOverlayTokens.panelHeight)
        }

        activeDrawerHeightOverride = height
        let total = MeetingOverlayTokens.panelHeight + height
        frame.origin.y = top - total
        frame.size.height = total
        // Direct, unanimated frame tracking while the user drags; the size
        // memo keeps duration ticks from animating back mid-drag.
        panel.setFrame(frame, display: true)
        lastRequestedPanelSize = frame.size
    }

    private func handleDrawerResizeEnded() {
        if let height = activeDrawerHeightOverride {
            LiveMeetingCodexPreferences.setPreferredDrawerHeight(Double(height))
        }
        drawerResizeBaseHeight = nil
        activeDrawerHeightOverride = nil
    }

    private func handleCopyTranscriptTapped() {
        let text = makeTranscriptPlainText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        rootView?.flashTranscriptCopyFeedback()
    }

    private func makeTranscriptPlainText() -> String {
        var lines: [String] = []
        for entry in latestTranscriptFinals {
            lines.append("\(entry.source == .microphone ? "You" : "Them"): \(entry.text)")
        }
        for source in [LiveMeetingCodexSource.microphone, .system] {
            if let partial = latestTranscriptPartials[source] {
                lines.append("\(source == .microphone ? "You" : "Them"): \(partial.text)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Drawer-header action: opens the tokenized browser preview, the same
    /// page Settings' "Open Live View" uses and the one agents watch.
    private func handleLiveViewBrowserTapped() {
        do {
            let workspaceURL = try AgentConnectionGuide.ensureLiveMeetingCodexWorkspace()
            let previewURL = try LiveMeetingPreviewServer.shared.start(workspaceURL: workspaceURL)
            let opened = NSWorkspace.shared.open(previewURL)
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .livePreview,
                agentTarget: .localAgent,
                surface: .meetingOverlay,
                result: opened ? .success : .failed
            )
            if opened {
                ActivationTelemetry.trackAgentPromptAction(
                    promptKind: .liveMeetingPreview,
                    actionKind: .opened,
                    agentTarget: .localAgent,
                    surface: .meetingOverlay
                )
            }
        } catch {
            ActivationTelemetry.trackAgentSetupCTA(
                setupKind: .livePreview,
                agentTarget: .localAgent,
                surface: .meetingOverlay,
                result: .failed
            )
            DiagnosticsTrail.record(
                level: .warning,
                engine: "meeting",
                event: "live_view_open_from_overlay_failed",
                message: "Live View could not open from the meeting overlay",
                context: ["error": error.localizedDescription]
            )
        }
    }

    private func dismissPrompt(notifyDetector: Bool) {
        promptCountdownTask?.cancel()

        if notifyDetector, let candidate = promptCandidate {
            onPromptDismiss?(candidate)
        }

        promptCandidate = nil
        promptKind = nil
        currentPrompt = nil
        state = .idle
        hidePanel()
    }

    private func clearAudioInactivityPrompt() {
        guard promptKind == .audioInactivity else { return }

        promptCountdownTask?.cancel()
        promptKind = nil
        currentPrompt = nil

        if meetingSession?.state == .recording {
            state = .recording
            showPanel()
            pushToView()
            scheduleRestIfNeeded()
            // A mic-boost prompt may have fired while the inactivity prompt
            // was up (suppressed by precedence) or been replaced by it. The
            // session still latches it visible — and already recorded its
            // outcome as "shown" — so re-present instead of silently losing
            // the one-shot in-meeting offer.
            if meetingSession?.isMicBoostPromptVisible == true {
                applyMicBoostPrompt(true)
            }
        } else {
            state = .idle
            hidePanel()
        }
    }

    private func schedulePromptCountdown() {
        promptCountdownTask?.cancel()
        promptCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while self.promptSecondsRemaining > 0 {
                self.refreshPromptCountdownDisplay()
                self.pushToView()

                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.promptSecondsRemaining -= 1
            }

            self.handlePromptCountdownExpired()
        }
    }

    private func refreshPromptCountdownDisplay() {
        switch promptKind {
        case .audioInactivity:
            let warning = meetingSession?.audioInactivityWarning
                ?? MeetingAudioInactivityWarning(
                    inactiveDuration: 5 * 60,
                    countdownSeconds: max(1, promptSecondsRemaining)
                )
            currentPrompt = audioInactivityPromptDisplay(
                warning: warning,
                countdownSeconds: promptSecondsRemaining
            )
        case .micBoost:
            currentPrompt = micBoostPromptDisplay()
        case .detectedMeeting, .none:
            currentPrompt = detectedMeetingPromptDisplay(countdownSeconds: promptSecondsRemaining)
        }
    }

    private func handlePromptCountdownExpired() {
        switch promptKind {
        case .micBoost:
            // Defensive no-op: a countdown is never scheduled for this kind,
            // and expiry must never auto-enable VPIO.
            return
        case .audioInactivity:
            guard meetingSession?.audioInactivityWarning?.automaticStopAllowed != false else {
                return
            }
            Task { @MainActor [weak self] in
                guard let session = self?.meetingSession else { return }
                await session.endRecordingFromAudioInactivityPrompt(automatic: true)
            }
        case .detectedMeeting, .none:
            dismissPrompt(notifyDetector: true)
        }
    }

    private func detectedMeetingPromptDisplay(countdownSeconds: Int) -> PromptDisplay {
        PromptDisplay(
            title: promptCandidate?.title ?? "Meeting detected",
            detail: promptCandidate?.detail ?? "Record this meeting?",
            countdownText: "\(countdownSeconds)s",
            secondaryTitle: "Not now",
            secondaryAccessibilityLabel: "Dismiss meeting prompt",
            remindTitle: "Remind me soon",
            remindAccessibilityLabel: "Remind me soon",
            primaryTitle: "Record",
            primaryAccessibilityLabel: "Start meeting recording"
        )
    }

    private func audioInactivityPromptDisplay(
        warning: MeetingAudioInactivityWarning,
        countdownSeconds: Int
    ) -> PromptDisplay {
        if warning.kind == .degradedRoute {
            return PromptDisplay(
                title: "Audio route changed",
                detail: "Mic or system audio looks muted. Transcripted is still recording.",
                countdownText: "",
                secondaryTitle: "Keep Recording",
                secondaryAccessibilityLabel: "Keep recording",
                remindTitle: nil,
                remindAccessibilityLabel: nil,
                primaryTitle: "End & Transcribe",
                primaryAccessibilityLabel: "End and transcribe meeting"
            )
        }

        return PromptDisplay(
            title: "No audio detected",
            detail: "No mic or system audio for \(formatInactiveDuration(warning.inactiveDuration)).",
            countdownText: "Ends in \(max(0, countdownSeconds))s",
            secondaryTitle: "Keep Recording",
            secondaryAccessibilityLabel: "Keep recording",
            remindTitle: nil,
            remindAccessibilityLabel: nil,
            primaryTitle: "End & Transcribe",
            primaryAccessibilityLabel: "End and transcribe meeting"
        )
    }

    // The prompt panel renders `detail` as a single truncating line (~336pt
    // at 11pt medium; fixed MeetingOverlayTokens.promptHeight). The ducking
    // trade-off disclosure must be the detail on its own and fit untruncated
    // — the user has to see the cost before consenting to VPIO — so the
    // cause lives in the title instead.
    private func micBoostPromptDisplay() -> PromptDisplay {
        PromptDisplay(
            title: "Mic is very quiet — another app's call",
            detail: "Boosting may make other apps' audio slightly quieter.",
            countdownText: "",
            secondaryTitle: "Not now",
            secondaryAccessibilityLabel: "Keep software mic boost",
            remindTitle: nil,
            remindAccessibilityLabel: nil,
            primaryTitle: "Boost Mic",
            primaryAccessibilityLabel: "Boost microphone with Apple voice processing"
        )
    }

    private func formatInactiveDuration(_ duration: TimeInterval) -> String {
        let minutes = max(1, Int(round(duration / 60)))
        return minutes == 1 ? "1 minute" : "\(minutes) minutes"
    }

    // MARK: - View push

    private func pushToView() {
        resizePanelIfNeeded()
        rootView?.update(
            state: state,
            duration: currentDuration,
            micLevel: currentMicLevel,
            systemLevel: currentSystemLevel,
            participants: currentParticipants,
            warmupStatus: currentWarmupStatus,
            prompt: currentPrompt,
            isCondensed: isVisuallyCondensed,
            liveView: MeetingLiveViewAffordancePolicy.affordance(
                isRecording: state == .recording,
                isLiveMeetingSidecarEnabled: LiveMeetingCodexPreferences.isEnabled(),
                isTranscriptVisible: isTranscriptExpanded
            ),
            isTranscriptExpanded: isTranscriptExpanded
        )
    }

    private func pushAudioLevelsToView() {
        rootView?.updateAudioLevels(
            micLevel: currentMicLevel,
            systemLevel: currentSystemLevel
        )
    }

    private func resizePanelIfNeeded() {
        guard let panel, panel.isVisible else {
            lastRequestedPanelSize = nil
            return
        }
        let desired = NSSize(width: currentPanelWidth(), height: currentPanelHeight())

        // Compare against the last *requested* size, not the live frame: the
        // per-second duration tick lands mid-animation, and re-targeting the
        // same size against an intermediate frame restarts the animation and
        // makes the resize stutter.
        if let last = lastRequestedPanelSize,
           abs(last.width - desired.width) < 0.5,
           abs(last.height - desired.height) < 0.5 {
            return
        }
        lastRequestedPanelSize = desired

        // Keep the top edge and horizontal center fixed; both are invariant
        // across our resizes, so reading them mid-animation is safe.
        let frame = panel.frame
        let top = frame.origin.y + frame.height
        var target = NSRect(
            x: frame.midX - desired.width / 2,
            y: top - desired.height,
            width: desired.width,
            height: desired.height
        )

        // Never grow past the bottom or sides of the screen the panel is on.
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            target.origin.y = max(target.origin.y, visible.minY + 8)
            target.origin.x = min(
                max(target.origin.x, visible.minX + 8),
                visible.maxX - target.width - 8
            )
        }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.20
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().setFrame(target, display: true)
        }
    }
}
