// VoicePrintCascadePlan.swift
// The match animation the owner picked, "Cascade D: Pixel print"
// (CascadeD.dc.html), as plain numbers. On a yes the print briefly redraws
// itself as a 3-point LED grid of 2-point squares; the squares push out and
// snap back while the solid rings dissolve and return, and the ring just
// earned lands with a small stroke bump. Squares inside a ring's gap stay dark,
// so even the pixel version shows the person's own lock, and the sweep starts
// from the gap of the ring that just lit. When the print completes (the full
// version) three square-dot rings race out and the glow blooms.
//
// Ported number for number from the mockup, including its hash and PRNG and
// JavaScript's rounding, so a person's sparkle is the same every time.
// Foundation-only for the fast tests; VoicePrintView+Cascade.swift turns it
// into Core Animation. Positions are design points from the print's center,
// y down; times are seconds from the moment the cascade starts.

import Foundation

enum VoicePrintCascadePlan {
    /// Small on every confirm; full when the print reaches five rings.
    enum Kind: Equatable {
        case small
        case full
    }

    struct Timing: Equatable {
        /// Each square's own animation.
        let pixelDuration: Double
        /// Delay per ring band, innermost first (squares and solid rings).
        let bandStagger: Double
        /// Extra delay for a square half way round from the sweep's origin.
        let sweep: Double
        /// How far squares push out: base + per band + random share.
        let pushBase: Double
        let pushPerBand: Double
        let pushJitter: Double
        /// How many times a twinkling square flashes.
        let twinkles: Int
        /// The solid rings' dissolve and return.
        let ringDuration: Double
    }

    /// A cubic Bézier easing, as CSS `cubic-bezier(c1x, c1y, c2x, c2y)`.
    struct Curve: Equatable {
        let c1x: Double
        let c1y: Double
        let c2x: Double
        let c2y: Double

        init(_ c1x: Double, _ c1y: Double, _ c2x: Double, _ c2y: Double) {
            self.c1x = c1x
            self.c1y = c1y
            self.c2x = c2x
            self.c2y = c2y
        }

        static let linear = Curve(0, 0, 1, 1)
        static let ease = Curve(0.25, 0.1, 0.25, 1)
        static let easeInOut = Curve(0.42, 0, 0.58, 1)
        static let easeOut = Curve(0, 0, 0.58, 1)
    }

    /// One keyframed value: `values` at `keyTimes` (shares of the duration),
    /// easing into each next keyframe along `curves`.
    struct Track: Equatable {
        let keyTimes: [Double]
        let values: [Double]
        let curves: [Curve]
    }

    /// One square of the pixel print.
    struct Pixel: Equatable {
        /// Center, design points from the print's center, y down.
        let x: Double
        let y: Double
        /// The ring it belongs to, innermost 0.
        let band: Int
        let isLit: Bool
        /// On the ring that just lit.
        let isNew: Bool
        let opacity: Double
        /// Where the push takes it, whole design points.
        let dx: Double
        let dy: Double
        let delay: Double
        /// When it flashes white; nil when it doesn't twinkle.
        let twinkleDelay: Double?
    }

    /// One dot of the full version's burst.
    struct BurstDot: Equatable {
        /// Start, on the print's edge.
        let x: Double
        let y: Double
        /// Travel, landing on the 3-point grid.
        let dx: Double
        let dy: Double
        /// Which of the three burst rings, innermost 0.
        let ring: Int
        let opacity: Double
        let duration: Double
        let delay: Double
        let twinkleDelay: Double?
    }

    struct BurstRing: Equatable {
        let dots: Int
        /// Where its dots land, design points from the center.
        let reach: Double
        let opacity: Double
        /// It leaves a gap where this print ring has its gap.
        let gapRing: Int
    }

    /// What one cascade runs. Without Reduce Motion that's the whole mockup;
    /// with it, only a quick crossfade: squares fade in and out where they sit,
    /// all at once, and a completed print's glow fades up. Ring colors
    /// crossfade either way (the mockup's stroke transition).
    struct Steps: Equatable {
        /// Squares push out, snap back and start in a sweep; otherwise they
        /// only fade, all at once, over `pixelDuration`.
        let movesPixels: Bool
        let twinkles: Bool
        /// The solid rings dissolve and return, the new one with a stroke
        /// bump. Skipped while the clip plays: the playback ripple owns the
        /// rings' opacity, as in the mockup.
        let dissolvesRings: Bool
        let bursts: Bool
        let bloomsGlow: Bool
        let fadesGlow: Bool
        let pixelDuration: Double
    }

    /// The cascade for a print that now has `litRings` lit: none for an empty
    /// print, the full version when it completes, else the small one.
    static func kind(forLitRings litRings: Int) -> Kind? {
        let lit = VoicePrintGeometry.clampedLitRings(litRings)
        guard lit > 0 else { return nil }
        return lit == VoicePrintGeometry.ringCount ? .full : .small
    }

    static func steps(_ kind: Kind, reduceMotion: Bool, isPlaying: Bool) -> Steps {
        if reduceMotion {
            return Steps(
                movesPixels: false,
                twinkles: false,
                dissolvesRings: false,
                bursts: false,
                bloomsGlow: false,
                fadesGlow: kind == .full,
                pixelDuration: reducedPixelDuration
            )
        }
        return Steps(
            movesPixels: true,
            twinkles: true,
            dissolvesRings: !isPlaying,
            bursts: kind == .full,
            bloomsGlow: kind == .full,
            fadesGlow: false,
            pixelDuration: timing(kind).pixelDuration
        )
    }

    static func timing(_ kind: Kind) -> Timing {
        switch kind {
        case .small:
            return Timing(pixelDuration: 1.0, bandStagger: 0.035, sweep: 0.12, pushBase: 1.6, pushPerBand: 0.45, pushJitter: 1.4, twinkles: 1, ringDuration: 1.12)
        case .full:
            return Timing(pixelDuration: 1.15, bandStagger: 0.04, sweep: 0.12, pushBase: 2.4, pushPerBand: 0.9, pushJitter: 2.2, twinkles: 2, ringDuration: 1.3)
        }
    }

    // MARK: - Squares

    static let pitch = 3.0
    static let squareSize = 2.0
    static let squareCornerRadius = 0.5
    /// Squares closer than this stay off, keeping the play button clear.
    static let innerClearRadius = 6.6
    static let outerRadius = 21.3
    static let pixelTwinkleDuration = 0.34
    static let burstTwinkleDuration = 0.3
    /// CSS blur of a twinkling square's glow, design points.
    static let twinkleGlowBlur = 4.0

    /// Square opacity, as a share of the square's own opacity.
    static let pixelOpacity = Track(
        keyTimes: [0, 0.12, 0.68, 0.8, 1],
        values: [0, 1, 1, 1, 0],
        curves: [Curve(0.2, 0.9, 0.3, 1), Curve(0.16, 0.84, 0.3, 1), Curve(0.4, 0, 0.6, 1), .linear]
    )
    /// Square scale. Shares `pixelPush`'s key times and curves, so the two
    /// make one transform.
    static let pixelScale = Track(
        keyTimes: [0, 0.12, 0.38, 0.46, 0.68, 1],
        values: [0.3, 1, 1, 1, 1, 1],
        curves: pixelMoveCurves
    )
    /// How far out the square is, as a share of its push. The snap back
    /// overshoots a little toward the center.
    static let pixelPush = Track(
        keyTimes: [0, 0.12, 0.38, 0.46, 0.68, 1],
        values: [0, 0, 1, 1, 0, 0],
        curves: pixelMoveCurves
    )
    private static let pixelMoveCurves = [
        Curve(0.2, 0.9, 0.3, 1), Curve(0.16, 0.84, 0.3, 1), .linear, Curve(0.5, 0, 0.3, 1.45), Curve(0.4, 0, 0.6, 1),
    ]
    /// A twinkle: the share of the flash (white, plus a glow in the square's
    /// color) over one flash.
    static let twinkle = Track(keyTimes: [0, 0.5, 1], values: [0, 1, 0], curves: [.easeInOut, .easeInOut])

    // MARK: - Solid rings and glow

    /// Every ring dissolves (inner first) as the squares take over, then
    /// comes back as they snap home.
    static let ringOpacity = Track(
        keyTimes: [0, 0.08, 0.62, 0.76, 1],
        values: [1, 0.05, 0.05, 1, 1],
        curves: [Curve(0.4, 0, 0.6, 1), .linear, Curve(0.3, 0, 0.2, 1), .linear]
    )
    /// The ring just earned lands with a stroke bump, design points.
    static let newRingWidth = Track(
        keyTimes: [0, 0.62, 0.76, 1],
        values: [1.8, 1.8, 2.9, 1.8],
        curves: [Curve(0.4, 0, 0.6, 1), Curve(0.3, 0, 0.2, 1), Curve(0.4, 0, 0.2, 1)]
    )
    static let glowDuration = 1.35
    /// Full version: the glow blooms past its resting strength, then settles
    /// at `steady` (the complete print's glow, 0 where prints don't glow).
    static func glowOpacity(steady: Double) -> Track {
        Track(keyTimes: [0, 0.58, 0.74, 1], values: [0, 0, 1, steady], curves: [.linear, .linear, .linear])
    }

    /// The bloom's CSS blur, design points; it settles at the resting glow.
    static let glowBlur = Track(
        keyTimes: [0, 0.58, 0.74, 1],
        values: [0, 0, 13, VoicePrintGeometry.glowBlur],
        curves: [.linear, .linear, .linear]
    )

    // MARK: - Burst (full version only)

    static let burstRings = [
        BurstRing(dots: 28, reach: 39, opacity: 0.95, gapRing: 2),
        BurstRing(dots: 36, reach: 51, opacity: 0.7, gapRing: 3),
        BurstRing(dots: 44, reach: 63, opacity: 0.48, gapRing: 4),
    ]
    static let burstStartRadius = 21.0
    static let burstEndScale = 0.55
    static let burstMoveCurve = Curve(0.12, 0.78, 0.24, 1)
    /// Burst dot opacity, as a share of the dot's own.
    static let burstOpacity = Track(keyTimes: [0, 0.07, 0.45, 1], values: [0, 1, 0.72, 0], curves: [.linear, .linear, .linear])

    // MARK: - Playback, Reduce Motion, cleanup

    /// While a clip plays the rings ripple outward, looping.
    static let rippleDuration = 0.8
    static let rippleStagger = 0.11
    static let ripple = Track(keyTimes: [0, 0.5, 1], values: [0.25, 1, 0.25], curves: [.easeInOut, .easeInOut])
    /// The well brightens or dims when playback starts or stops.
    static let wellFadeDuration = 0.2
    /// A ring changing color crossfades (the mockup's `transition: stroke .5s ease`).
    static let colorFadeDuration = 0.5
    /// Reduce Motion: squares only fade in and out where they sit, all at
    /// once; no push, twinkle, burst, dissolve or bloom.
    static let reducedPixelDuration = 0.45
    static let reducedPixelOpacity = Track(keyTimes: [0, 0.35, 1], values: [0, 1, 0], curves: [.easeOut, .easeOut])
    /// Reduce Motion: the glow fades in this fast instead of blooming.
    static let reducedGlowFade = 0.5
    /// When the full version's print has re-formed (the mockup ticks the
    /// "named automatically" counter here); 0 under Reduce Motion.
    static let landedDelay = 0.82
    /// The footer's "named automatically" moment plays after the print, one
    /// beat at a time, so it never lands on top of the cascade: the dot waits
    /// until the print has settled, pops in, its sparkle follows, and the count
    /// ticks up last (owner feedback 2026-10-09: it all happened at once).
    enum FooterLanding {
        /// From the ✓ to the dot starting to pop in.
        static let dotDelay = 1.45
        static let dotPopDuration = 0.85
        /// From the dot starting to the sparkle starting.
        static let sparkleDelay = 0.35
        static let sparkleDuration = 0.9
        static let sparkleStagger = 0.03
        /// From the dot starting to the count starting to tick up.
        static let countDelay = 0.6
        static let countTickDuration = 0.8
    }

    /// By now every square and dot has finished (the mockup drops them here).
    static let finishedBy = 1.9

    // MARK: - Squares and dots

    /// The pixel print for `litRings` lit rings, squares in the mockup's order.
    static func pixels(gapAngles: [Double], litRings: Int, kind: Kind, seedBase: String) -> [Pixel] {
        guard gapAngles.count == VoicePrintGeometry.ringCount else { return [] }
        let count = VoicePrintGeometry.clampedLitRings(litRings)
        let timing = timing(kind)
        let fresh = count - 1
        let origin = gapAngles[max(0, fresh)]
        var pixels: [Pixel] = []
        for cell in cells(gapAngles: gapAngles, seedBase: seedBase) {
            let isLit = cell.band < count
            // Rings not earned yet stay sparse.
            if !isLit && cell.b > 0.45 { continue }
            let isNew = cell.band == fresh
            let twinkles = isLit && cell.c < (isNew ? 0.34 : 0.12)
            let opacity: Double
            if twinkles {
                opacity = 1
            } else if isNew {
                opacity = 0.85 + 0.15 * cell.b
            } else if isLit {
                opacity = 0.48 + 0.4 * cell.b
            } else {
                opacity = 0.12 + 0.16 * cell.a
            }
            let push = timing.pushBase + Double(cell.band) * timing.pushPerBand + cell.e * timing.pushJitter
            let delay = Double(cell.band) * timing.bandStagger
                + angularDistance(cell.angle, origin) / 180 * timing.sweep
                + cell.a * 0.03
            pixels.append(Pixel(
                x: cell.x,
                y: cell.y,
                band: cell.band,
                isLit: isLit,
                isNew: isNew,
                opacity: opacity,
                dx: jsRound(cell.x / cell.distance * push),
                dy: jsRound(cell.y / cell.distance * push),
                delay: delay,
                twinkleDelay: twinkles ? delay + (0.26 + cell.e * 0.2) * timing.pixelDuration : nil
            ))
        }
        return pixels
    }

    /// The full version's three dot rings, each leaving a gap where one of
    /// the person's outer rings has its gap.
    static func burst(gapAngles: [Double], seedBase: String) -> [BurstDot] {
        guard gapAngles.count == VoicePrintGeometry.ringCount else { return [] }
        let next = VoicePrintStyle.random(seed: VoicePrintStyle.seed(of: seedBase + ":burst"))
        let origin = gapAngles[VoicePrintGeometry.ringCount - 1]
        var dots: [BurstDot] = []
        for (ringIndex, ring) in burstRings.enumerated() {
            let step = 360 / Double(ring.dots)
            for index in 0..<ring.dots {
                let angle = Double(index) * step + (ringIndex % 2 == 1 ? step / 2 : 0)
                let jitter = next()
                let sparkle = next()
                if isInGap(angle: angle, gapCenter: gapAngles[ring.gapRing]) { continue }
                let radians = angle * .pi / 180
                let ux = cos(radians)
                let uy = sin(radians)
                let x0 = jsRound(ux * burstStartRadius)
                let y0 = jsRound(uy * burstStartRadius)
                // Land on the same 3-point grid as the print's own squares.
                let x1 = jsRound(ux * ring.reach / pitch) * pitch
                let y1 = jsRound(uy * ring.reach / pitch) * pitch
                let twinkles = sparkle < 0.16
                let delay = 0.26 + Double(ringIndex) * 0.07 + angularDistance(angle, origin) / 180 * 0.08 + jitter * 0.02
                dots.append(BurstDot(
                    x: x0,
                    y: y0,
                    dx: x1 - x0,
                    dy: y1 - y0,
                    ring: ringIndex,
                    opacity: twinkles ? 1 : ring.opacity * (0.6 + 0.4 * jitter),
                    duration: 0.85 + Double(ringIndex) * 0.08,
                    delay: delay,
                    twinkleDelay: twinkles ? delay + 0.12 + jitter * 0.2 : nil
                ))
            }
        }
        return dots
    }

    /// The farthest the cascade draws from the print's center, design points,
    /// with a grid step of margin for square corners, whole-point rounding and
    /// the twinkle glow. The full version's burst lands up to 63 out (fading
    /// as it goes); the small version stays near the rings.
    static func reach(_ kind: Kind) -> Double {
        switch kind {
        case .small:
            let timing = timing(.small)
            let push = timing.pushBase + Double(VoicePrintGeometry.ringCount - 1) * timing.pushPerBand + timing.pushJitter
            return outerRadius + push + pitch
        case .full:
            return (burstRings.map(\.reach).max() ?? 0) + pitch
        }
    }

    /// How far past the print's 42-point box the cascade draws, design points.
    /// Hosts leave this unclipped around the print.
    static func outset(_ kind: Kind) -> Double {
        reach(kind) - VoicePrintGeometry.designSize / 2
    }

    /// The app's style doesn't keep the saved ID, so the sparkle seeds from
    /// what makes the print theirs: the gap angles and the color.
    static func seedBase(for style: VoicePrintStyle) -> String {
        style.gapAngles.map { String(Int($0)) }.joined(separator: ",") + "/" + String(style.preferredColorIndex)
    }

    /// Inside the 20% gap centered on `gapCenter`.
    static func isInGap(angle: Double, gapCenter: Double) -> Bool {
        angularDistance(angle, gapCenter) < VoicePrintGeometry.gapHalfAngle
    }

    // MARK: - Private

    private struct Cell {
        let x: Double
        let y: Double
        let distance: Double
        let band: Int
        let angle: Double
        let a: Double
        let b: Double
        let c: Double
        let e: Double
    }

    /// Every grid square on a ring band and outside that ring's gap, rows top
    /// to bottom, each with four random draws in the mockup's order.
    private static func cells(gapAngles: [Double], seedBase: String) -> [Cell] {
        let next = VoicePrintStyle.random(seed: VoicePrintStyle.seed(of: seedBase + ":px"))
        var cells: [Cell] = []
        for row in -7...7 {
            for column in -7...7 {
                let x = Double(column) * pitch
                let y = Double(row) * pitch
                let distance = hypot(x, y)
                if distance < innerClearRadius || distance > outerRadius { continue }
                let band = max(0, min(VoicePrintGeometry.ringCount - 1, Int(jsRound((distance - 8) / 2.9))))
                let angle = VoicePrintGeometry.normalized(atan2(y, x) * 180 / .pi)
                if isInGap(angle: angle, gapCenter: gapAngles[band]) { continue }
                let a = next()
                let b = next()
                let c = next()
                let e = next()
                cells.append(Cell(x: x, y: y, distance: distance, band: band, angle: angle, a: a, b: b, c: c, e: e))
            }
        }
        return cells
    }

    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(VoicePrintGeometry.normalized(a) - VoicePrintGeometry.normalized(b))
        return min(d, 360 - d)
    }

    /// JavaScript's Math.round: halves round up, also below zero.
    private static func jsRound(_ value: Double) -> Double {
        (value + 0.5).rounded(.down)
    }
}
