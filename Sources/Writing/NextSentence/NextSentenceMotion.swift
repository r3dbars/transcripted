import AppKit
import QuartzCore

/// The card's small motions, kept apart from its layout. All of them step aside for Reduce Motion.
@MainActor
enum NextSentenceMotion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// A different version of the message: the new text settles in from the direction it grew
    /// (longer comes from below, shorter from above) as it fades in.
    static func textChanged(_ layer: CALayer?, direction: Int) {
        guard let layer, !reduced else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.2
        layer.add(fade, forKey: "fade")
        guard direction != 0 else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = direction > 0 ? 5 : -5
        slide.toValue = 0
        slide.duration = 0.22
        slide.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.1)
        layer.add(slide, forKey: "slide")
    }

    /// A light that sweeps across "Reading your context…" while it waits.
    static func shimmer(_ view: NSView, on: Bool) {
        guard let layer = view.layer else { return }
        guard on, !reduced else { layer.mask = nil; return }
        guard layer.mask == nil else { return }
        let mask = CAGradientLayer()
        mask.frame = layer.bounds.insetBy(dx: -layer.bounds.width, dy: 0)
        mask.startPoint = CGPoint(x: 0, y: 0.5)
        mask.endPoint = CGPoint(x: 1, y: 0.5)
        let dim = NSColor(white: 1, alpha: 0.45).cgColor
        mask.colors = [dim, dim, NSColor.white.cgColor, dim, dim]
        mask.locations = [0, 0.4, 0.5, 0.6, 1]
        layer.mask = mask
        let sweep = CABasicAnimation(keyPath: "transform.translation.x")
        sweep.fromValue = -layer.bounds.width
        sweep.toValue = layer.bounds.width
        sweep.duration = 1.4
        sweep.repeatCount = .infinity
        mask.add(sweep, forKey: "shimmer")
    }

    /// A quick squash and settle, for the pad's dot landing in a cell.
    static func pop(_ layer: CALayer?) {
        guard let layer, !reduced else { return }
        let spring = CASpringAnimation(keyPath: "transform.scale")
        spring.fromValue = 1.3
        spring.toValue = 1
        spring.stiffness = 420
        spring.damping = 14
        spring.duration = spring.settlingDuration
        layer.add(spring, forKey: "pop")
    }

    static func scale(_ factor: CGFloat, about corner: CGPoint) -> CATransform3D {
        CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-corner.x, -corner.y, 0), CATransform3DMakeScale(factor, factor, 1)),
            CATransform3DMakeTranslation(corner.x, corner.y, 0))
    }
}
