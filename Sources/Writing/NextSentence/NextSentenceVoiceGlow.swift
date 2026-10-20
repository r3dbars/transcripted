import AppKit
import QuartzCore

/// While it listens, the card's edge is the voice meter: the loading aurora's blue, warm and mint
/// drift slowly around a thin rim, and a soft bloom spreads off the edge as you talk. The rim never
/// thickens; your voice only makes the bloom brighter and wider. It follows a smoothed level, so
/// syllables blend into a breath instead of flickering. Letting go flares it once, with the chime.
final class NextSentenceVoiceGlow: NextSentenceFlippedView {
    /// How far past the card the bloom can reach.
    static let reach: CGFloat = 26

    /// One ring of color: a rotating conic gradient seen through a rounded-rect stroke. The blur sits
    /// on `holder`, outside the mask, so it softens the ring itself instead of being clipped back to it.
    @MainActor private final class Rim {
        let holder = CALayer()
        let masked = CALayer()
        let colors = CAGradientLayer()
        let mask = CAShapeLayer()

        init(blur: CGFloat?, in host: CALayer) {
            colors.type = .conic
            colors.startPoint = CGPoint(x: 0.5, y: 0.5)
            colors.endPoint = CGPoint(x: 0.5, y: 0)
            mask.fillColor = nil
            mask.strokeColor = NSColor.white.cgColor
            masked.mask = mask
            masked.addSublayer(colors)
            holder.addSublayer(masked)
            if let blur, let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) {
                filter.name = "blur"
                holder.filters = [filter]
            }
            host.addSublayer(holder)
        }
    }

    private var far: Rim!
    private var near: Rim!
    private var line: Rim!
    private var timer: Timer?
    private var target: CGFloat = 0
    private var level: CGFloat = 0
    private var drift: CGFloat = 0
    private(set) var active = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        guard let host = layer else { return }
        // Back to front: the wide bloom, a tighter glow, then the thin rim.
        far = Rim(blur: 14, in: host)
        near = Rim(blur: 5, in: host)
        line = Rim(blur: nil, in: host)
        for rim in [far, near, line] { rim?.colors.colors = Self.aurora }
        alphaValue = 0
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Blue, warm and mint around the rim, dimmer between them so the colors read as drifting lights.
    private static var aurora: [CGColor] {
        let colors = NextSentenceCardStyle.toneColors
        let blue = colors[0], warm = colors[2], mint = NextSentenceCardStyle.factColors[0]
        let between = NSColor(srgbRed: 1, green: 0.62, blue: 0.4, alpha: 0.35)
        return [blue, between, warm, between, mint, between, blue].map(\.cgColor)
    }

    private var rims: [Rim] { [far, near, line] }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let card = bounds.insetBy(dx: Self.reach, dy: Self.reach)
        let path = CGPath(roundedRect: card.insetBy(dx: 0.75, dy: 0.75), cornerWidth: NextSentenceCardStyle.cornerRadius,
                          cornerHeight: NextSentenceCardStyle.cornerRadius, transform: nil)
        // A square of color big enough to cover the card at any turn, so it can rotate under the rim.
        let side = hypot(bounds.width, bounds.height)
        for rim in rims {
            rim.holder.frame = bounds
            rim.masked.frame = bounds
            rim.mask.frame = bounds
            rim.mask.path = path
            rim.colors.bounds = CGRect(x: 0, y: 0, width: side, height: side)
            rim.colors.position = CGPoint(x: bounds.midX, y: bounds.midY)
        }
        far.mask.lineWidth = 7
        near.mask.lineWidth = 3
        line.mask.lineWidth = 1.25
        CATransaction.commit()
        apply()
    }

    /// The microphone's loudness, 0...1, as it arrives.
    func set(level: CGFloat) { target = max(0, min(1, level)) }

    func start() {
        guard !active else { return }
        active = true
        target = 0
        level = 0
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        apply()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            animator().alphaValue = 1
        }
    }

    /// Stops listening. With `flare`, the bloom breathes bright once (they let go) before it fades.
    func stop(flare: Bool) {
        guard active else { return }
        active = false
        target = 0
        if flare && !NextSentenceMotion.reduced {
            level = max(level, 0.85)
            apply()
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = flare ? 0.6 : 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.active else { return }
                self.timer?.invalidate()
                self.timer = nil
            }
        })
    }

    private func tick() {
        // Rises gently and falls slower still. The colors drift slowly, a little faster with your voice.
        level += (target - level) * (target > level ? 0.1 : 0.035)
        if !NextSentenceMotion.reduced { drift += (0.0015 + 0.004 * level) * 2 * .pi }
        apply()
    }

    /// The rim stays the same thin line; the voice brightens it a little and spreads the bloom.
    private func apply() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        line.holder.opacity = Float(0.45 + 0.4 * level)
        near.holder.opacity = Float(0.15 + 0.6 * level)
        far.holder.opacity = Float(0.9 * level)
        near.holder.setValue(4 + 4 * level, forKeyPath: "filters.blur.inputRadius")
        far.holder.setValue(10 + 12 * level, forKeyPath: "filters.blur.inputRadius")
        let turn = CATransform3DMakeRotation(drift, 0, 0, 1)
        for rim in rims { rim.colors.transform = turn }
        CATransaction.commit()
    }
}
