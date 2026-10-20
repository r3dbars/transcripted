import AppKit
import QuartzCore

/// Colors, type and corners from the notch island (`NotchIslandPalette`, `NotchIslandGeometry` in
/// UIOverlay, which this module can't name). Keep the two in step.
enum NextSentenceCardStyle {
    static let background = NSColor.black
    static let title = NSColor(white: 1, alpha: 0.64)
    static let body = NSColor(white: 1, alpha: 0.9)
    static let faint = NSColor(white: 1, alpha: 0.36)
    static let buttonPlain = NSColor(white: 0.17, alpha: 1)
    static let buttonSubtle = NSColor(white: 0.11, alpha: 1)
    static var accent: NSColor { NSColor(srgbRed: 0.04, green: 0.52, blue: 1, alpha: 1) }
    static var send: NSColor { NSColor(srgbRed: 0.19, green: 0.82, blue: 0.35, alpha: 1) }
    static var listening: NSColor { NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1) }
    /// Mood pad, left to right: direct (cool blue), casual (neutral), warm (amber).
    static var toneColors: [NSColor] {
        [NSColor(srgbRed: 0.44, green: 0.64, blue: 1, alpha: 1), NSColor(white: 0.84, alpha: 1),
         NSColor(srgbRed: 1, green: 0.66, blue: 0.3, alpha: 1)]
    }
    /// Words that came from their history are a different shade of the text, not underlined.
    static var factColors: [NSColor] {
        [NSColor(srgbRed: 0.62, green: 0.94, blue: 0.77, alpha: 1), NSColor(srgbRed: 1, green: 0.82, blue: 0.63, alpha: 1),
         NSColor(srgbRed: 0.66, green: 0.86, blue: 1, alpha: 1), NSColor(srgbRed: 0.85, green: 0.76, blue: 1, alpha: 1)]
    }
    static let width: CGFloat = 500
    static let cornerRadius: CGFloat = 16
    static let lineHeight: CGFloat = 23
    /// The text box fits five lines at every length, so the card never changes size.
    static let textLines: CGFloat = 5
    static var titleFont: NSFont { .systemFont(ofSize: 12, weight: .semibold) }
    static var bodyFont: NSFont { .systemFont(ofSize: 16, weight: .regular) }
    static var hintFont: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    static var keyFont: NSFont { .monospacedSystemFont(ofSize: 10, weight: .semibold) }

    @MainActor static func label(_ font: NSFont, _ color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: "")
        label.font = font
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        return label
    }

    /// A small tick on the trackpad, for each step of a drag or a roll.
    @MainActor static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }

}

/// Top-down coordinates, so the card lays out like the page it was designed on.
class NextSentenceFlippedView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: Buttons

/// The island's capsule button, filled. Optionally press-and-hold: a ring fills while held
/// (`onHoldProgress`), and letting go once it's full calls `onHeld` instead of `onPress`.
final class NextSentenceCapsuleButton: NSButton {
    var onPress: (() -> Void)?
    var holdDuration: TimeInterval?
    var onHoldProgress: ((Double) -> Void)?
    var onHeld: (() -> Void)?
    /// Pointer in or out, for the card's own tooltips (system ones don't show over another app).
    var onHover: ((Bool) -> Void)?
    var fill: NSColor { didSet { layer?.backgroundColor = fill.cgColor } }
    private let height: CGFloat
    /// A labeled main action: more room around the title.
    private let wide: Bool
    private var holdStart: Date?
    private var holdTimer: Timer?

    init(title: String, fill: NSColor, height: CGFloat = 28, wide: Bool = false) {
        self.fill = fill
        self.height = height
        self.wide = wide
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = height / 2
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        contentTintColor = .white
        target = self
        action = #selector(pressed)
        set(title: title, icon: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func set(title: String, icon: NSImage?, color: NSColor = .white) {
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: height < 22 ? 10.5 : wide ? 13 : 12, weight: .semibold), .foregroundColor: color,
        ])
        imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        if let icon {
            // Symbols are templates: draw them in the title color. App icons keep their colors.
            let side: CGFloat = height < 22 ? 11 : 14
            image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
                icon.draw(in: rect)
                if icon.isTemplate { color.set(); rect.fill(using: .sourceAtop) }
                return true
            }
        } else {
            image = nil
        }
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        let base = super.intrinsicContentSize
        let empty = attributedTitle.length == 0
        let title = attributedTitle.size().width + (image == nil ? 0 : 19)
        return NSSize(width: empty ? height : ceil(max(base.width, title)) + (wide ? 36 : 22), height: height)
    }

    var fittingWidth: CGFloat { ceil(intrinsicContentSize.width) }

    @objc private func pressed() { onPress?() }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        guard holdDuration != nil else { return super.mouseDown(with: event) }
        holdStart = Date()
        layer?.opacity = 0.85
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    override func mouseUp(with event: NSEvent) {
        guard let holdDuration, let start = holdStart else { return super.mouseUp(with: event) }
        let held = Date().timeIntervalSince(start) >= holdDuration
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        cancelHold()
        if held { onHeld?() } else if inside { onPress?() }
    }

    func cancelHold() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        layer?.opacity = 1
        onHoldProgress?(0)
    }

    private func holdTick() {
        guard let holdDuration, let start = holdStart else { return }
        onHoldProgress?(NextSentencePolicy.holdProgress(heldFor: Date().timeIntervalSince(start), needed: holdDuration))
    }
}

// MARK: Mood pad

/// A small pad in the card's corner. Drag the dot: left is more direct, right warmer; up shorter,
/// down longer. Same axes as the arrow keys.
final class NextSentenceMoodPad: NextSentenceFlippedView {
    static let size = CGSize(width: 58, height: 38)
    var tone = 1
    var length = NextSentencePrompt.mediumLength
    var onChange: ((Int, Int) -> Void)?
    /// Being dragged, or not.
    var onActive: ((Bool) -> Void)?
    var onHover: ((Bool) -> Void)?
    private let dot = NSView()
    private let core = CALayer()
    private var dragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        dot.wantsLayer = true
        dot.frame = NSRect(x: 0, y: 0, width: 17, height: 17)
        dot.layer?.backgroundColor = NSColor(white: 1, alpha: 0.18).cgColor
        dot.layer?.cornerRadius = 8.5
        core.frame = CGRect(x: 3, y: 3, width: 11, height: 11)
        core.backgroundColor = NSColor.white.cgColor
        core.cornerRadius = 5.5
        core.shadowColor = NSColor.black.cgColor
        core.shadowOpacity = 0.5
        core.shadowRadius = 1.5
        core.shadowOffset = .zero
        dot.layer?.addSublayer(core)
        addSubview(dot)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self))
        place(animated: false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(tone: Int, length: Int) {
        guard !dragging, tone != self.tone || length != self.length else { return }
        self.tone = tone
        self.length = length
        place(animated: true)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9)
        let colors = NextSentenceCardStyle.toneColors
        NSGradient(colors: [colors[0].withAlphaComponent(0.4), NSColor(white: 1, alpha: 0.07), colors[2].withAlphaComponent(0.42)])?
            .draw(in: shape, angle: 0)
        NSColor(white: 1, alpha: 0.08).setFill()
        for third in [1.0 / 3, 2.0 / 3] {
            NSRect(x: (bounds.width * third).rounded(), y: 4, width: 1, height: bounds.height - 8).fill()
        }
        NSColor(white: 1, alpha: 0.12).setStroke()
        let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 9, yRadius: 9)
        edge.lineWidth = 0.5
        edge.stroke()
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    override func mouseDown(with event: NSEvent) {
        dragging = true
        onActive?(true)
        follow(event)
    }

    override func mouseDragged(with event: NSEvent) { follow(event) }

    override func mouseUp(with event: NSEvent) {
        dragging = false
        onActive?(false)
        place(animated: true)
    }

    private func follow(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let clamped = CGPoint(x: min(max(point.x, 0), bounds.width), y: min(max(point.y, 0), bounds.height))
        dot.setFrameOrigin(NSPoint(x: clamped.x - 8.5, y: clamped.y - 8.5))
        let cell = NextSentencePolicy.padCell(at: clamped, size: bounds.size)
        guard cell.tone != tone || cell.length != length else { return }
        tone = cell.tone
        length = cell.length
        NextSentenceCardStyle.tick()
        onChange?(tone, length)
    }

    private func place(animated: Bool) {
        let center = NextSentencePolicy.padCenter(tone: tone, length: length, size: Self.size)
        let origin = NSPoint(x: center.x - 8.5, y: center.y - 8.5)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return dot.setFrameOrigin(origin) }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.3)
            dot.animator().setFrameOrigin(origin)
        }
        NextSentenceMotion.pop(core)
    }
}

// MARK: Length handle

/// A small bar at the very end of the message. Drag it left to cut words one at a time, right to
/// bring them back and then for a longer message. Shows a left-right cursor and its own tooltip.
final class NextSentenceLengthGrip: NextSentenceFlippedView {
    static let size = CGSize(width: 18, height: 22)
    var onHover: ((Bool) -> Void)?
    var onDragStart: (() -> Void)?
    /// Where the pointer is, in window coordinates.
    var onDrag: ((NSPoint) -> Void)?
    var onDragEnd: (() -> Void)?
    private let bar = NSView()
    private var startX: CGFloat?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        layer?.cornerRadius = 5
        bar.wantsLayer = true
        bar.layer?.cornerRadius = 1.5
        addSubview(bar)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .inVisibleRect],
                                       owner: self))
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        NSCursor.resizeLeftRight.set()
        paint()
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if startX == nil { NSCursor.arrow.set() }
        paint()
        onHover?(false)
    }

    override func mouseMoved(with event: NSEvent) { NSCursor.resizeLeftRight.set() }
    override func cursorUpdate(with event: NSEvent) { NSCursor.resizeLeftRight.set() }

    override func mouseDown(with event: NSEvent) {
        startX = event.locationInWindow.x
        paint()
        onDragStart?()
    }

    override func mouseDragged(with event: NSEvent) {
        NSCursor.resizeLeftRight.set()
        guard startX != nil else { return }
        onDrag?(event.locationInWindow)
    }

    override func mouseUp(with event: NSEvent) {
        startX = nil
        if !hovering { NSCursor.arrow.set() }
        paint()
        onDragEnd?()
    }

    private func paint() {
        let active = hovering || startX != nil
        let height: CGFloat = active ? 18 : 15
        bar.frame = NSRect(x: (Self.size.width - 3) / 2, y: (Self.size.height - height) / 2, width: 3, height: height)
        bar.layer?.backgroundColor = (active ? NextSentenceCardStyle.accent : NSColor(white: 1, alpha: 0.35)).cgColor
        layer?.backgroundColor = (active ? NSColor(white: 1, alpha: 0.08) : .clear).cgColor
    }
}

// MARK: Rings around the card

/// The ring around the card's edge: blue fills while the remix button is held, green while Return or
/// Insert is held (full means "release to send"), and a red sweep runs around it while listening.
final class NextSentenceRing: NSView {
    private let progressLayer = CAShapeLayer()
    private let sweep = CALayer()
    private let sweepGradient = CAGradientLayer()
    private let sweepMask = CAShapeLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        progressLayer.fillColor = nil
        progressLayer.lineWidth = 2.5
        progressLayer.lineCap = .round
        progressLayer.strokeEnd = 0
        layer?.addSublayer(progressLayer)
        sweepGradient.type = .conic
        sweepGradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        sweepGradient.endPoint = CGPoint(x: 0.5, y: 0)
        let red = NextSentenceCardStyle.listening.cgColor
        let orange = NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1).cgColor
        let clear = NSColor.clear.cgColor
        sweepGradient.colors = [clear, clear, red, orange, clear]
        sweepGradient.locations = [0, 0.55, 0.72, 0.8, 0.92]
        sweepMask.fillColor = nil
        sweepMask.strokeColor = NSColor.white.cgColor
        sweepMask.lineWidth = 2.5
        sweep.mask = sweepMask
        sweep.addSublayer(sweepGradient)
        sweep.isHidden = true
        layer?.addSublayer(sweep)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let path = Self.path(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: NextSentenceCardStyle.cornerRadius + 2)
        progressLayer.frame = bounds
        progressLayer.path = path
        sweep.frame = bounds
        sweepMask.frame = bounds
        sweepMask.path = path
        let side = hypot(bounds.width, bounds.height)
        sweepGradient.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        CATransaction.commit()
    }

    // MARK: The send charge: a spark ring

    private lazy var head: CALayer = {
        let dot = CALayer()
        dot.bounds = CGRect(x: 0, y: 0, width: 5, height: 5)
        dot.cornerRadius = 2.5
        dot.backgroundColor = NSColor.white.cgColor
        dot.shadowColor = NSColor(srgbRed: 1, green: 0.75, blue: 0.43, alpha: 1).cgColor
        dot.shadowOpacity = 1
        dot.shadowRadius = 6
        dot.shadowOffset = .zero
        dot.isHidden = true
        layer?.addSublayer(dot)
        return dot
    }()

    private lazy var sparks: CAEmitterLayer = {
        let emitter = CAEmitterLayer()
        emitter.emitterShape = .point
        emitter.renderMode = .additive
        emitter.birthRate = 0
        let colors: [NSColor] = [.white, NSColor(srgbRed: 0.78, green: 1, blue: 0.85, alpha: 1), NextSentenceCardStyle.send,
                                 NSColor(srgbRed: 1, green: 0.82, blue: 0.54, alpha: 1)]
        emitter.emitterCells = colors.map { color in
            let cell = CAEmitterCell()
            cell.contents = Self.sparkImage
            cell.color = color.cgColor
            cell.birthRate = 30
            cell.lifetime = 0.45
            cell.lifetimeRange = 0.2
            cell.velocity = 28
            cell.velocityRange = 22
            cell.emissionRange = .pi * 2
            cell.scale = 0.22
            cell.scaleRange = 0.12
            cell.scaleSpeed = -0.3
            cell.alphaSpeed = -2
            cell.yAcceleration = -12
            return cell
        }
        layer?.addSublayer(emitter)
        return emitter
    }()

    private static let sparkImage: CGImage? = {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 3, dy: 3)).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()

    /// Hold-to-send: the ring traces the edge in green with a hot spark at its head shedding sparks,
    /// faster and flickering as it nears full. 0 clears it.
    func set(charge p: Double) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        guard p > 0 else {
            progressLayer.strokeEnd = 0
            progressLayer.isHidden = true
            head.isHidden = true
            sparks.birthRate = 0
            progressLayer.shadowOpacity = 0
            CATransaction.commit()
            return
        }
        let eased = (p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2) * 0.6 + p * 0.4
        let near = max(0, min(1, (p - 0.8) / 0.2))
        progressLayer.isHidden = false
        progressLayer.strokeColor = NextSentenceCardStyle.send.cgColor
        progressLayer.strokeEnd = eased
        progressLayer.lineWidth = 1.6 + 1.4 * p
        progressLayer.opacity = near > 0 ? Float(0.7 + 0.3 * Double.random(in: 0...1)) : 1
        progressLayer.shadowColor = NextSentenceCardStyle.send.cgColor
        progressLayer.shadowRadius = 3
        progressLayer.shadowOpacity = 0.8
        progressLayer.shadowOffset = .zero
        let point = Self.point(on: bounds.insetBy(dx: 1.5, dy: 1.5), radius: NextSentenceCardStyle.cornerRadius + 2, at: eased)
        head.isHidden = p >= 1
        head.position = point
        sparks.frame = bounds
        sparks.emitterPosition = point
        sparks.birthRate = Float(1 + p * 2 + near * 4)
        CATransaction.commit()
    }

    /// Full charge: the whole ring flares and throws sparks outward.
    func ignite() {
        progressLayer.strokeEnd = 1
        progressLayer.strokeColor = NSColor(srgbRed: 0.55, green: 1, blue: 0.7, alpha: 1).cgColor
        let flare = CAKeyframeAnimation(keyPath: "lineWidth")
        flare.values = [3, 7, 3]
        flare.keyTimes = [0, 0.25, 1]
        flare.duration = 0.52
        progressLayer.add(flare, forKey: "flare")
        let glow = CAKeyframeAnimation(keyPath: "shadowRadius")
        glow.values = [3, 14, 6]
        glow.keyTimes = [0, 0.2, 1]
        glow.duration = 0.7
        progressLayer.add(glow, forKey: "glow")
        sparks.emitterShape = .rectangle
        sparks.emitterMode = .outline
        sparks.emitterSize = bounds.size
        sparks.emitterPosition = CGPoint(x: bounds.midX, y: bounds.midY)
        sparks.birthRate = 40
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self else { return }
            self.sparks.birthRate = 0
            self.sparks.emitterShape = .point
            self.sparks.emitterMode = .points
        }
    }

    /// The point `fraction` of the way around the rounded rectangle, starting at the top center and
    /// running clockwise on screen (layer coordinates: y up), matching `path(in:radius:)`.
    static func point(on rect: CGRect, radius: CGFloat, at fraction: Double) -> CGPoint {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let straightW = rect.width - 2 * r, straightH = rect.height - 2 * r, arc = CGFloat.pi * r / 2
        let segments: [CGFloat] = [straightW / 2, arc, straightH, arc, straightW, arc, straightH, arc, straightW / 2]
        var left = CGFloat(max(0, min(1, fraction))) * segments.reduce(0, +)
        for (index, length) in segments.enumerated() {
            guard left > length, index < segments.count - 1 else {
                let k = length > 0 ? left / length : 0
                func corner(_ cx: CGFloat, _ cy: CGFloat, _ start: CGFloat) -> CGPoint {
                    let angle = start - k * .pi / 2
                    return CGPoint(x: cx + r * cos(angle), y: cy + r * sin(angle))
                }
                switch index {
                case 0: return CGPoint(x: rect.midX + left, y: rect.maxY)
                case 1: return corner(rect.maxX - r, rect.maxY - r, .pi / 2)
                case 2: return CGPoint(x: rect.maxX, y: rect.maxY - r - left)
                case 3: return corner(rect.maxX - r, rect.minY + r, 0)
                case 4: return CGPoint(x: rect.maxX - r - left, y: rect.minY)
                case 5: return corner(rect.minX + r, rect.minY + r, -.pi / 2)
                case 6: return CGPoint(x: rect.minX, y: rect.minY + r + left)
                case 7: return corner(rect.minX + r, rect.maxY - r, .pi)
                default: return CGPoint(x: rect.minX + r + left, y: rect.maxY)
                }
            }
            left -= length
        }
        return CGPoint(x: rect.midX, y: rect.maxY)
    }

    func set(progress: Double, color: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        progressLayer.strokeColor = color.cgColor
        progressLayer.strokeEnd = progress
        progressLayer.isHidden = progress <= 0
        CATransaction.commit()
    }

    /// One pass of light around the edge, then gone. For the card's arrival.
    func sweepOnce(color: NSColor) {
        let sweepLayer = CAShapeLayer()
        sweepLayer.frame = bounds
        sweepLayer.path = Self.path(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: NextSentenceCardStyle.cornerRadius + 2)
        sweepLayer.fillColor = nil
        sweepLayer.strokeColor = color.cgColor
        sweepLayer.lineWidth = 1.5
        sweepLayer.lineCap = .round
        sweepLayer.strokeStart = 0
        sweepLayer.strokeEnd = 0
        layer?.addSublayer(sweepLayer)
        let head = CABasicAnimation(keyPath: "strokeEnd")
        head.fromValue = 0
        head.toValue = 1
        head.duration = 0.55
        head.timingFunction = CAMediaTimingFunction(controlPoints: 0.3, 0.1, 0.2, 1)
        let tail = CABasicAnimation(keyPath: "strokeStart")
        tail.fromValue = 0
        tail.toValue = 1
        tail.beginTime = 0.12
        tail.duration = 0.55
        tail.timingFunction = head.timingFunction
        let group = CAAnimationGroup()
        group.animations = [head, tail]
        group.duration = 0.67
        group.beginTime = CACurrentMediaTime() + 0.18
        group.fillMode = .both
        group.isRemovedOnCompletion = false
        sweepLayer.add(group, forKey: "sweep")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) { sweepLayer.removeFromSuperlayer() }
    }

    func set(listening: Bool) {
        guard listening == sweep.isHidden else { return }
        sweep.isHidden = !listening
        sweepGradient.removeAllAnimations()
        guard listening, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        spin.toValue = -2 * Double.pi
        spin.duration = 1.1
        spin.repeatCount = .infinity
        sweepGradient.add(spin, forKey: "spin")
    }

    /// A rounded rectangle starting at the top center and running clockwise (on screen), so a ring
    /// fills like a clock hand. Layer coordinates: y up.
    static func path(in rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(radius, rect.width / 2, rect.height / 2)
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY), tangent2End: CGPoint(x: rect.maxX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY), tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY), tangent2End: CGPoint(x: rect.midX, y: rect.maxY), radius: r)
        path.closeSubpath()
        return path
    }
}

/// Sixteen small bars that bounce while it's listening.
final class NextSentenceWaveform: NSView {
    static let size = CGSize(width: 64, height: 14)
    private var bars: [CALayer] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: NSRect(origin: frameRect.origin, size: Self.size))
        wantsLayer = true
        for index in 0..<16 {
            let bar = CALayer()
            let height = CGFloat(4 + (index * 7) % 10)
            bar.frame = CGRect(x: CGFloat(index) * 4, y: (Self.size.height - height) / 2, width: 2, height: height)
            bar.cornerRadius = 1
            bar.backgroundColor = NextSentenceCardStyle.listening.cgColor
            layer?.addSublayer(bar)
            bars.append(bar)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func set(animating: Bool) {
        for (index, bar) in bars.enumerated() {
            bar.removeAllAnimations()
            guard animating, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { continue }
            let bounce = CABasicAnimation(keyPath: "transform.scale.y")
            bounce.fromValue = 1
            bounce.toValue = 0.3
            bounce.duration = 0.45
            bounce.autoreverses = true
            bounce.repeatCount = .infinity
            bounce.beginTime = CACurrentMediaTime() + Double(index) * 0.04
            bar.add(bounce, forKey: "bounce")
        }
    }
}
