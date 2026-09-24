// MenuBarHeaderView.swift
// Top status zone for the menubar popover.

import AppKit

struct MenuBarHeaderSmokeSnapshot: Codable, Equatable {
    let statusText: String
    let detailText: String
    let warningText: String
    let isReady: Bool
}

@MainActor
final class MenuBarHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "Transcripted")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "Ready")
    private let progressBar = NSProgressIndicator()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let warningIconView = NSImageView()
    private let warningLabel = NSTextField(wrappingLabelWithString: "")
    // Clear button over the warning row, so the warning is clickable and
    // reachable by keyboard and VoiceOver when it has a fix to open.
    private let warningButton = NSButton(title: "", target: nil, action: nil)

    /// Runs the warning's fix (open Accessibility or Keyboard settings).
    var onWarningAction: ((MenuBarShortcutWarningPresentation.Action) -> Void)?
    private var currentWarningAction: MenuBarShortcutWarningPresentation.Action?

    private var currentWarmupStatus: MeetingSessionController.ModelWarmupStatus = .ready
    private var currentHotkeyError: String?
    private var currentStatusTone: MenuBarHeaderStatusPresentation.Tone = .ready

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func setupViews() {
        titleLabel.font = MenuTokens.Font.headerTitle
        titleLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(titleLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MenuTokens.statusDotSize / 2
        addSubview(statusDot)

        statusLabel.font = MenuTokens.Font.headerStatus
        statusLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(statusLabel)

        progressBar.style = .bar
        progressBar.isIndeterminate = false
        progressBar.minValue = 0
        progressBar.maxValue = 1
        addSubview(progressBar)

        detailLabel.font = MenuTokens.Font.headerDetail
        detailLabel.textColor = MenuTokens.textSecondaryNS
        detailLabel.maximumNumberOfLines = 2
        addSubview(detailLabel)

        if let image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Warning") {
            warningIconView.image = image
            warningIconView.contentTintColor = MenuTokens.statusOrangeNS
        }
        addSubview(warningIconView)

        warningLabel.font = MenuTokens.Font.headerDetail
        warningLabel.textColor = MenuTokens.textSecondaryNS
        warningLabel.maximumNumberOfLines = 2
        addSubview(warningLabel)

        warningButton.isBordered = false
        warningButton.title = ""
        warningButton.target = self
        warningButton.action = #selector(handleWarningClicked)
        warningButton.isHidden = true
        addSubview(warningButton)
    }

    @objc private func handleWarningClicked() {
        guard let currentWarningAction else { return }
        onWarningAction?(currentWarningAction)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if !warningButton.isHidden {
            addCursorRect(warningButton.frame, cursor: .pointingHand)
        }
    }

    override func layout() {
        super.layout()

        let isReady = currentWarmupStatus.isReadyForMenuHeader
        let hasWarning = currentHotkeyError?.isEmpty == false

        if isReady && !hasWarning {
            let dotSize = MenuTokens.statusDotSize
            let labelWidth = statusLabel.intrinsicContentSize.width
            let statusWidth = dotSize + 6 + labelWidth
            let statusX = bounds.width - statusWidth
            titleLabel.frame = NSRect(x: 0, y: 0, width: max(120, statusX - 8), height: 20)
            statusDot.frame = NSRect(x: statusX, y: 7, width: dotSize, height: dotSize)
            statusLabel.frame = NSRect(x: statusDot.frame.maxX + 6, y: 3, width: labelWidth, height: 16)
        } else {
            titleLabel.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 20)
            let statusY: CGFloat = 22
            let dotSize = MenuTokens.statusDotSize
            statusDot.frame = NSRect(x: 0, y: statusY + 3, width: dotSize, height: dotSize)
            statusLabel.frame = NSRect(x: dotSize + 8, y: statusY, width: bounds.width - dotSize - 8, height: 14)
        }

        progressBar.isHidden = isReady
        detailLabel.isHidden = isReady
        if !isReady {
            progressBar.frame = NSRect(x: 0, y: 42, width: bounds.width, height: 8)
            detailLabel.frame = NSRect(x: 0, y: 54, width: bounds.width, height: 24)
        }

        warningIconView.isHidden = !hasWarning
        warningLabel.isHidden = !hasWarning
        warningButton.isHidden = !(hasWarning && currentWarningAction != nil)
        if hasWarning {
            let warningY = MenuBarHeaderLayoutPolicy.warningTop(isReady: isReady)
            warningIconView.frame = NSRect(x: 0, y: warningY + 1, width: 12, height: 12)
            warningLabel.frame = NSRect(
                x: 18,
                y: warningY - 1,
                width: bounds.width - 18,
                height: MenuBarHeaderLayoutPolicy.warningTextHeight
            )
            warningButton.frame = NSRect(
                x: 0,
                y: warningY - 1,
                width: bounds.width,
                height: MenuBarHeaderLayoutPolicy.warningTextHeight
            )
        }
        window?.invalidateCursorRects(for: self)
    }

    func update(
        warmupStatus: MeetingSessionController.ModelWarmupStatus,
        shortcutWarning: MenuBarShortcutWarningPresentation?,
        isMeetingRecording: Bool = false,
        transcribingStatus: String? = nil,
        capturePhase: MenuBarMeetingCapturePhase? = nil
    ) {
        currentWarmupStatus = warmupStatus
        currentHotkeyError = shortcutWarning?.text
        currentWarningAction = shortcutWarning?.action

        let isReady = warmupStatus.isReadyForMenuHeader
        let status = MenuBarHeaderStatusPresentation.resolve(
            isReady: isReady,
            isMeetingRecording: isMeetingRecording,
            warmupSubtitle: warmupStatus.subtitle,
            transcribingStatus: transcribingStatus,
            capturePhase: capturePhase
        )
        currentStatusTone = status.tone
        statusLabel.stringValue = status.text
        applyStatusDotColor()
        progressBar.doubleValue = warmupStatus.progress
        detailLabel.stringValue = isReady ? "" : warmupStatus.detail
        warningLabel.stringValue = shortcutWarning?.text ?? ""
        warningButton.setAccessibilityLabel(shortcutWarning?.text)
        warningButton.toolTip = shortcutWarning?.action == nil ? nil : shortcutWarning?.text

        needsLayout = true
        invalidateIntrinsicContentSize()
    }

    private func applyStatusDotColor() {
        let color: NSColor
        switch currentStatusTone {
        case .recording:
            color = MenuTokens.statusRedNS
        case .ready:
            color = MenuTokens.statusGreenNS
        case .working:
            color = MenuTokens.statusOrangeNS
        }
        statusDot.layer?.backgroundColor = menuResolvedCGColor(color)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStatusDotColor()
    }

    var intrinsicHeight: CGFloat {
        let isReady = currentWarmupStatus.isReadyForMenuHeader
        let hasWarning = currentHotkeyError?.isEmpty == false
        // A ready header shows its one-line status row for recording and
        // for a transcript being made (the working tone only occurs while
        // ready when transcribing); a plain "Ready" header stays hidden.
        return MenuBarHeaderLayoutPolicy.intrinsicHeight(
            isReady: isReady,
            hasWarning: hasWarning,
            isRecording: currentStatusTone != .ready
        )
    }

    var smokeSnapshot: MenuBarHeaderSmokeSnapshot {
        MenuBarHeaderSmokeSnapshot(
            statusText: statusLabel.stringValue,
            detailText: detailLabel.stringValue,
            warningText: warningLabel.stringValue,
            isReady: currentWarmupStatus.isReadyForMenuHeader
        )
    }
}
