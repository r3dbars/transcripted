import AppKit
import CoreImage
import QuartzCore

/// The card's arrival: a small flash pulses at the text caret, then a droplet of ink pulls off it with
/// two smaller drops behind, they merge into one blob, and the blob swells into the card's shape. A blur
/// then threshold (a "goo" filter) makes the circles flow together like liquid. When the blob fills the
/// card, `done` runs and the real card takes over.
@MainActor
enum NextSentenceLiquid {
    static let duration: TimeInterval = 0.64

    /// `caret` and `target` are in `root`'s (flipped) coordinates.
    static func open(in root: NSView, caret: CGPoint, target: CGRect, done: @escaping @MainActor @Sendable () -> Void) {
        flash(in: root, at: caret)

        let goo = NextSentenceFlippedView(frame: root.bounds)
        goo.wantsLayer = true
        goo.layerUsesCoreImageFilters = true
        if let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 6]),
           let threshold = CIFilter(name: "CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 20), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: -8)]) {
            goo.contentFilters = [blur, threshold]
        }
        for _ in 0..<4 {
            let blob = CALayer()
            blob.backgroundColor = NSColor.black.cgColor
            goo.layer?.addSublayer(blob)
        }
        root.addSubview(goo, positioned: .below, relativeTo: root.subviews.first)

        // The drop lands in the card's corner nearest the caret, and the card swells from there.
        let below = caret.y < target.midY
        let landing = CGPoint(x: target.minX + 34, y: below ? target.minY + 20 : target.maxY - 20)
        let lift: CGFloat = below ? 1 : -1

        let start = Date()
        var finished = false
        let finish = NextSentenceMainCallback(done)
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            MainActor.assumeIsolated {
                let ms = Date().timeIntervalSince(start) * 1000
                // The four blobs live on the goo view's layer: the card body, the drop, and two small drops.
                guard let blobs = goo.layer?.sublayers, blobs.count == 4 else { return timer.invalidate() }
                let (body, drop, small, tiny) = (blobs[0], blobs[1], blobs[2], blobs[3])
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                for (layer, delay, span, size, spread) in [(drop, 0.0, 320.0, (4.0, 15.0, 28.0), 0.0), (small, 60, 330, (3, 10, 14), -6.0),
                                                           (tiny, 120, 320, (2, 7, 9), -10.0)] as [(CALayer, Double, Double, (CGFloat, CGFloat, CGFloat), Double)] {
                    let t = min(1, max(0, (ms - delay) / span))
                    let mid = CGPoint(x: caret.x + 2, y: caret.y + 12 * lift)
                    let end = CGPoint(x: landing.x + spread, y: landing.y - CGFloat(spread) * 0.5 * lift)
                    let (center, size) = path(t, from: caret, mid: mid, to: end, sizes: size)
                    circle(layer, center, t <= 0 ? 0 : size)
                }
                // The body swells from the landing spot into the card, with a little spring.
                let t = min(1, max(0, (ms - 190) / 470))
                if t > 0 {
                    let seedCenter = CGPoint(x: landing.x + 6, y: landing.y + 8 * lift)
                    if t < 0.22 {
                        // A round blob grows where the drops landed.
                        circle(body, seedCenter, 46 * CGFloat(ease(t / 0.22)))
                    } else {
                        // Then it springs out into the card's shape.
                        let k = CGFloat(springy((t - 0.22) / 0.78))
                        let seed = CGRect(x: seedCenter.x - 23, y: seedCenter.y - 23, width: 46, height: 46)
                        body.frame = CGRect(x: seed.minX + (target.minX - seed.minX) * k, y: seed.minY + (target.minY - seed.minY) * k,
                                            width: seed.width + (target.width - seed.width) * k,
                                            height: seed.height + (target.height - seed.height) * k)
                        body.cornerRadius = 23 + (18 - 23) * min(1, k)
                    }
                }
                CATransaction.commit()
                if ms >= duration * 1000, !finished {
                    finished = true
                    finish.call()
                    NSAnimationContext.runAnimationGroup({ context in
                        context.duration = 0.2
                        goo.animator().alphaValue = 0
                    }, completionHandler: { MainActor.assumeIsolated { goo.removeFromSuperview() } })
                    timer.invalidate()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func circle(_ layer: CALayer, _ center: CGPoint, _ size: CGFloat) {
        layer.frame = CGRect(x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)
        layer.cornerRadius = size / 2
    }

    /// Two-step path for a drop: up off the caret, then over to the landing spot.
    private static func path(_ t: Double, from: CGPoint, mid: CGPoint, to: CGPoint, sizes: (CGFloat, CGFloat, CGFloat)) -> (CGPoint, CGFloat) {
        let p = ease(t)
        if p < 0.38 {
            let k = CGFloat(p / 0.38)
            return (mix(from, mid, k), sizes.0 + (sizes.1 - sizes.0) * k)
        }
        let k = CGFloat((p - 0.38) / 0.62)
        return (mix(mid, to, k), sizes.1 + (sizes.2 - sizes.1) * k)
    }

    /// A small bright pulse right where the caret is, before anything else moves.
    static func flash(in root: NSView, at caret: CGPoint) {
        let size: CGFloat = 30
        let glow = CAGradientLayer()
        glow.type = .radial
        glow.colors = [NSColor.white.cgColor, NextSentenceCardStyle.accent.withAlphaComponent(0.55).cgColor,
                       NextSentenceCardStyle.accent.withAlphaComponent(0).cgColor]
        glow.locations = [0, 0.3, 1]
        glow.startPoint = CGPoint(x: 0.5, y: 0.5)
        glow.endPoint = CGPoint(x: 1, y: 1)
        glow.frame = CGRect(x: caret.x - size / 2, y: caret.y - size / 2, width: size, height: size)
        glow.opacity = 0
        root.layer?.addSublayer(glow)
        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [0.2, 1, 1.6]
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 1, 0]
        let pulse = CAAnimationGroup()
        pulse.animations = [scale, fade]
        [scale, fade].forEach { $0.keyTimes = [0, 0.35, 1] }
        pulse.duration = 0.42
        pulse.timingFunction = CAMediaTimingFunction(name: .easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { glow.removeFromSuperlayer() }
        glow.add(pulse, forKey: "flash")
        CATransaction.commit()
    }

    private static func mix(_ a: CGPoint, _ b: CGPoint, _ k: CGFloat) -> CGPoint {
        CGPoint(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k)
    }

    private static func ease(_ t: Double) -> Double {
        t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
    }

    /// Fast out, a slight overshoot, then settled: like the mockup's spring curve.
    private static func springy(_ t: Double) -> Double {
        let c = 1.4
        return 1 + (c + 1) * pow(t - 1, 3) + c * pow(t - 1, 2)
    }
}

/// Carries a main-actor callback into the animation timer, which only ever runs it on the main thread.
final class NextSentenceMainCallback: @unchecked Sendable {
    private let callback: @MainActor () -> Void
    init(_ callback: @escaping @MainActor () -> Void) { self.callback = callback }
    @MainActor func call() { callback() }
}
