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

/// Swap and mark: when a different version replaces the message, the words it didn't have fade in
/// with a warm glow that cools to their settled color, so what changed is easy to see.
struct NextSentenceMark {
    static let duration: TimeInterval = 1.1
    private var ranges: [NSRange] = []
    private var started = Date.distantPast

    var isActive: Bool { !ranges.isEmpty }

    mutating func start(_ ranges: [NSRange]) {
        self.ranges = ranges
        started = Date()
    }

    mutating func reset() { ranges.removeAll() }

    /// Fades the new words in over a quarter second, warm, then cools them to their settled color.
    mutating func apply(to storage: NSTextStorage, settled: (Int) -> NSColor) {
        let t = Date().timeIntervalSince(started)
        let appear = Self.ease(min(1, max(0, (t - 0.06) / 0.22)))
        let cool = Self.ease(min(1, max(0, (t - 0.3) / 0.8)))
        let warm = NSColor(srgbRed: 1, green: 0.82, blue: 0.61, alpha: 1)
        storage.beginEditing()
        for range in ranges where NSMaxRange(range) <= storage.length {
            let rest = settled(range.location)
            let color = warm.blended(withFraction: CGFloat(cool), of: rest) ?? rest
            storage.addAttribute(.foregroundColor, value: color.withAlphaComponent(CGFloat(appear) * rest.alphaComponent), range: range)
        }
        storage.endEditing()
        if t >= Self.duration { ranges.removeAll() }
    }

    private static func ease(_ x: Double) -> Double { 1 - pow(1 - x, 3) }
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
