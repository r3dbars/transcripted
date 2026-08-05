// MeetingOverlayRootView.swift
// AppKit root view and visual tokens used by the meeting overlay.

import AppKit
import Combine
import TranscriptedCore

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
    var onPrimaryAction: (() -> Void)?
    var onLiveViewAction: (() -> Void)?
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
        layer?.backgroundColor = AccessibilityDisplayPolicy.backdropColor(MeetingOverlayTokens.panelBg).cgColor
        layer?.borderWidth = 0.5
        layer?.borderColor = MeetingOverlayTokens.panelStroke.cgColor

        // Status dot for non-recording states. Recording uses the timer and
        // waveform; capture trouble is written out in plain language.
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

        statusDot.frame = .zero

        let timerSize = timerLabel.fittingSize
        timerLabel.frame = NSRect(
            x: tokens.padLeft,
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

        let recordingContentRight: CGFloat
        if titleLabel.isHidden {
            titleLabel.frame = .zero
            recordingContentRight = timerLabel.frame.maxX
        } else {
            let titleX = timerLabel.frame.maxX + tokens.headerGap
            let titleWidth = max(0, closeButton.frame.minX - tokens.headerGap - titleX)
            titleLabel.frame = NSRect(
                x: titleX,
                y: midY - titleLabel.fittingSize.height / 2,
                width: titleWidth,
                height: titleLabel.fittingSize.height
            )
            recordingContentRight = closeButton.frame.minX - tokens.headerGap
        }
        let barsLeft = recordingContentRight + tokens.headerGap
        let barsRight = closeButton.frame.minX - tokens.headerGap
        let availableBarsWidth = max(0, barsRight - barsLeft)
        let barsWidth = min(tokens.recordingWaveformWidth, availableBarsWidth)
        let barsHeight: CGFloat = 22
        let barsY = midY - barsHeight / 2
        audioWaveform.frame = titleLabel.isHidden
            ? NSRect(
                x: barsLeft + (availableBarsWidth - barsWidth) / 2,
                y: barsY,
                width: barsWidth,
                height: barsHeight
            )
            : .zero

        // The body covers the strip below the stop button so any click on
        // the pill itself toggles the transcript.
        pillBodyView.frame = NSRect(
            x: 0,
            y: bounds.height - tokens.panelHeight,
            width: bounds.width,
            height: tokens.panelHeight
        )

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

        // Keep the resting capsule calm and unambiguous: the elapsed timer is
        // the complete compact recording state. Route trouble remains readable
        // in the expanded system-audio prompt instead of becoming an unlabeled
        // triangle beside an unlabeled colored dot.
        let timerSize = timerLabel.fittingSize
        let startX = max(tokens.condensedPadLeft, (bounds.width - timerSize.width) / 2)

        statusDot.frame = .zero
        timerLabel.frame = NSRect(
            x: startX,
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
        let recordingContentRight = timerLabel.frame.maxX
        let barsLeft = recordingContentRight + tokens.headerGap
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
        let topY = bounds.height - 24

        statusDot.frame = NSRect(x: pad, y: topY - dotSize / 2, width: dotSize, height: dotSize)

        let timerSize = timerLabel.fittingSize
        timerLabel.frame = NSRect(
            x: bounds.width - pad - timerSize.width,
            y: topY - timerSize.height / 2,
            width: timerSize.width,
            height: timerSize.height
        )

        let titleX = statusDot.frame.maxX + 8
        let titleRight = timerLabel.frame.minX
        let titleWidth = max(0, titleRight - titleX - 8)
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(
            x: titleX,
            y: topY - titleSize.height / 2,
            width: min(titleWidth, titleSize.width),
            height: titleSize.height
        )

        detailLabel.frame = NSRect(
            x: pad,
            y: 55,
            width: bounds.width - pad * 2,
            height: 16
        )

        let secondaryWidth = max(68, closeButton.fittingSize.width + 18)
        let primaryWidth = max(74, recordButton.fittingSize.width + 18)
        let buttonHeight = MeetingOverlayTokens.promptButtonHeight
        let buttonGap: CGFloat = 8
        let totalButtonWidth = secondaryWidth + primaryWidth + buttonGap
        let buttonStartX = max(pad, bounds.width - pad - totalButtonWidth)

        closeButton.frame = NSRect(
            x: buttonStartX,
            y: 8,
            width: secondaryWidth,
            height: buttonHeight
        )
        recordButton.frame = NSRect(
            x: bounds.width - pad - primaryWidth,
            y: 8,
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

        let closeSize: CGFloat = 24
        closeButton.frame = NSRect(
            x: bounds.width - pad - closeSize,
            y: topY - closeSize / 2,
            width: closeSize,
            height: closeSize
        )

        let titleX = statusDot.frame.maxX + 8
        let titleWidth = max(0, closeButton.frame.minX - titleX - 8)
        let titleSize = titleLabel.fittingSize
        titleLabel.frame = NSRect(
            x: titleX,
            y: topY - titleSize.height / 2,
            width: min(titleWidth, titleSize.width),
            height: titleSize.height
        )

        detailLabel.maximumNumberOfLines = 2
        detailLabel.frame = NSRect(
            x: pad,
            y: 10,
            width: bounds.width - pad * 2,
            height: 36
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
        systemAudioWarning: MeetingSystemAudioDegradationWarning?,
        isCondensed: Bool,
        liveView: MeetingLiveViewAffordancePolicy.Affordance?,
        isTranscriptExpanded: Bool
    ) {
        currentState = state
        currentLiveViewAffordance = liveView
        self.isTranscriptExpanded = state == .recording && !isCondensed && isTranscriptExpanded
        let wasCondensed = self.isCondensed
        self.isCondensed = state == .recording && isCondensed && systemAudioWarning == nil
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
        statusDot.isHidden = isPreparing || state == .recording
        titleLabel.isHidden = isPreparing || (state == .recording && systemAudioWarning == nil)
        timerLabel.isHidden = isPreparing || (state != .recording && !isPrompting)
        detailLabel.isHidden = !(isPrompting || isErrorState)
        micLabel.isHidden = true
        systemLabel.isHidden = true
        recordButton.isHidden = !isPrompting
        if state == .recording {
            applyStripContentFade(wasCondensed: wasCondensed)
        } else {
            audioWaveform.isHidden = true
            audioWaveform.alphaValue = 1
            closeButton.isHidden = isPreparing || !(isPrompting || isErrorState)
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
            setStatusDotPulsing(false)
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
            detailLabel.lineBreakMode = .byTruncatingTail
            detailLabel.maximumNumberOfLines = 1
            timerLabel.stringValue = prompt?.countdownText ?? ""
            updateStatusDot(color: MeetingOverlayTokens.dotPrompt)
            closeButton.attributedTitle = buttonTitle(prompt?.secondaryTitle ?? "Not now", size: 11, weight: .semibold)
            closeButton.image = nil
            closeButton.imagePosition = .noImage
            closeButton.toolTip = nil
            closeButton.setAccessibilityLabel(prompt?.secondaryAccessibilityLabel ?? dismissPromptTooltip)
            closeButton.setAccessibilityHelp("Dismisses this meeting recording prompt.")
            closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            recordButton.attributedTitle = primaryButtonTitle(prompt?.primaryTitle ?? "Record")
            recordButton.setAccessibilityLabel(prompt?.primaryAccessibilityLabel ?? startTooltip)
        case .recording:
            titleLabel.stringValue = systemAudioWarning.map {
                MeetingSystemAudioDegradationCopy.title(for: $0)
            } ?? "Recording meeting"
            titleLabel.toolTip = systemAudioWarning.map {
                MeetingSystemAudioDegradationCopy.accessibilityLabel(for: $0)
            }
            updateStatusDot(
                color: systemAudioWarning == nil
                    ? MeetingOverlayTokens.dotRecording
                    : MeetingOverlayTokens.dotPrompt,
                haloOpacity: 0.24,
                haloRadius: 3
            )
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
            titleLabel.stringValue = "Transcribing meeting…"
            updateStatusDot(color: MeetingOverlayTokens.dotPrep, haloOpacity: 0.22, haloRadius: 3)
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
            closeButton.attributedTitle = buttonTitle("Dismiss", size: 11, weight: .semibold)
            closeButton.image = nil
            closeButton.imagePosition = .noImage
            closeButton.toolTip = nil
            closeButton.setAccessibilityLabel("Dismiss meeting failure")
            closeButton.setAccessibilityHelp("Hides this meeting failure notice. Recovery remains available from Home.")
            closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.10).cgColor
            closeButton.layer?.cornerRadius = 8
            closeButton.layer?.borderWidth = 0
            updateStatusDot(
                color: failureKind == .recordingTooShort
                    ? MeetingOverlayTokens.dotIdle
                    : MeetingOverlayTokens.dotError
            )
            detailLabel.stringValue = copy.detail
            detailLabel.lineBreakMode = .byWordWrapping
            detailLabel.maximumNumberOfLines = 2
            closeButton.attributedTitle = buttonTitle("", size: 12, weight: .semibold)
            closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
            closeButton.imagePosition = .imageOnly
            closeButton.contentTintColor = MeetingOverlayTokens.textSecondary
            closeButton.setAccessibilityLabel("Dismiss meeting error")
            closeButton.setAccessibilityHelp("Keeps the failed meeting available on Home.")
            closeButton.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.08).cgColor
            closeButton.layer?.cornerRadius = 12
            closeButton.layer?.borderWidth = 0
        }

        // Transcription has no progress channel to drive a bar, so pulse the
        // status dot while it runs. Without this the pill reads as finished
        // ("Saved to Markdown" lookalike) or frozen during the long
        // transcribe + diarize step that follows stopping a recording.
        setStatusDotPulsing(state == .transcribing)

        if state == .recording {
            timerLabel.stringValue = formatDuration(duration)
        }
        currentMicLevel = max(0, min(1, micLevel))
        currentSystemLevel = max(0, min(1, systemLevel))
        audioWaveform.primaryLevel = currentMicLevel
        audioWaveform.secondaryLevel = currentSystemLevel
        if state == .recording, systemAudioWarning != nil {
            audioWaveform.isHidden = true
        }
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
            ctx.duration = AccessibilityDisplayPolicy.motionDuration(fadeOut ? 0.12 : 0.18)
            ctx.timingFunction = CAMediaTimingFunction(name: fadeOut ? .easeIn : .easeOut)
            for view in fadeViews {
                view.animator().alphaValue = fadeOut ? 0 : 1
            }
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.isCondensed == fadeOut else { return }
                if fadeOut {
                    self.audioWaveform.isHidden = true
                    self.closeButton.isHidden = true
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
        finals: [LiveMeetingTranscriptEntry],
        partials: [LiveMeetingTranscriptSource: LiveMeetingTranscriptEntry],
        statusText: String?,
        hasEntries: Bool
    ) {
        transcriptDrawer.update(
            finals: finals,
            partials: partials,
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
                ctx.duration = AccessibilityDisplayPolicy.motionDuration(0.18)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                transcriptDrawer.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = AccessibilityDisplayPolicy.motionDuration(0.12)
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                transcriptDrawer.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self, !self.isDrawerVisible else { return }
                    self.transcriptDrawer.isHidden = true
                }
            })
        }
    }

    private func applyBaseVisualStyle() {
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = MeetingOverlayTokens.textPrimary
        titleLabel.toolTip = nil
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

    /// Gently breathes the status dot's opacity so an in-progress state with
    /// no determinate progress (transcription) never looks frozen. Idempotent:
    /// `update(...)` runs on every duration tick, so re-adding the same
    /// animation is skipped while it's already attached.
    private func setStatusDotPulsing(_ pulsing: Bool) {
        let key = "transcribingPulse"
        guard let layer = statusDot.layer else { return }
        // Reduce Motion: keep the dot at full opacity instead of breathing.
        if pulsing && !AccessibilityDisplayPolicy.reduceMotion {
            guard layer.animation(forKey: key) == nil else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.35
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(pulse, forKey: key)
        } else {
            layer.removeAnimation(forKey: key)
            layer.opacity = 1
        }
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
        MeetingDurationFormatter.formatDuration(seconds)
    }

    // Clicking a tracked button while its tooltip is up would otherwise
    // leave the old tooltip text floating over the new state.
    @objc private func handleSecondaryAction() {
        hideTooltip()
        onSecondaryAction?()
    }

    @objc private func handlePrimaryAction() {
        hideTooltip()
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
    static let promptButtonHeight: CGFloat = 40
    static let promptHeight: CGFloat = 106
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
    static let drawerActionButtonSize: CGFloat = 40
    static let drawerResizeHandleHeight: CGFloat = 40
    static let stopHeight: CGFloat  = 40
    static let recordingWaveformWidth: CGFloat = 124
    static let tooltipOffset: CGFloat = 8
    static let tooltipScreenInset: CGFloat = 6
    static let tooltipDelayNanoseconds: UInt64 = 80_000_000
    static let missedCallNudgeTimeoutSeconds = 30
}
