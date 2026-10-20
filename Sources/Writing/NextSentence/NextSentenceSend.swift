import AppKit
import QuartzCore

/// How the card leaves: into the text caret (insert), back to the caret (Esc), or charged and poured
/// into the caret as it sends (send).
enum NextSentenceExit {
    case insert, dismiss, send
}

/// Hold-to-send's charge: one thin green line fills the card's edge from the top center down both
/// sides, with a soft bloom that brightens as it charges. Full, it flares once and then breathes while
/// it's held. Nothing flies around: one clean line of light.
final class NextSentenceChargeRim: NSView {
    /// How far past the card the bloom can reach.
    static let reach: CGFloat = 26

    /// Both halves of the line at one softness. The blur sits on `holder`, so it softens the line
    /// instead of being clipped by it.
    @MainActor private final class Glow {
        let holder = CALayer()
        let halves = [CAShapeLayer(), CAShapeLayer()]

        init(blur: CGFloat?, width: CGFloat, color: NSColor, in host: CALayer) {
            for half in halves {
                half.fillColor = nil
                half.strokeColor = color.cgColor
                half.lineWidth = width
                half.lineCap = .round
                half.strokeEnd = 0
                holder.addSublayer(half)
            }
            if let blur, let filter = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: blur]) {
                filter.name = "blur"
                holder.filters = [filter]
            }
            holder.opacity = 0
            host.addSublayer(holder)
        }
    }

    private var far: Glow!
    private var near: Glow!
    private var line: Glow!
    private let heads = [CALayer(), CALayer()]
    private var full = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerUsesCoreImageFilters = true
        guard let host = layer else { return }
        let green = NextSentenceCardStyle.send
        far = Glow(blur: 12, width: 7, color: green, in: host)
        near = Glow(blur: 4, width: 3, color: green, in: host)
        line = Glow(blur: nil, width: 1.5, color: NSColor(srgbRed: 0.62, green: 1, blue: 0.74, alpha: 1), in: host)
        for head in heads {
            head.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            head.cornerRadius = 2
            head.backgroundColor = NSColor.white.cgColor
            head.shadowColor = green.cgColor
            head.shadowOpacity = 1
            head.shadowRadius = 5
            head.shadowOffset = .zero
            head.isHidden = true
            host.addSublayer(head)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private var glows: [Glow] { [far, near, line] }
    private var edge: CGRect { bounds.insetBy(dx: Self.reach + 0.75, dy: Self.reach + 0.75) }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // One half runs clockwise from the top center; the other is its mirror image, so the two
        // fill down both sides and meet at the bottom.
        let path = NextSentenceRing.path(in: edge, radius: NextSentenceCardStyle.cornerRadius)
        var mirror = CGAffineTransform(translationX: bounds.width, y: 0).scaledBy(x: -1, y: 1)
        let mirrored = path.copy(using: &mirror) ?? path
        for glow in glows {
            glow.holder.frame = bounds
            for (half, shape) in zip(glow.halves, [path, mirrored]) {
                half.frame = bounds
                half.path = shape
            }
        }
        CATransaction.commit()
    }

    /// How charged the send is, 0...1. 0 lets the light fade away.
    func set(charge p: Double) {
        guard p > 0 else { return fade() }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Slow to start, quick through the middle, settling into full.
        let eased = (p < 0.5 ? 4 * p * p * p : 1 - pow(-2 * p + 2, 3) / 2) * 0.6 + p * 0.4
        for glow in glows {
            glow.holder.removeAnimation(forKey: "fade")
            glow.halves.forEach { $0.strokeEnd = 0.5 * eased }
        }
        if !full {
            line.holder.opacity = Float(0.65 + 0.35 * eased)
            near.holder.opacity = Float(0.25 + 0.55 * eased)
            far.holder.opacity = Float(0.85 * eased * eased)
            near.holder.setValue(3 + 3 * eased, forKeyPath: "filters.blur.inputRadius")
            far.holder.setValue(8 + 8 * eased, forKeyPath: "filters.blur.inputRadius")
        }
        let tip = NextSentenceRing.point(on: edge, radius: NextSentenceCardStyle.cornerRadius, at: 0.5 * eased)
        for (head, x) in zip(heads, [tip.x, bounds.width - tip.x]) {
            head.isHidden = p >= 1
            head.position = CGPoint(x: x, y: tip.y)
        }
        CATransaction.commit()
    }

    /// Full: the bloom flares once, then breathes softly for as long as it's held.
    func arm() {
        guard !full else { return }
        full = true
        heads.forEach { $0.isHidden = true }
        line.holder.opacity = 1
        near.holder.opacity = 0.85
        far.holder.opacity = 0.75
        guard !NextSentenceMotion.reduced else { return }
        let flare = CAKeyframeAnimation(keyPath: "opacity")
        flare.values = [0.85, 1, 0.75]
        flare.keyTimes = [0, 0.2, 1]
        flare.duration = 0.5
        let spread = CAKeyframeAnimation(keyPath: "filters.blur.inputRadius")
        spread.values = [16, 22, 14]
        spread.keyTimes = [0, 0.2, 1]
        spread.duration = 0.5
        far.holder.add(flare, forKey: "flare")
        far.holder.add(spread, forKey: "spread")
        far.holder.setValue(14, forKeyPath: "filters.blur.inputRadius")
        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.75
        breathe.toValue = 0.5
        breathe.duration = 0.8
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.beginTime = CACurrentMediaTime() + 0.5
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        far.holder.add(breathe, forKey: "breathe")
    }

    /// Let go, early or sending: the light fades out quickly, then the line resets.
    private func fade() {
        full = false
        heads.forEach { $0.isHidden = true }
        for glow in glows where glow.holder.opacity > 0 {
            glow.holder.removeAnimation(forKey: "breathe")
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = glow.holder.presentation()?.opacity ?? glow.holder.opacity
            fade.toValue = 0
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            glow.holder.opacity = 0
            glow.holder.add(fade, forKey: "fade")
            CATransaction.commit()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self, !self.full, self.line.holder.opacity == 0 else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.glows.forEach { $0.halves.forEach { $0.strokeEnd = 0 } }
            CATransaction.commit()
        }
    }
}

extension NextSentenceMotion {
    /// The card leaves. `caret` is where the text caret is, in the card layer's (flipped) coordinates.
    /// It starts from wherever the card is now, so a send leaves straight from its charged squeeze.
    static func exit(_ kind: NextSentenceExit, _ layer: CALayer, caret: CGPoint, then done: @escaping @MainActor () -> Void) {
        guard !reduced else { return done() }
        let now = layer.presentation()?.transform ?? CATransform3DIdentity
        let center = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
        let gone = scale(0.04, about: caret)
        let lift: CATransform3D, liftAt: Double, duration: Double
        switch kind {
        case .insert:
            // Pours straight into the caret.
            (lift, liftAt, duration) = (scale(1.02, about: caret), 0.15, 0.28)
        case .dismiss:
            // A small lift, then it falls back into the caret.
            (lift, liftAt, duration) = (CATransform3DMakeTranslation(0, -6, 0), 0.3, 0.36)
        case .send:
            // The charge lets go: a quick spring up past full size, then it pours into the caret.
            (lift, liftAt, duration) = (scale(1.03, about: center), 0.24, 0.42)
        }
        let move = CAKeyframeAnimation(keyPath: "transform")
        move.values = [now, lift, gone].map { NSValue(caTransform3D: $0) }
        move.keyTimes = [0, NSNumber(value: liftAt), 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: kind == .send ? 0.72 : 0.55), 1]
        let group = CAAnimationGroup()
        group.duration = duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        switch kind {
        case .insert: group.timingFunction = CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.4)
        case .dismiss: group.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.4, 1)
        case .send:
            // Out fast into the pop, then gathering speed into the caret.
            move.timingFunctions = [CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1),
                                    CAMediaTimingFunction(controlPoints: 0.6, 0, 0.85, 0.4)]
        }
        var animations: [CAAnimation] = [move, fade]
        if kind == .send {
            // The charge's green rides along with the card as a glow around it.
            let green = NextSentenceCardStyle.send.cgColor
            let color = CAKeyframeAnimation(keyPath: "shadowColor")
            color.values = [layer.shadowColor ?? green, green, green]
            let radius = CAKeyframeAnimation(keyPath: "shadowRadius")
            radius.values = [layer.shadowRadius, 26, 8]
            let opacity = CAKeyframeAnimation(keyPath: "shadowOpacity")
            opacity.values = [layer.shadowOpacity, 0.95, 0]
            for glow in [color, radius, opacity] {
                glow.keyTimes = [0, NSNumber(value: liftAt), 1]
                animations.append(glow)
            }
        }
        group.animations = animations
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        layer.add(group, forKey: "leave")
        CATransaction.commit()
    }

    /// Sent: two thin green rings spread from the caret and fade, the second just behind the first.
    static func sentRipple(in view: NSView, at point: CGPoint) {
        guard !reduced, let host = view.layer else { return }
        for (index, size) in [CGFloat(48), 30].enumerated() {
            let ring = CAShapeLayer()
            ring.bounds = CGRect(x: 0, y: 0, width: size, height: size)
            ring.position = point
            ring.path = CGPath(ellipseIn: ring.bounds.insetBy(dx: 1, dy: 1), transform: nil)
            ring.fillColor = nil
            ring.strokeColor = NextSentenceCardStyle.send.cgColor
            ring.lineWidth = 1.5
            ring.opacity = 0
            host.addSublayer(ring)
            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.2
            grow.toValue = 1
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.9, 0]
            fade.keyTimes = [0, 0.15, 1]
            let group = CAAnimationGroup()
            group.animations = [grow, fade]
            group.duration = 0.55
            group.beginTime = CACurrentMediaTime() + 0.08 * Double(index)
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.3, 1)
            group.fillMode = .both
            group.isRemovedOnCompletion = false
            ring.add(group, forKey: "ripple")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.75) { ring.removeFromSuperlayer() }
        }
    }
}
