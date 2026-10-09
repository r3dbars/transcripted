// VoicePrintView+Cascade.swift
// The match animation on a VoicePrintView ("Cascade D: Pixel print"):
// VoicePrintCascadePlan's numbers turned into Core Animation. Squares are
// small CALayers taken from a pool when the cascade starts and handed back when
// it ends; every animation is added once and runs on the render server, and
// the cleanup rides the transaction's completion, so the main thread does no
// per-frame work. Under Reduce Motion the squares only fade where they sit,
// the new ring crossfades in and the glow fades up.

import AppKit

extension VoicePrintView {
    private enum Key {
        static let ringFade = "voicePrint.cascade.ringFade"
        static let ringWidth = "voicePrint.cascade.ringWidth"
        static let ringColor = "voicePrint.cascade.ringColor"
        static let glowOpacity = "voicePrint.cascade.glowOpacity"
        static let glowRadius = "voicePrint.cascade.glowRadius"
    }

    /// The most squares kept around between cascades (a full one uses ~200).
    private static let squarePoolLimit = 240

    /// Animate to `litRings` with the Cascade D match animation: small version
    /// when the new count < 5, full version when it reaches 5. Honors Reduce Motion.
    func celebrate(toLitRings litRings: Int) {
        stopCascade()
        let previousColors = ringLayers.map(\.strokeColor)
        let previousGlow = printLayer.shadowOpacity
        currentModel.litRings = litRings
        render()
        let target = VoicePrintGeometry.clampedLitRings(litRings)
        guard let kind = VoicePrintCascadePlan.kind(forLitRings: target) else { return }
        let steps = VoicePrintCascadePlan.steps(kind, reduceMotion: AccessibilityDisplayPolicy.reduceMotion, isPlaying: isPlaying)
        let generation = cascadeGeneration

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.cascadeGeneration == generation else { return }
                self.stopCascade()
            }
        }
        syncOrientation()
        let start = printLayer.convertTime(CACurrentMediaTime(), from: nil)
        crossfadeRingColors(from: previousColors, start: start)
        addSquares(target: target, kind: kind, steps: steps, start: start)
        if steps.dissolvesRings { dissolveRings(target: target, kind: kind, start: start) }
        if steps.bursts { addBurst(start: start) }
        if steps.bloomsGlow { bloomGlow(start: start) }
        if steps.fadesGlow { fadeGlow(from: previousGlow, start: start) }
        CATransaction.commit()
    }

    /// Stop any running animation and show the current model (Undo mid-animation).
    func cancelAnimations() {
        stopCascade()
        render()
    }

    /// Takes the cascade off: squares back to the pool, ring and glow
    /// animations removed. Playback's ripple and the hover scale stay.
    func stopCascade() {
        cascadeGeneration += 1
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for ring in ringLayers {
            removeRingCascade(from: ring)
            ring.removeAnimation(forKey: Key.ringColor)
        }
        printLayer.removeAnimation(forKey: Key.glowOpacity)
        printLayer.removeAnimation(forKey: Key.glowRadius)
        for square in liveSquares {
            square.removeAllAnimations()
            square.removeFromSuperlayer()
        }
        let room = max(0, Self.squarePoolLimit - squarePool.count)
        squarePool.append(contentsOf: liveSquares.prefix(room))
        liveSquares.removeAll()
        CATransaction.commit()
    }

    /// Drops a ring's dissolve (playback's ripple replaces it).
    func removeRingCascade(from ring: CAShapeLayer) {
        ring.removeAnimation(forKey: Key.ringFade)
        ring.removeAnimation(forKey: Key.ringWidth)
    }

    /// A keyframe animation of `track`, values multiplied by `factor`.
    static func keyframes(
        _ keyPath: String,
        _ track: VoicePrintCascadePlan.Track,
        factor: Double = 1,
        duration: Double,
        begin: CFTimeInterval
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = track.values.map { NSNumber(value: $0 * factor) }
        animation.keyTimes = track.keyTimes.map { NSNumber(value: $0) }
        animation.timingFunctions = track.curves.map(\.mediaTimingFunction)
        animation.duration = duration
        animation.beginTime = begin
        animation.fillMode = .backwards
        return animation
    }

    // MARK: - Rings and glow

    /// A ring that changed color fades into it (hidden under the dissolve,
    /// visible under Reduce Motion).
    private func crossfadeRingColors(from previous: [CGColor?], start: CFTimeInterval) {
        for (ring, old) in zip(ringLayers, previous) {
            guard let old, let new = ring.strokeColor, old != new else { continue }
            let fade = CABasicAnimation(keyPath: "strokeColor")
            fade.fromValue = old
            fade.toValue = new
            fade.duration = VoicePrintCascadePlan.colorFadeDuration
            fade.beginTime = start
            fade.fillMode = .backwards
            fade.timingFunction = VoicePrintCascadePlan.Curve.ease.mediaTimingFunction
            ring.add(fade, forKey: Key.ringColor)
        }
    }

    /// Every ring dissolves as the squares take over and comes back as they
    /// snap home; the new one lands with a stroke bump.
    private func dissolveRings(target: Int, kind: VoicePrintCascadePlan.Kind, start: CFTimeInterval) {
        let timing = VoicePrintCascadePlan.timing(kind)
        for (index, ring) in ringLayers.enumerated() {
            let begin = start + Double(index) * timing.bandStagger
            ring.add(Self.keyframes("opacity", VoicePrintCascadePlan.ringOpacity, duration: timing.ringDuration, begin: begin), forKey: Key.ringFade)
            guard index == target - 1 else { continue }
            let bump = Self.keyframes("lineWidth", VoicePrintCascadePlan.newRingWidth, factor: Double(scale), duration: timing.ringDuration, begin: begin)
            ring.add(bump, forKey: Key.ringWidth)
        }
    }

    /// Full version: the glow blooms as the print re-forms, then settles.
    private func bloomGlow(start: CFTimeInterval) {
        let steady = VoicePrintInk.glowOpacity(litRings: currentModel.litRings, tone: tone)
        let duration = VoicePrintCascadePlan.glowDuration
        printLayer.add(Self.keyframes("shadowOpacity", VoicePrintCascadePlan.glowOpacity(steady: steady), duration: duration, begin: start), forKey: Key.glowOpacity)
        // Core Animation's shadowRadius is half a CSS blur.
        let radius = Self.keyframes("shadowRadius", VoicePrintCascadePlan.glowBlur, factor: Double(scale) / 2, duration: duration, begin: start)
        printLayer.add(radius, forKey: Key.glowRadius)
    }

    /// Reduce Motion: the glow fades up instead of blooming.
    private func fadeGlow(from previous: Float, start: CFTimeInterval) {
        guard previous != printLayer.shadowOpacity else { return }
        let fade = CABasicAnimation(keyPath: "shadowOpacity")
        fade.fromValue = previous
        fade.toValue = printLayer.shadowOpacity
        fade.duration = VoicePrintCascadePlan.reducedGlowFade
        fade.beginTime = start
        fade.fillMode = .backwards
        fade.timingFunction = VoicePrintCascadePlan.Curve.ease.mediaTimingFunction
        printLayer.add(fade, forKey: Key.glowOpacity)
    }

    // MARK: - Squares

    private func addSquares(target: Int, kind: VoicePrintCascadePlan.Kind, steps: VoicePrintCascadePlan.Steps, start: CFTimeInterval) {
        let style = currentModel.style
        let pixels = VoicePrintCascadePlan.pixels(
            gapAngles: style.gapAngles,
            litRings: target,
            kind: kind,
            seedBase: VoicePrintCascadePlan.seedBase(for: style)
        )
        let timing = VoicePrintCascadePlan.timing(kind)
        let person = VoicePrintInk.personColor(colorIndex: currentModel.colorIndex, tone: tone).cgColor
        let unlit = VoicePrintInk.unlitSquare(tone: tone).cgColor
        for pixel in pixels {
            let color = pixel.isLit ? person : unlit
            let square = dequeueSquare(x: pixel.x, y: pixel.y, color: color)
            guard steps.movesPixels else {
                let fade = Self.keyframes("opacity", VoicePrintCascadePlan.reducedPixelOpacity, factor: pixel.opacity, duration: steps.pixelDuration, begin: start)
                Self.hold(fade, on: square, key: "fade")
                continue
            }
            let begin = start + pixel.delay
            let fade = Self.keyframes("opacity", VoicePrintCascadePlan.pixelOpacity, factor: pixel.opacity, duration: steps.pixelDuration, begin: begin)
            Self.hold(fade, on: square, key: "fade")
            Self.hold(pushAnimation(dx: pixel.dx, dy: pixel.dy, duration: steps.pixelDuration, begin: begin), on: square, key: "push")
            if steps.twinkles, let twinkleDelay = pixel.twinkleDelay {
                twinkle(square, color: color, begin: start + twinkleDelay, duration: VoicePrintCascadePlan.pixelTwinkleDuration, repeats: timing.twinkles)
            }
        }
    }

    /// Full version: three dot rings race out from the print and fade.
    private func addBurst(start: CFTimeInterval) {
        let style = currentModel.style
        let person = VoicePrintInk.personColor(colorIndex: currentModel.colorIndex, tone: tone).cgColor
        let endScale = CGFloat(VoicePrintCascadePlan.burstEndScale)
        for dot in VoicePrintCascadePlan.burst(gapAngles: style.gapAngles, seedBase: VoicePrintCascadePlan.seedBase(for: style)) {
            let square = dequeueSquare(x: dot.x, y: dot.y, color: person)
            let begin = start + dot.delay
            let move = CABasicAnimation(keyPath: "transform")
            move.fromValue = CATransform3DIdentity
            move.toValue = CATransform3DScale(CATransform3DMakeTranslation(CGFloat(dot.dx) * scale, CGFloat(dot.dy) * scale, 0), endScale, endScale, 1)
            move.duration = dot.duration
            move.beginTime = begin
            move.timingFunction = VoicePrintCascadePlan.burstMoveCurve.mediaTimingFunction
            Self.hold(move, on: square, key: "push")
            let fade = Self.keyframes("opacity", VoicePrintCascadePlan.burstOpacity, factor: dot.opacity, duration: dot.duration, begin: begin)
            Self.hold(fade, on: square, key: "fade")
            if let twinkleDelay = dot.twinkleDelay {
                twinkle(square, color: person, begin: start + twinkleDelay, duration: VoicePrintCascadePlan.burstTwinkleDuration, repeats: 1)
            }
        }
    }

    /// Out along the square's own spoke and back, scaling up from 0.3 on the way in.
    private func pushAnimation(dx: Double, dy: Double, duration: Double, begin: CFTimeInterval) -> CAKeyframeAnimation {
        let push = VoicePrintCascadePlan.pixelPush
        let growth = VoicePrintCascadePlan.pixelScale
        let animation = CAKeyframeAnimation(keyPath: "transform")
        animation.values = zip(push.values, growth.values).map { share, size in
            let moved = CATransform3DMakeTranslation(CGFloat(dx * share) * scale, CGFloat(dy * share) * scale, 0)
            return NSValue(caTransform3D: CATransform3DScale(moved, CGFloat(size), CGFloat(size), 1))
        }
        animation.keyTimes = push.keyTimes.map { NSNumber(value: $0) }
        animation.timingFunctions = push.curves.map(\.mediaTimingFunction)
        animation.duration = duration
        animation.beginTime = begin
        return animation
    }

    /// The square flashes white with a small glow in its own color.
    private func twinkle(_ square: CALayer, color: CGColor, begin: CFTimeInterval, duration: Double, repeats: Int) {
        let flash = CAKeyframeAnimation(keyPath: "backgroundColor")
        flash.values = [color, VoicePrintInk.twinkle.cgColor, color]
        flash.keyTimes = VoicePrintCascadePlan.twinkle.keyTimes.map { NSNumber(value: $0) }
        flash.timingFunctions = VoicePrintCascadePlan.twinkle.curves.map(\.mediaTimingFunction)
        flash.duration = duration
        flash.beginTime = begin
        flash.repeatCount = Float(repeats)
        square.add(flash, forKey: "twinkle")
        let glow = Self.keyframes("shadowOpacity", VoicePrintCascadePlan.twinkle, duration: duration, begin: begin)
        glow.repeatCount = Float(repeats)
        square.add(glow, forKey: "twinkleGlow")
    }

    /// Keeps the first and last frame on the square until the cascade ends,
    /// so nothing flashes at its resting state between animations.
    private static func hold(_ animation: CAAnimation, on square: CALayer, key: String) {
        animation.fillMode = .both
        animation.isRemovedOnCompletion = false
        square.add(animation, forKey: key)
    }

    /// A 2-point square at a design-point offset from the center, invisible
    /// until its animations run.
    private func dequeueSquare(x: Double, y: Double, color: CGColor) -> CALayer {
        let square = squarePool.popLast() ?? CALayer()
        let side = CGFloat(VoicePrintCascadePlan.squareSize) * scale
        let corner = CGFloat(VoicePrintCascadePlan.squareCornerRadius) * scale
        square.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        square.cornerRadius = corner
        square.position = CGPoint(x: CGFloat(x) * scale, y: CGFloat(y) * scale)
        square.transform = CATransform3DIdentity
        square.backgroundColor = color
        square.opacity = 0
        square.shadowColor = color
        square.shadowOpacity = 0
        square.shadowOffset = .zero
        square.shadowRadius = CGFloat(VoicePrintCascadePlan.twinkleGlowBlur / 2) * scale
        square.shadowPath = CGPath(roundedRect: square.bounds, cornerWidth: corner, cornerHeight: corner, transform: nil)
        effectsLayer.addSublayer(square)
        liveSquares.append(square)
        return square
    }
}
