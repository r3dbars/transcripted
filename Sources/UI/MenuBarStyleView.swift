// MenuBarStyleView.swift
// Writing style section: header with example count, expandable style card

import AppKit

@MainActor
final class MenuBarStyleView: NSView {
    private let headerLabel = NSTextField(labelWithString: "Your Style")
    private let phaseLabel = NSTextField(labelWithString: "")

    // Style match card
    private let matchCard = NSView()
    private let matchTitle = NSTextField(labelWithString: "Style Match")
    private let matchPercent = NSTextField(labelWithString: "")
    private let matchBar = NSProgressIndicator()
    private let matchDetail = NSTextField(labelWithString: "")

    // Style content card
    private let styleCard = NSView()
    private let styleText = NSTextField(wrappingLabelWithString: "")
    private let toggleButton = NSButton(title: "Show more", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "Accept a draft to start learning your style")

    private var isExpanded = false
    private var exampleCount = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        // Section header
        headerLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        headerLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(headerLabel)

        phaseLabel.font = NSFont.systemFont(ofSize: 11)
        phaseLabel.textColor = MenuTokens.textSecondaryNS
        phaseLabel.alignment = .right
        addSubview(phaseLabel)

        // Style match card
        matchCard.wantsLayer = true
        matchCard.layer?.cornerRadius = MenuTokens.cardCornerRadius
        matchCard.layer?.backgroundColor = MenuTokens.cardBackgroundNS.cgColor
        matchCard.layer?.borderColor = MenuTokens.cardBorderNS.cgColor
        matchCard.layer?.borderWidth = 1
        matchCard.isHidden = true
        addSubview(matchCard)

        matchTitle.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        matchTitle.textColor = MenuTokens.textPrimaryNS
        matchCard.addSubview(matchTitle)

        matchPercent.font = NSFont.systemFont(ofSize: 13, weight: .bold)
        matchPercent.alignment = .right
        matchCard.addSubview(matchPercent)

        matchBar.style = .bar
        matchBar.isIndeterminate = false
        matchBar.minValue = 0
        matchBar.maxValue = 100
        matchCard.addSubview(matchBar)

        matchDetail.font = NSFont.systemFont(ofSize: 10)
        matchDetail.textColor = MenuTokens.textMutedNS
        matchCard.addSubview(matchDetail)

        // Style card
        styleCard.wantsLayer = true
        styleCard.layer?.cornerRadius = MenuTokens.cardCornerRadius
        styleCard.layer?.backgroundColor = MenuTokens.cardBackgroundNS.cgColor
        styleCard.layer?.borderColor = MenuTokens.cardBorderNS.cgColor
        styleCard.layer?.borderWidth = 1
        addSubview(styleCard)

        styleText.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        styleText.textColor = MenuTokens.textSecondaryNS
        styleText.maximumNumberOfLines = MenuTokens.compactStyleLines
        styleText.lineBreakMode = .byTruncatingTail
        styleText.isSelectable = true
        styleCard.addSubview(styleText)

        toggleButton.bezelStyle = .inline
        toggleButton.isBordered = false
        toggleButton.font = NSFont.systemFont(ofSize: 11)
        toggleButton.contentTintColor = MenuTokens.textSecondaryNS
        toggleButton.target = self
        toggleButton.action = #selector(toggleExpand)
        styleCard.addSubview(toggleButton)

        emptyLabel.font = NSFont.systemFont(ofSize: 13)
        emptyLabel.textColor = MenuTokens.textMutedNS
        emptyLabel.isHidden = true
        styleCard.addSubview(emptyLabel)
    }

    override func layout() {
        super.layout()
        let pad = MenuTokens.cardPadding
        var y = bounds.height

        // Header row
        let headerH: CGFloat = 20
        y -= headerH
        headerLabel.frame = NSRect(x: 0, y: y, width: bounds.width / 2, height: headerH)
        phaseLabel.frame = NSRect(x: bounds.width / 2, y: y, width: bounds.width / 2, height: headerH)

        // Match card (if visible)
        if !matchCard.isHidden {
            y -= 10
            let matchH: CGFloat = 70
            y -= matchH
            matchCard.frame = NSRect(x: 0, y: y, width: bounds.width, height: matchH)

            matchTitle.frame = NSRect(x: pad, y: matchH - pad - 16, width: matchH, height: 16)
            matchPercent.frame = NSRect(x: bounds.width - pad - 50, y: matchH - pad - 16, width: 50, height: 16)
            matchBar.frame = NSRect(x: pad, y: matchH - pad - 16 - 18, width: bounds.width - pad * 2, height: 10)
            matchDetail.frame = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: 14)
        }

        // Style card
        y -= 10
        let styleH = computeStyleCardHeight()
        y -= styleH
        styleCard.frame = NSRect(x: 0, y: max(0, y), width: bounds.width, height: styleH)

        if exampleCount == 0 {
            emptyLabel.frame = NSRect(x: pad, y: (styleH - 20) / 2, width: bounds.width - pad * 2, height: 20)
        } else {
            let toggleH: CGFloat = 20
            let textH = styleH - pad * 2 - toggleH - 6
            styleText.frame = NSRect(x: pad, y: pad + toggleH + 6, width: bounds.width - pad * 2, height: max(0, textH))
            toggleButton.frame = NSRect(x: bounds.width - pad - 80, y: pad, width: 80, height: toggleH)
        }
    }

    private func computeStyleCardHeight() -> CGFloat {
        if exampleCount == 0 { return 44 }
        let textHeight: CGFloat = isExpanded ? 180 : 60
        return MenuTokens.cardPadding * 2 + textHeight + 26
    }

    @objc private func toggleExpand() {
        isExpanded.toggle()
        styleText.maximumNumberOfLines = isExpanded ? 0 : MenuTokens.compactStyleLines
        toggleButton.title = isExpanded ? "Show less" : "Show more"
        needsLayout = true
        // Notify parent to relayout
        superview?.needsLayout = true
    }

    func update(styleContents: String, exampleCount: Int, trainingPhase: String,
                styleMatchScore: Int) {
        self.exampleCount = exampleCount
        phaseLabel.stringValue = trainingPhase

        // Style match card
        if exampleCount > 0 {
            matchCard.isHidden = false
            matchPercent.stringValue = "\(styleMatchScore)%"
            matchPercent.textColor = styleMatchScore >= 75 ? MenuTokens.statusGreenNS : MenuTokens.statusOrangeNS
            matchBar.doubleValue = Double(styleMatchScore)
            matchDetail.stringValue = "Based on your last \(min(exampleCount, DraftConstants.refinementDistanceWindow)) edits"
        } else {
            matchCard.isHidden = true
        }

        // Style card
        if exampleCount == 0 {
            emptyLabel.isHidden = false
            styleText.isHidden = true
            toggleButton.isHidden = true
        } else {
            emptyLabel.isHidden = true
            styleText.isHidden = false
            toggleButton.isHidden = false
            styleText.stringValue = computeStylePreview(styleContents)
        }

        needsLayout = true
    }

    private func computeStylePreview(_ contents: String) -> String {
        if isExpanded { return contents }
        if let range = contents.range(of: "## Style Summary") {
            let afterHeader = contents[range.upperBound...]
            let lines = afterHeader.split(separator: "\n", omittingEmptySubsequences: false)
            let meaningful = lines.drop(while: { $0.trimmingCharacters(in: .whitespaces).isEmpty })
            return meaningful.prefix(6).joined(separator: "\n")
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.prefix(4).joined(separator: "\n")
    }

    var intrinsicHeight: CGFloat {
        var h: CGFloat = 20 + 10 // header + gap
        if !matchCard.isHidden { h += 70 + 10 }
        h += computeStyleCardHeight()
        return h
    }
}
