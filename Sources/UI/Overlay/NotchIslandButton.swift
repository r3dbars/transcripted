// NotchIslandButton.swift
// The island's pill buttons: plain, accent (the white primary), warning and
// destructive, with an optional countdown ring; plus the recording footer's
// borderless round icon and translucent Stop. Split out of NotchIslandView.swift.

import AppKit

final class NotchIslandButton: NSButton {
    enum Style {
        case plain
        case subtle
        case accent
        case destructive
        case warning
        case link
        /// White with black text: the speaker review's Done and Open.
        case white
        /// A borderless round icon (no title drawn); a faint fill on hover.
        case icon
        /// Dark translucent fill, thin light border, white text: the
        /// recording's Stop, so the island never shows a glaring white block.
        case translucent
    }

    var onPress: (() -> Void)?
    private let style: Style
    private var countdownSeconds: Double?
    private var countdownFromFraction: Double = 1
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
        // The review's white Done / Open pill is a little roomier (mockup: 20 px).
        self.horizontalPadding = style == .icon ? 0 : (style == .link ? 4 : (style == .white ? 20 : (height < 26 ? 9 : 14)))
        self.symbolPointSize = style == .icon ? fontSize : (style == .translucent ? fontSize - 4 : fontSize - 2)
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = height / 2
        if style == .translucent {
            layer?.borderWidth = 1
            layer?.borderColor = NSColor(white: 1, alpha: 0.16).cgColor
        }
        let weight: NSFont.Weight = style == .link
            ? .medium
            : ((style == .accent || style == .destructive || style == .white || height < 26) ? .bold : .semibold)
        attributedTitle = NSAttributedString(
            string: style == .icon ? "" : title,
            attributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: weight), .foregroundColor: foreground]
        )
        if let symbolName, let image = symbolImage(symbolName) {
            self.image = image
            imagePosition = style == .icon ? .imageOnly : .imageLeading
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

    private let symbolPointSize: CGFloat
    private var hovered = false
    private var hoverArea: NSTrackingArea?

    private func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: symbolPointSize, weight: style == .icon ? .medium : .bold))
    }

    /// Swaps the icon, keeping its size and tint (Copy's brief checkmark).
    func replaceSymbol(_ name: String) {
        guard let image = symbolImage(name) else { return }
        self.image = image
    }

    /// Swaps the words, keeping the font and color ("Copy all" → "Copied").
    func replaceTitle(_ title: String) {
        let attributes = attributedTitle.length > 0 ? attributedTitle.attributes(at: 0, effectiveRange: nil) : [:]
        attributedTitle = NSAttributedString(string: title, attributes: attributes)
        setAccessibilityLabel(title)
    }

    /// Traces a ring around the button that runs down over `seconds`,
    /// starting from `fromFraction` of a full ring (a countdown already
    /// under way when the drop-down was built).
    /// `words` says what happens at zero for VoiceOver ("Stops in 12
    /// seconds"); the button's accessibility value reads it from the ring's
    /// current position, so it stays right as the ring runs and while it's held.
    func startCountdown(seconds: Double, fromFraction: Double = 1, words: ((Int) -> String)? = nil) {
        countdownSeconds = seconds
        countdownFromFraction = min(1, max(0, fromFraction))
        countdownWords = words
        needsLayout = true
    }

    private var countdownWords: ((Int) -> String)?

    override func accessibilityValue() -> Any? {
        guard let seconds = countdownSeconds, let countdownWords else { return super.accessibilityValue() }
        // Before the first layout the ring hasn't started: the full count is left.
        let left: Double
        if countdownStarted, countdownFromFraction > 0 {
            let fractionLeft = Double(ring.presentation()?.strokeEnd ?? ring.strokeEnd)
            left = fractionLeft * seconds / countdownFromFraction
        } else {
            left = seconds
        }
        return countdownWords(Int(left.rounded(.up)))
    }

    /// Takes the ring away for good (the person started answering).
    func stopCountdown() {
        countdownSeconds = nil
        countdownWords = nil
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
        // On the white pill the ring is drawn dark so it still shows.
        let whiteFill = style == .white || style == .accent
        let ink: CGFloat = whiteFill ? 0 : 1
        let trackAlpha: CGFloat = whiteFill ? 0.14 : 0.10
        let ringAlpha: CGFloat = whiteFill ? 0.6 : 0.85
        for (shape, color) in [(ringTrack, NSColor(white: ink, alpha: trackAlpha)), (ring, NSColor(white: ink, alpha: ringAlpha))] {
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
        run.fromValue = countdownFromFraction
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
        case .plain, .destructive: return .white
        case .subtle: return NSColor(white: 1, alpha: 0.82)
        case .warning: return NotchIslandPalette.warning
        case .link: return NSColor(white: 1, alpha: 0.55)
        // The primary action is ink on the black island: a white pill.
        // Green means live, so it is never a button.
        case .accent, .white: return .black
        case .icon: return NSColor(white: 1, alpha: hovered ? 0.92 : 0.66)
        case .translucent: return NSColor(white: 1, alpha: 0.92)
        }
    }

    private var fill: NSColor {
        switch style {
        case .plain: return NotchIslandPalette.buttonPlain
        case .subtle: return NotchIslandPalette.buttonSubtle
        case .accent: return .white
        case .destructive: return NotchIslandPalette.destructive
        case .warning: return NotchIslandPalette.warning.withAlphaComponent(0.22)
        case .link: return .clear
        case .white: return .white
        case .icon: return NSColor(white: 1, alpha: hovered ? 0.08 : 0)
        case .translucent: return NSColor(white: 1, alpha: hovered ? 0.14 : 0.10)
        }
    }

    override var intrinsicContentSize: NSSize {
        // A round icon is as wide as it is tall.
        if style == .icon { return NSSize(width: buttonHeight, height: buttonHeight) }
        let base = super.intrinsicContentSize
        return NSSize(width: ceil(base.width) + horizontalPadding * 2, height: buttonHeight)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard style == .icon || style == .translucent else { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHovered(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHovered(false)
    }

    private func setHovered(_ value: Bool) {
        guard style == .icon || style == .translucent, hovered != value else { return }
        hovered = value
        contentTintColor = foreground
        updateBackground()
    }

    override var isHighlighted: Bool {
        didSet { updateBackground() }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    private func updateBackground() {
        let pressedFill = style == .icon || style == .translucent
            ? NSColor(white: 1, alpha: 0.18)
            : fill.blended(withFraction: style == .white ? 0.12 : 0.25, of: .black) ?? fill
        let color = isHighlighted ? pressedFill : fill
        layer?.backgroundColor = color.cgColor
    }

    @objc private func pressed() {
        onPress?()
    }
}
