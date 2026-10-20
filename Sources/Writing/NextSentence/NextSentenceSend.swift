import AppKit
import QuartzCore

/// How the card leaves: into the text caret (insert), back to the caret (Esc), or jumping away (send).
enum NextSentenceExit {
    case insert, dismiss, send
}

/// Stars inside the card. While Return is held they streak inward, faster as it charges; on send
/// they flare outward as the card jumps away.
final class NextSentenceWarp: NextSentenceFlippedView {
    private struct Star { var angle: Double; var radius: Double; var speed: Double; var brightness: Double }
    private var stars: [Star] = []
    private let layers = [0.3, 0.55, 0.9].map { alpha -> CAShapeLayer in
        let layer = CAShapeLayer()
        layer.strokeColor = NSColor(srgbRed: 0.8, green: 0.88, blue: 1, alpha: alpha).cgColor
        layer.fillColor = nil
        layer.lineCap = .round
        layer.lineWidth = 1.1
        return layer
    }
    private var target = 0.0
    private var shown = 0.0
    private var jumpedAt: Date?
    private var timer: Timer?
    private var last = Date()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layers.forEach { layer?.addSublayer($0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// How charged the send is, 0...1.
    func set(charge: Double) {
        target = charge
        if charge > 0 { run() }
    }

    /// The send fired: stars flare outward.
    func jump() {
        guard shown > 0.02 || target > 0 else { return }
        jumpedAt = Date()
        run()
    }

    func reset() {
        target = 0
        shown = 0
        jumpedAt = nil
        timer?.invalidate()
        timer = nil
        layers.forEach { $0.path = nil }
    }

    private var maxRadius: Double { Double(hypot(bounds.width, bounds.height)) * 0.62 }

    private func run() {
        guard timer == nil, !NextSentenceMotion.reduced else { return }
        if stars.isEmpty {
            stars = (0..<130).map { _ in
                Star(angle: .random(in: 0..<(2 * .pi)), radius: .random(in: 30...max(31, maxRadius)),
                     speed: .random(in: 0.4...1.3), brightness: .random(in: 0.35...1))
            }
        }
        last = Date()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let now = Date()
        let dt = min(40, now.timeIntervalSince(last) * 1000)
        last = now
        shown += (target - shown) * min(1, dt / 80)
        let center = CGPoint(x: bounds.midX, y: bounds.midY), maxR = maxRadius
        let squash = Double(bounds.height / max(1, bounds.width)) * 1.1
        let paths = layers.map { _ in CGMutablePath() }
        let jump = jumpedAt.map { now.timeIntervalSince($0) * 1000 }
        if jump == nil && shown < 0.003 && target == 0 {
            reset()
            return
        }
        for index in stars.indices {
            var star = stars[index]
            let inner: Double, outer: Double, alpha: Double
            if let u = jump {
                star.radius += (0.5 + 0.004 * u) * star.speed * (0.3 + star.radius / maxR) * dt
                let length = min(240, 20 + u * 0.7) * star.speed * (0.3 + star.radius / maxR)
                inner = max(0, star.radius - length)
                outer = star.radius
                alpha = star.brightness * max(0, min(1, 1 - (u - 250) / 450))
            } else {
                star.radius -= (0.01 + 0.42 * shown * shown) * star.speed * (0.35 + star.radius / maxR) * dt
                if star.radius < 8 { star.radius = maxR * .random(in: 0.7...1) }
                inner = star.radius
                outer = star.radius + 1.5 + 70 * shown * shown * star.speed * (star.radius / maxR)
                alpha = shown * star.brightness * max(0, min(1, (star.radius - 8) / 50))
            }
            stars[index] = star
            guard alpha > 0.06 else { continue }
            let bucket = alpha < 0.4 ? 0 : alpha < 0.72 ? 1 : 2
            let (c, s) = (cos(star.angle), sin(star.angle) * squash)
            paths[bucket].move(to: CGPoint(x: center.x + CGFloat(c * inner), y: center.y + CGFloat(s * inner)))
            paths[bucket].addLine(to: CGPoint(x: center.x + CGFloat(c * outer), y: center.y + CGFloat(s * outer)))
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (layer, path) in zip(layers, paths) {
            layer.frame = bounds
            layer.path = path
        }
        CATransaction.commit()
        if let u = jump, u > 760 { reset() }
    }
}

extension NextSentenceMotion {
    /// The card leaves. `caret` is where the text caret is, in the card layer's (flipped) coordinates.
    static func exit(_ kind: NextSentenceExit, _ layer: CALayer, caret: CGPoint, then done: @escaping @MainActor () -> Void) {
        guard !reduced else { return done() }
        let gone: CATransform3D, lift: CATransform3D, liftAt: Double, duration: Double, curve: CAMediaTimingFunction
        switch kind {
        case .insert:
            // Pours straight into the caret.
            lift = scale(1.02, about: caret)
            gone = scale(0.04, about: caret)
            (liftAt, duration, curve) = (0.15, 0.28, CAMediaTimingFunction(controlPoints: 0.5, 0, 0.75, 0.4))
        case .dismiss:
            // A small lift, then it falls back into the caret.
            lift = CATransform3DMakeTranslation(0, -6, 0)
            gone = scale(0.04, about: caret)
            (liftAt, duration, curve) = (0.3, 0.36, CAMediaTimingFunction(controlPoints: 0.45, 0, 0.4, 1))
        case .send:
            // A breath in, then it jumps up and away.
            lift = scale(1.03, about: CGPoint(x: layer.bounds.midX, y: layer.bounds.midY))
            gone = CATransform3DConcat(scale(0.3, about: CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)), CATransform3DMakeTranslation(0, -70, 0))
            (liftAt, duration, curve) = (0.18, 0.38, CAMediaTimingFunction(controlPoints: 0.7, 0, 0.2, 1))
        }
        let move = CAKeyframeAnimation(keyPath: "transform")
        move.values = [CATransform3DIdentity, lift, gone].map { NSValue(caTransform3D: $0) }
        move.keyTimes = [0, NSNumber(value: liftAt), 1]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 1, 0]
        fade.keyTimes = [0, NSNumber(value: kind == .send ? 0.4 : 0.55), 1]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = duration
        group.timingFunction = curve
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { done() } }
        layer.add(group, forKey: "leave")
        CATransaction.commit()
    }
}
