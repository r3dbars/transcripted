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
    private let cancelButton = NSButton()
    private let closeButton = NSButton()
    private let chevronButton = NSButton()
    private let warmupTitleLabel = NSTextField(labelWithString: "Getting Transcripted ready")
    private let warmupSubtitleLabel = NSTextField(labelWithString: "Loading dictation and meeting models")
    private let warmupProgress = NSProgressIndicator()
    private var currentState: MeetingOverlayController.OverlayState = .idle
    private var currentWarmupStatus: MeetingSessionController.ModelWarmupStatus = .ready
    private let cancelTooltip = "Cancel meeting recording"
    private let finishTooltip = "Finish and transcribe"
    private let dismissPromptTooltip = "Dismiss meeting prompt"
    private let startTooltip = "Start meeting recording"
    private var tooltipPanel: MeetingOverlayTooltipPanel?
    private var tooltipTask: Task<Void, Never>?
    private var tooltipTrackingAreas: [NSTrackingArea] = []

    /// Invoked when the user clicks the close/stop button.
    var onSecondaryAction: (() -> Void)?
    var onCancelAction: (() -> Void)?
    var onPrimaryAction: (() -> Void)?

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

        cancelButton.isBordered = false
        cancelButton.wantsLayer = true
        cancelButton.layer?.cornerRadius = MeetingOverlayTokens.cancelHeight / 2
        cancelButton.layer?.backgroundColor = MeetingOverlayTokens.quietActionBg.cgColor
        cancelButton.layer?.borderWidth = 0.5
        cancelButton.layer?.borderColor = MeetingOverlayTokens.quietActionBorder.cgColor
        cancelButton.imageScaling = .scaleProportionallyDown
        cancelButton.image = cancelButtonImage()
        cancelButton.imagePosition = .imageOnly
        cancelButton.contentTintColor = MeetingOverlayTokens.quietActionTint
        cancelButton.toolTip = nil
        cancelButton.setAccessibilityLabel(cancelTooltip)
        cancelButton.setAccessibilityHelp("Shows a confirmation before discarding this meeting recording.")
        cancelButton.target = self
        cancelButton.action = #selector(handleCancelAction)
        cancelButton.isHidden = true
        addSubview(cancelButton)

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
        let midY = bounds.height / 2

        cancelButton.frame = NSRect(
            x: tokens.padLeft,
            y: midY - tokens.cancelHeight / 2,
            width: tokens.cancelHeight,
            height: tokens.cancelHeight
        )

        statusDot.frame = NSRect(
            x: cancelButton.frame.maxX + tokens.headerGap,
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
            x: barsLeft,
            y: barsY,
            width: barsWidth,
            height: barsHeight
        )

        titleLabel.frame = .zero
        detailLabel.frame = .zero
        micLabel.frame = .zero
        systemLabel.frame = .zero
        chevronButton.frame = .zero
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

        let secondaryWidth = max(62, closeButton.fittingSize.width + 18)
        let primaryWidth = max(74, recordButton.fittingSize.width + 18)
        let buttonHeight: CGFloat = 24

        closeButton.frame = NSRect(
            x: bounds.width - pad - secondaryWidth - primaryWidth - 8,
            y: 10,
            width: secondaryWidth,
            height: buttonHeight
        )
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
        prompt: MeetingOverlayController.PromptDisplay?
    ) {
        currentState = state
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
        audioWaveform.isHidden = isPreparing || isPrompting
        let showLevels = state == .recording
        audioWaveform.isHidden = !showLevels
        recordButton.isHidden = !isPrompting
        cancelButton.isHidden = state != .recording
        closeButton.isHidden = isPreparing || (state != .recording && !isPrompting)
        chevronButton.isHidden = true
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
            closeButton.attributedTitle = buttonTitle("Not now", size: 11, weight: .semibold)
            closeButton.toolTip = nil
            closeButton.setAccessibilityLabel(dismissPromptTooltip)
            closeButton.setAccessibilityHelp("Dismisses this meeting recording prompt.")
            closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
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
            closeButton.layer?.backgroundColor = MeetingOverlayTokens.finishActionColor.cgColor
            closeButton.layer?.cornerRadius = MeetingOverlayTokens.stopHeight / 2
            closeButton.layer?.borderWidth = 0.5
            closeButton.layer?.borderColor = MeetingOverlayTokens.finishActionBorder.cgColor
        case .transcribing:
            titleLabel.stringValue = "Saving transcript"
            updateStatusDot(color: MeetingOverlayTokens.dotPrep)
            detailLabel.stringValue = ""
        case .saved:
            titleLabel.stringValue = "Saved transcript"
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
        let shouldAnimate = state == .recording
        audioWaveform.isActive = shouldAnimate

        needsLayout = true
    }

    func updateAudioLevels(micLevel: Float, systemLevel: Float) {
        currentMicLevel = max(0, min(1, micLevel))
        currentSystemLevel = max(0, min(1, systemLevel))
        audioWaveform.primaryLevel = currentMicLevel
        audioWaveform.secondaryLevel = currentSystemLevel
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
        cancelButton.image = cancelButtonImage()
        cancelButton.imagePosition = .imageOnly
        cancelButton.contentTintColor = MeetingOverlayTokens.quietActionTint
        cancelButton.toolTip = nil
        cancelButton.setAccessibilityLabel(cancelTooltip)
        cancelButton.setAccessibilityHelp("Shows a confirmation before discarding this meeting recording.")
        cancelButton.layer?.cornerRadius = MeetingOverlayTokens.cancelHeight / 2
        cancelButton.layer?.backgroundColor = MeetingOverlayTokens.quietActionBg.cgColor
        cancelButton.layer?.borderWidth = 0.5
        cancelButton.layer?.borderColor = MeetingOverlayTokens.quietActionBorder.cgColor
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

    private func cancelButtonImage() -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        return NSImage(systemSymbolName: "xmark", accessibilityDescription: cancelTooltip)?
            .withSymbolConfiguration(config)
    }

    private func refreshTooltipTrackingAreas() {
        for area in tooltipTrackingAreas {
            removeTrackingArea(area)
        }
        tooltipTrackingAreas.removeAll()

        addTooltipTrackingArea(for: cancelButton, text: cancelTooltip)
        addTooltipTrackingArea(for: closeButton, text: currentState == .recording ? finishTooltip : dismissPromptTooltip)
        addTooltipTrackingArea(for: recordButton, text: startTooltip)

        if tooltipTrackingAreas.isEmpty {
            hideTooltip()
        }
    }

    private func addTooltipTrackingArea(for view: NSView, text: String) {
        guard !view.isHidden, view.frame.width > 0, view.frame.height > 0 else { return }
        let area = NSTrackingArea(
            rect: view.frame,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: ["tooltipText": text, "anchorView": view]
        )
        tooltipTrackingAreas.append(area)
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        guard
            let text = event.trackingArea?.userInfo?["tooltipText"] as? String,
            let anchorView = event.trackingArea?.userInfo?["anchorView"] as? NSView
        else { return }
        scheduleTooltip(text, anchoredTo: anchorView)
    }

    override func mouseExited(with event: NSEvent) {
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

    @objc private func handleSecondaryAction() {
        onSecondaryAction?()
    }

    @objc private func handleCancelAction() {
        onCancelAction?()
    }

    @objc private func handlePrimaryAction() {
        onPrimaryAction?()
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
    static let finishActionColor = NSColor.white.withAlphaComponent(0.16)
    static let finishActionBorder = NSColor.white.withAlphaComponent(0.24)
    static let finishActionForeground = NSColor.white.withAlphaComponent(0.92)

    static let panelWidth: CGFloat  = 360
    static let recordingPanelWidth: CGFloat = 292
    static let panelHeight: CGFloat = 44
    static let promptHeight: CGFloat = 88
    static let warmupHeight: CGFloat = 96
    static let errorHeight: CGFloat = 72
    static let cornerRadius: CGFloat = 22
    static let dotSize: CGFloat     = 8
    static let padLeft: CGFloat     = 12
    static let padRight: CGFloat    = 8
    static let headerGap: CGFloat   = 8
    static let timerFontSize: CGFloat = 13
    static let cancelHeight: CGFloat = 24
    static let stopHeight: CGFloat  = 28
    static let recordingWaveformWidth: CGFloat = 124
    static let tooltipOffset: CGFloat = 8
    static let tooltipScreenInset: CGFloat = 6
    static let tooltipDelayNanoseconds: UInt64 = 80_000_000
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
final class MeetingOverlayController {

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
    private var promptCountdownTask: Task<Void, Never>?
    private var promptSecondsRemaining = 0

    // MARK: - Panel & views

    private var panel: MeetingOverlayPanel?
    private var rootView: MeetingOverlayRootView?
    private var subscriptions: Set<AnyCancellable> = []
    private var autoHideTask: Task<Void, Never>?
    private var isShowingCancelConfirmation = false

    deinit {
        autoHideTask?.cancel()
        promptCountdownTask?.cancel()
    }

    // MARK: - Dependencies

    /// The session controller the overlay reflects and forwards hotkey events to.
    /// Set once by `TranscriptedAppDelegate` during app launch.
    weak var meetingSession: MeetingSessionController?
    var onPromptRecord: ((MeetingPromptDetector.Candidate) -> Void)?
    var onPromptDismiss: ((MeetingPromptDetector.Candidate) -> Void)?

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
        rootView.onCancelAction = { [weak self] in self?.handleCancelTapped() }
        rootView.onPrimaryAction = { [weak self] in self?.handlePrimaryActionTapped() }
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
    func presentDetectedMeetingPrompt(_ candidate: MeetingPromptDetector.Candidate, timeout seconds: Int = 10) -> Bool {
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
        promptSecondsRemaining = max(1, seconds)
        currentPrompt = PromptDisplay(
            title: candidate.title,
            detail: candidate.detail,
            countdownText: "\(promptSecondsRemaining)s"
        )
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

    }

    private func applySessionState(_ sessionState: MeetingSessionController.State) {
        switch sessionState {
        case .idle:
            if state == .prompt {
                pushToView()
                break
            }
            state = .idle
            hidePanel()
        case .loadingModels:
            state = .preparing
            currentPrompt = nil
            promptCandidate = nil
            promptCountdownTask?.cancel()
            showPanel()
        case .ready:
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
            state = .recording
            currentPrompt = nil
            promptCandidate = nil
            promptCountdownTask?.cancel()
            autoHideTask?.cancel()
            showPanel()
        case .transcribing:
            state = .transcribing
            currentPrompt = nil
            promptCandidate = nil
            promptCountdownTask?.cancel()
            showPanel()
        case .error(let message):
            state = .error(message)
            currentPrompt = nil
            promptCandidate = nil
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
        case .error:
            return MeetingOverlayTokens.errorHeight
        default:
            return MeetingOverlayTokens.panelHeight
        }
    }

    private func currentPanelWidth() -> CGFloat {
        switch state {
        case .recording:
            return MeetingOverlayTokens.recordingPanelWidth
        default:
            return MeetingOverlayTokens.panelWidth
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

    private func handleCancelTapped() {
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
            dismissPrompt(notifyDetector: true)
        case .recording:
            handleCloseTapped()
        default:
            hidePanel()
        }
    }

    private func handlePrimaryActionTapped() {
        guard case .prompt = state, let candidate = promptCandidate else { return }
        promptCountdownTask?.cancel()
        onPromptRecord?(candidate)
    }

    private func dismissPrompt(notifyDetector: Bool) {
        promptCountdownTask?.cancel()

        if notifyDetector, let candidate = promptCandidate {
            onPromptDismiss?(candidate)
        }

        promptCandidate = nil
        currentPrompt = nil
        state = .idle
        hidePanel()
    }

    private func schedulePromptCountdown() {
        promptCountdownTask?.cancel()
        promptCountdownTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while self.promptSecondsRemaining > 0 {
                self.currentPrompt = PromptDisplay(
                    title: self.promptCandidate?.title ?? "Meeting detected",
                    detail: self.promptCandidate?.detail ?? "Record this meeting?",
                    countdownText: "\(self.promptSecondsRemaining)s"
                )
                self.pushToView()

                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.promptSecondsRemaining -= 1
            }

            self.dismissPrompt(notifyDetector: true)
        }
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
            prompt: currentPrompt
        )
    }

    private func pushAudioLevelsToView() {
        rootView?.updateAudioLevels(
            micLevel: currentMicLevel,
            systemLevel: currentSystemLevel
        )
    }

    private func resizePanelIfNeeded() {
        guard let panel, panel.isVisible else { return }
        let desiredHeight = currentPanelHeight()
        let desiredWidth = currentPanelWidth()
        let heightChanged = abs(panel.frame.height - desiredHeight) > 0.5
        let widthChanged = abs(panel.frame.width - desiredWidth) > 0.5
        guard heightChanged || widthChanged else { return }

        var frame = panel.frame
        frame.origin.y += frame.height - desiredHeight
        frame.origin.x += (frame.width - desiredWidth) / 2
        frame.size.height = desiredHeight
        frame.size.width = desiredWidth
        panel.setFrame(frame, display: true, animate: true)
    }
}
