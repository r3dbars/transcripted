import AppKit
import QuartzCore

/// Dust: a short burst of small particles from each rect (in `view`'s coordinates) that drifts up
/// and fades. For words cut off the end, and for the whole message bursting into a fresh take.
@MainActor
enum NextSentenceDust {
    static func burst(in view: NSView, rects: [CGRect], color: NSColor, density: Float = 1) {
        guard !NextSentenceMotion.reduced, let host = view.layer else { return }
        for rect in rects where rect.width > 1 && rect.height > 1 {
            let emitter = CAEmitterLayer()
            emitter.frame = view.bounds
            emitter.emitterShape = .rectangle
            emitter.emitterMode = .surface
            emitter.emitterPosition = CGPoint(x: rect.midX, y: rect.midY)
            emitter.emitterSize = rect.size
            emitter.renderMode = .additive
            let cell = CAEmitterCell()
            cell.contents = dot
            cell.color = color.withAlphaComponent(0.9).cgColor
            cell.birthRate = Float(rect.width * rect.height) * 0.9 * density
            cell.lifetime = 0.75
            cell.lifetimeRange = 0.3
            cell.velocity = 22
            cell.velocityRange = 18
            cell.emissionRange = .pi * 2
            cell.xAcceleration = 18
            cell.yAcceleration = view.isFlipped ? -26 : 26
            cell.scale = 0.16
            cell.scaleRange = 0.08
            cell.scaleSpeed = -0.12
            cell.alphaSpeed = -1.3
            emitter.emitterCells = [cell]
            emitter.beginTime = CACurrentMediaTime()
            host.addSublayer(emitter)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { emitter.birthRate = 0 }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) { emitter.removeFromSuperlayer() }
        }
    }

    private static let dot: CGImage? = {
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            NSColor.white.setFill()
            NSBezierPath(ovalIn: rect.insetBy(dx: 2.5, dy: 2.5)).fill()
            return true
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }()
}

/// A warm orb that breathes with your voice while it listens, in the mood pad's place.
final class NextSentenceOrb: NextSentenceFlippedView {
    private let core = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        core.type = .radial
        core.colors = [NSColor(srgbRed: 1, green: 0.86, blue: 0.62, alpha: 1).cgColor,
                       NSColor(srgbRed: 1, green: 0.45, blue: 0.25, alpha: 0.9).cgColor,
                       NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 0).cgColor]
        core.locations = [0, 0.45, 1]
        core.startPoint = CGPoint(x: 0.5, y: 0.5)
        core.endPoint = CGPoint(x: 1, y: 1)
        core.shadowColor = NSColor(srgbRed: 1, green: 0.45, blue: 0.25, alpha: 1).cgColor
        core.shadowOpacity = 0.8
        core.shadowRadius = 10
        core.shadowOffset = .zero
        layer?.addSublayer(core)
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// `level` is the voice's loudness, 0...1.
    func set(level: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let size = min(bounds.width, bounds.height) * (0.62 + 0.38 * level)
        core.frame = CGRect(x: bounds.midX - size / 2, y: bounds.midY - size / 2, width: size, height: size)
        core.shadowRadius = 8 + 14 * level
        core.opacity = Float(0.75 + 0.25 * level)
        CATransaction.commit()
    }
}

/// Word morph: when a different version replaces the message, words it shares with the old one stay
/// put and only the new words bloom in, one after another.
struct NextSentenceBloom {
    static let duration: TimeInterval = 0.34
    private var arrivals: [(range: NSRange, at: Date)] = []

    var isActive: Bool { arrivals.contains { Date().timeIntervalSince($0.at) < Self.duration } }

    /// Starts a bloom for every word in `new` that `old` didn't have (counting repeats).
    mutating func start(from old: String, to new: String) {
        arrivals = NextSentencePolicy.newWordRanges(from: old, to: new).enumerated().map { index, range in
            (range, Date().addingTimeInterval(Double(index) * 0.025))
        }
    }

    mutating func reset() { arrivals.removeAll() }

    /// Fades each new word in from clear to its settled color.
    mutating func apply(to storage: NSTextStorage, settled: (Int) -> NSColor) {
        let now = Date()
        storage.beginEditing()
        for arrival in arrivals where NSMaxRange(arrival.range) <= storage.length {
            let raw = max(0, min(1, now.timeIntervalSince(arrival.at) / Self.duration))
            let eased = 1 - pow(1 - raw, 3)
            storage.addAttribute(.foregroundColor, value: settled(arrival.range.location).withAlphaComponent(CGFloat(eased)), range: arrival.range)
        }
        storage.endEditing()
        arrivals.removeAll { now.timeIntervalSince($0.at) >= Self.duration + 0.05 }
    }
}

extension NextSentenceRing {
    /// Glow wash: on a tone change, the new tone's color flows around the edge from the mood pad's
    /// corner in both directions, then fades.
    func wash(color: NSColor) {
        guard !NextSentenceMotion.reduced, let host = layer else { return }
        let path = Self.path(in: bounds.insetBy(dx: 1.5, dy: 1.5), radius: NextSentenceCardStyle.cornerRadius + 2)
        let start: CGFloat = 0.09 // the pad sits just right of the top center
        func stroke() -> CAShapeLayer {
            let line = CAShapeLayer()
            line.frame = bounds
            line.path = path
            line.fillColor = nil
            line.strokeColor = color.cgColor
            line.lineWidth = 2
            line.lineCap = .round
            line.shadowColor = color.cgColor
            line.shadowRadius = 6
            line.shadowOpacity = 0.9
            line.shadowOffset = .zero
            host.addSublayer(line)
            return line
        }
        // One flows forward (clockwise) to halfway; the other flows back through the top and down the left.
        let forward = stroke(), back = stroke()
        let duration = 0.5
        func grow(_ line: CAShapeLayer, from: (CGFloat, CGFloat), to: (CGFloat, CGFloat)) {
            line.strokeStart = to.0
            line.strokeEnd = to.1
            let a = CABasicAnimation(keyPath: "strokeStart"), b = CABasicAnimation(keyPath: "strokeEnd")
            a.fromValue = from.0; b.fromValue = from.1
            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [1, 1, 0]
            fade.keyTimes = [0, 0.6, 1]
            let group = CAAnimationGroup()
            group.animations = [a, b, fade]
            group.duration = duration
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 1, 0.36, 1)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            line.add(group, forKey: "wash")
        }
        grow(forward, from: (start, start), to: (start, 0.55))
        grow(back, from: (start, start), to: (0, start))
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) {
            forward.removeFromSuperlayer()
            back.removeFromSuperlayer()
        }
        // The rest of the way back, around the left side.
        let tail = stroke()
        grow(tail, from: (1, 1), to: (0.55, 1))
        DispatchQueue.main.asyncAfter(deadline: .now() + duration + 0.05) { tail.removeFromSuperlayer() }
    }
}
