// NotchIslandButton.swift
// The island's pill buttons: plain, accent, warning and destructive, with an
// optional countdown ring. Split out of NotchIslandView.swift.

import AppKit

final class NotchIslandButton: NSButton {
    enum Style {
        case plain
        case subtle
        case accent
        case destructive
        case warning
        case link
    }

    var onPress: (() -> Void)?
    private let style: Style
    private var countdownSeconds: Double?
    private var countdownStarted = false
    private var countdownPaused = false
    private let ringTrack = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let buttonHeight: CGFloat
    private let horizontalPadding: CGFloat

    /// The app icon's side in a button `height` tall.
    static func appIconSide(forHeight height: CGFloat = 32) -> CGFloat {
        (height * 0.6).rounded()
    }

    /// `appIcon` puts a small app icon before the title, drawn in its own
    /// colors ("Insert into Slack").
    init(title: String, style: Style, height: CGFloat = 32, fontSize: CGFloat = 13, symbolName: String? = nil, appIcon: NSImage? = nil) {
        self.style = style
        self.buttonHeight = height
        self.horizontalPadding = style == .link ? 4 : (height < 26 ? 9 : 14)
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        let weight: NSFont.Weight = (style == .accent || style == .destructive || height < 26) ? .bold : .semibold
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: foreground]
        )
        if let symbolName,
           let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: fontSize - 2, weight: .bold)) {
            self.image = image
            imagePosition = .imageLeading
            imageHugsTitle = true
            contentTintColor = foreground
        } else if let appIcon {
            // The island hands in the icon already drawn at this size, once
            // per take (NotchIslandAppIconCache); anything else is drawn now.
            let side = Self.appIconSide(forHeight: height)
            self.image = appIcon.size == NSSize(width: side, height: side)
                ? appIcon
                : NotchIslandAppIconCache.bitmap(of: appIcon, side: side, colorSpace: NSScreen.main?.colorSpace ?? .sRGB)
            imagePosition = .imageLeading
            imageHugsTitle = true
        }
        target = self
        action = #selector(pressed)
        setAccessibilityLabel(title)
        updateBackground()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Swaps the words, keeping the font and color ("Copy all" → "Copied").
    func replaceTitle(_ title: String) {
        let attributes = attributedTitle.length > 0 ? attributedTitle.attributes(at: 0, effectiveRange: nil) : [:]
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
        setAccessibilityLabel(title)
    }

    /// Traces a ring around the button that runs down over `seconds`.
    func startCountdown(seconds: Double) {
        countdownSeconds = seconds
        needsLayout = true
    }

    /// Takes the ring away for good (the person started answering).
    func stopCountdown() {
        countdownSeconds = nil
        ring.removeAllAnimations()
        ring.removeFromSuperlayer()
        ringTrack.removeFromSuperlayer()
    }

    func setCountdownPaused(_ paused: Bool) {
        guard paused != countdownPaused else { return }
        guard countdownStarted else {
            // Not laid out yet: the ring starts held (see layout()).
            countdownPaused = paused
            return
        }
        countdownPaused = paused
        if paused {
            let now = ring.convertTime(CACurrentMediaTime(), from: nil)
            ring.speed = 0
            ring.timeOffset = now
        } else {
            let pausedAt = ring.timeOffset
            ring.speed = 1
            ring.timeOffset = 0
            ring.beginTime = 0
            ring.beginTime = ring.convertTime(CACurrentMediaTime(), from: nil) - pausedAt
        }
    }

    override func layout() {
        super.layout()
        guard let seconds = countdownSeconds, let layer, bounds.width > 0 else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        let radius = r.height / 2
        // A pill traced clockwise from the top center.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: r.midX, y: r.maxY))
        path.addLine(to: CGPoint(x: r.maxX - radius, y: r.maxY))
        path.addArc(center: CGPoint(x: r.maxX - radius, y: r.midY), radius: radius, startAngle: .pi / 2, endAngle: -.pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: r.minX + radius, y: r.minY))
        path.addArc(center: CGPoint(x: r.minX + radius, y: r.midY), radius: radius, startAngle: -.pi / 2, endAngle: .pi / 2, clockwise: true)
        path.closeSubpath()
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: bounds.height)
        let traced: CGPath = isFlipped ? (path.copy(using: &flip) ?? path) : path
        for (shape, color) in [(ringTrack, NSColor(white: 1, alpha: 0.10)), (ring, NSColor(white: 1, alpha: 0.85))] {
            shape.path = traced
            shape.fillColor = nil
            shape.strokeColor = color.cgColor
            shape.lineWidth = 2
            shape.lineCap = .round
            shape.frame = bounds
            if shape.superlayer == nil { layer.addSublayer(shape) }
        }
        guard !countdownStarted else { return }
        countdownStarted = true
        let run = CABasicAnimation(keyPath: "strokeEnd")
        run.fromValue = 1
        run.toValue = 0
        run.duration = seconds
        ring.strokeEnd = 0
        ring.add(run, forKey: "countdown")
        if countdownPaused {
            ring.speed = 0
            ring.timeOffset = ring.convertTime(CACurrentMediaTime(), from: nil)
        }
    }

    private var foreground: NSColor {
        switch style {
        case .plain, .accent, .destructive: return .white
        case .subtle: return NSColor(white: 1, alpha: 0.82)
        case .warning: return NotchIslandPalette.warning
        case .link: return NotchIslandPalette.secondaryText
        }
    }

    private var fill: NSColor {
        switch style {
        case .plain: return NotchIslandPalette.buttonPlain
        case .subtle: return NotchIslandPalette.buttonSubtle
        case .accent: return NotchIslandPalette.accent
        case .destructive: return NotchIslandPalette.destructive
        case .warning: return NotchIslandPalette.warning.withAlphaComponent(0.22)
        case .link: return .clear
        }
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        return NSSize(width: ceil(base.width) + horizontalPadding * 2, height: buttonHeight)
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateBackground() {
        let color = isHighlighted ? fill.blended(withFraction: 0.25, of: .black) ?? fill : fill
        layer?.backgroundColor = color.cgColor
    }

    @objc private func pressed() {
        onPress?()
    }
}
