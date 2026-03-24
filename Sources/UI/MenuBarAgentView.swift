// MenuBarAgentView.swift
// Agent section: insight cards with Apply/Skip actions

import AppKit

@MainActor
final class MenuBarAgentView: NSView {
    private let headerLabel = NSTextField(labelWithString: "Agent")
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var cardViews: [NSView] = []

    /// Reference to the analysis engine for applying/skipping cards
    weak var analysisEngine: AnalysisEngine?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func setupViews() {
        headerLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        headerLabel.textColor = MenuTokens.textPrimaryNS
        addSubview(headerLabel)

        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = MenuTokens.statusDotSize / 2
        statusDot.layer?.backgroundColor = MenuTokens.statusGreenNS.cgColor
        addSubview(statusDot)

        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = MenuTokens.textSecondaryNS
        addSubview(statusLabel)

        spinner.style = .spinning
        spinner.controlSize = .mini
        spinner.isIndeterminate = true
        spinner.isHidden = true
        addSubview(spinner)
    }

    override func layout() {
        super.layout()
        let headerH: CGFloat = 20
        let headerSize = headerLabel.fittingSize
        headerLabel.frame = NSRect(x: 0, y: bounds.height - headerH, width: headerSize.width, height: headerH)

        // Status on the right
        let statusSize = statusLabel.fittingSize
        let dotSize = MenuTokens.statusDotSize
        if !spinner.isHidden {
            let spinSize: CGFloat = 12
            spinner.frame = NSRect(x: bounds.width - statusSize.width - spinSize - 6, y: bounds.height - headerH + (headerH - spinSize) / 2, width: spinSize, height: spinSize)
            statusLabel.frame = NSRect(x: bounds.width - statusSize.width, y: bounds.height - headerH + (headerH - statusSize.height) / 2, width: statusSize.width, height: statusSize.height)
        } else {
            statusDot.frame = NSRect(x: bounds.width - statusSize.width - dotSize - 6, y: bounds.height - headerH + (headerH - dotSize) / 2, width: dotSize, height: dotSize)
            statusLabel.frame = NSRect(x: bounds.width - statusSize.width, y: bounds.height - headerH + (headerH - statusSize.height) / 2, width: statusSize.width, height: statusSize.height)
        }

        // Card views below header
        var y = bounds.height - headerH - 12
        for cardView in cardViews {
            let cardH: CGFloat = 90
            y -= cardH
            cardView.frame = NSRect(x: 0, y: max(0, y), width: bounds.width, height: cardH)
            y -= 8
        }
    }

    func update(insights: [InsightCard], isAnalyzing: Bool, agentStatus: String) {
        // Update header status
        if isAnalyzing {
            spinner.isHidden = false
            spinner.startAnimation(nil)
            statusDot.isHidden = true
            statusLabel.stringValue = "Analyzing..."
        } else {
            spinner.isHidden = true
            spinner.stopAnimation(nil)
            statusDot.isHidden = false
            statusLabel.stringValue = agentStatus
        }

        // Rebuild card views for pending cards
        let pending = insights.filter { $0.status == .pending }

        // Remove old cards
        for view in cardViews { view.removeFromSuperview() }
        cardViews.removeAll()

        // Create new cards
        for card in pending {
            let cardView = createCardView(card)
            addSubview(cardView)
            cardViews.append(cardView)
        }

        needsLayout = true
    }

    private func createCardView(_ card: InsightCard) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerRadius = MenuTokens.cardCornerRadius
        view.layer?.backgroundColor = MenuTokens.cardBackgroundNS.cgColor
        view.layer?.borderColor = MenuTokens.cardBorderNS.cgColor
        view.layer?.borderWidth = 1

        let pad = MenuTokens.cardPadding

        let keyLabel = NSTextField(labelWithString: card.promptKeyLabel)
        keyLabel.font = NSFont.systemFont(ofSize: 11)
        keyLabel.textColor = MenuTokens.textSecondaryNS
        keyLabel.frame = NSRect(x: pad, y: 90 - pad - 14, width: 300, height: 14)
        view.addSubview(keyLabel)

        let descLabel = NSTextField(wrappingLabelWithString: card.changeDescription)
        descLabel.font = NSFont.systemFont(ofSize: 13)
        descLabel.textColor = MenuTokens.textPrimaryNS
        descLabel.maximumNumberOfLines = 2
        descLabel.frame = NSRect(x: pad, y: 30, width: 300, height: 30)
        view.addSubview(descLabel)

        // Defensive: capture card ID, do live lookup on button tap
        let cardId = card.id

        let skipButton = NSButton(title: "Skip", target: nil, action: nil)
        skipButton.bezelStyle = .inline
        skipButton.isBordered = false
        skipButton.font = NSFont.systemFont(ofSize: 11)
        skipButton.contentTintColor = MenuTokens.textSecondaryNS
        skipButton.frame = NSRect(x: 300 - 80, y: pad, width: 40, height: 20)
        skipButton.target = self
        skipButton.tag = cardId.hashValue
        skipButton.action = #selector(skipTapped(_:))
        view.addSubview(skipButton)

        let applyButton = NSButton(title: "Apply", target: nil, action: nil)
        applyButton.bezelStyle = .rounded
        applyButton.font = NSFont.systemFont(ofSize: 11)
        applyButton.frame = NSRect(x: 300 - 30, y: pad, width: 50, height: 22)
        applyButton.target = self
        applyButton.tag = cardId.hashValue
        applyButton.action = #selector(applyTapped(_:))
        view.addSubview(applyButton)

        // Store card ID on the view for lookup
        view.identifier = NSUserInterfaceItemIdentifier(cardId.uuidString)

        return view
    }

    @objc private func skipTapped(_ sender: NSButton) {
        guard let engine = analysisEngine,
              let cardView = sender.superview,
              let idString = cardView.identifier?.rawValue,
              let cardId = UUID(uuidString: idString),
              let live = engine.insights.first(where: { $0.id == cardId }) else { return }
        engine.skip(live)
    }

    @objc private func applyTapped(_ sender: NSButton) {
        guard let engine = analysisEngine,
              let cardView = sender.superview,
              let idString = cardView.identifier?.rawValue,
              let cardId = UUID(uuidString: idString),
              let live = engine.insights.first(where: { $0.id == cardId }) else { return }
        engine.apply(live)
    }

    var intrinsicHeight: CGFloat {
        var h: CGFloat = 20 + 12 // header + gap
        h += CGFloat(cardViews.count) * (90 + 8)
        return max(h, 32)
    }
}
