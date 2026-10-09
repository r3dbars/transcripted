import Foundation

/// Promises of the match animation the owner picked (CascadeD.dc.html,
/// "Pixel print"):
///   - the squares and burst dots are the mockup's, square for square, for the
///     same seed (counts, colors, pushes, opacities and delays match what the
///     mockup's script produced for priya-13, marcus-264 and dana-1);
///   - squares never sit in a ring's gap, so the pixel version shows the lock;
///   - the timeline matches the mockup's keyframes and ends by the time the
///     mockup drops the squares (1.9 s);
///   - Reduce Motion keeps only a quick crossfade.
func testVoicePrintCascadePlan() {
    typealias Plan = VoicePrintCascadePlan

    struct Expected {
        let seed: String
        let litRings: Int
        let count: Int
        let lit: Int
        let twinkles: Int
        let sumDX: Double
        let sumDY: Double
        let sumOpacity: Double
        let sumDelay: Double
    }

    // From the mockup's own script (gen ref of CascadeD.dc.html's PX.pixels).
    let pixelCases = [
        Expected(seed: "priya-13", litRings: 1, count: 55, lit: 12, twinkles: 5, sumDX: 14, sumDY: 7, sumOpacity: 20.04, sumDelay: 8.061),
        Expected(seed: "priya-13", litRings: 3, count: 77, lit: 53, twinkles: 13, sumDX: -7, sumDY: -9, sumOpacity: 49.28, sumDelay: 11.395),
        Expected(seed: "priya-13", litRings: 4, count: 94, lit: 78, twinkles: 15, sumDX: -3, sumDY: -30, sumOpacity: 65.47, sumDelay: 14.558),
        Expected(seed: "priya-13", litRings: 5, count: 117, lit: 117, twinkles: 27, sumDX: 43, sumDY: -36, sumOpacity: 93.89, sumDelay: 20.572),
        Expected(seed: "marcus-264", litRings: 1, count: 62, lit: 13, twinkles: 7, sumDX: -4, sumDY: -5, sumOpacity: 22.51, sumDelay: 9.679),
        Expected(seed: "marcus-264", litRings: 4, count: 101, lit: 81, twinkles: 8, sumDX: 14, sumDY: 3, sumOpacity: 66.78, sumDelay: 15.591),
        Expected(seed: "marcus-264", litRings: 5, count: 119, lit: 119, twinkles: 16, sumDX: -26, sumDY: 15, sumOpacity: 91.95, sumDelay: 20.99),
        Expected(seed: "dana-1", litRings: 1, count: 64, lit: 13, twinkles: 5, sumDX: 44, sumDY: -9, sumOpacity: 22.91, sumDelay: 10.468),
        Expected(seed: "dana-1", litRings: 3, count: 84, lit: 54, twinkles: 11, sumDX: 52, sumDY: -12, sumOpacity: 50.7, sumDelay: 13.105),
        Expected(seed: "dana-1", litRings: 5, count: 119, lit: 119, twinkles: 22, sumDX: 118, sumDY: -52, sumOpacity: 94.13, sumDelay: 21.801),
    ]

    runSuite("The pixel print matches the mockup square for square") {
        for expected in pixelCases {
            let style = VoicePrintStyle(seedString: expected.seed)
            let kind: Plan.Kind = expected.litRings == 5 ? .full : .small
            let pixels = Plan.pixels(gapAngles: style.gapAngles, litRings: expected.litRings, kind: kind, seedBase: expected.seed)
            let label = "\(expected.seed) x\(expected.litRings)"
            assertEqual(pixels.count, expected.count, "\(label) squares")
            assertEqual(pixels.filter(\.isLit).count, expected.lit, "\(label) lit squares")
            assertEqual(pixels.filter { $0.twinkleDelay != nil }.count, expected.twinkles, "\(label) twinkles")
            assertEqual(pixels.reduce(0) { $0 + $1.dx }, expected.sumDX, "\(label) pushes x")
            assertEqual(pixels.reduce(0) { $0 + $1.dy }, expected.sumDY, "\(label) pushes y")
            // The mockup prints opacity to 2 places and delays to 3.
            assertVoicePrintClose(pixels.reduce(0) { $0 + $1.opacity }, expected.sumOpacity, "\(label) opacity", tolerance: 0.005 * Double(expected.count))
            assertVoicePrintClose(pixels.reduce(0) { $0 + $1.delay }, expected.sumDelay, "\(label) delays", tolerance: 0.0005 * Double(expected.count))
            assertTrue(pixels.allSatisfy { $0.isNew == ($0.band == expected.litRings - 1) }, "\(label) new ring is the last lit")
        }
        let first = Plan.pixels(gapAngles: VoicePrintStyle(seedString: "priya-13").gapAngles, litRings: 1, kind: .small, seedBase: "priya-13")[0]
        assertEqual([first.x, first.y, first.dx, first.dy], [0, -21, 0, -4], "top square of the outer ring pushes straight up")
        assertFalse(first.isLit, "an unearned ring's square is dim")
        assertVoicePrintClose(first.opacity, 0.18, tolerance: 0.005)
        assertVoicePrintClose(first.delay, 0.231, tolerance: 0.0005)
    }

    runSuite("The full version's burst matches the mockup") {
        let cases: [(String, Int, Int, Double, Double, Double, Double)] = [
            ("priya-13", 86, 10, 361, -19, 50.0, 33.772),
            ("marcus-264", 87, 12, -203, 53, 53.91, 34.075),
            ("dana-1", 87, 10, 488, -249, 50.2, 34.511),
        ]
        for (seed, count, twinkles, sumDX, sumDY, sumOpacity, sumDelay) in cases {
            let dots = Plan.burst(gapAngles: VoicePrintStyle(seedString: seed).gapAngles, seedBase: seed)
            assertEqual(dots.count, count, "\(seed) dots")
            assertEqual(dots.filter { $0.twinkleDelay != nil }.count, twinkles, "\(seed) twinkling dots")
            assertEqual(dots.reduce(0) { $0 + $1.dx }, sumDX, "\(seed) travel x")
            assertEqual(dots.reduce(0) { $0 + $1.dy }, sumDY, "\(seed) travel y")
            assertVoicePrintClose(dots.reduce(0) { $0 + $1.opacity }, sumOpacity, "\(seed) opacity", tolerance: 0.005 * Double(count))
            assertVoicePrintClose(dots.reduce(0) { $0 + $1.delay }, sumDelay, "\(seed) delays", tolerance: 0.0005 * Double(count))
            for dot in dots {
                let landing = (dot.x + dot.dx, dot.y + dot.dy)
                assertEqual(landing.0.truncatingRemainder(dividingBy: Plan.pitch), 0, "\(seed) lands on the 3-point grid")
                assertEqual(landing.1.truncatingRemainder(dividingBy: Plan.pitch), 0, "\(seed) lands on the 3-point grid")
            }
        }
    }

    runSuite("No square or burst dot sits in a gap, so the pixel print shows the lock") {
        for seed in ["priya-13", "marcus-264", "dana-1", "someone-else"] {
            let gaps = VoicePrintStyle(seedString: seed).gapAngles
            for pixel in Plan.pixels(gapAngles: gaps, litRings: 5, kind: .full, seedBase: seed) {
                let angle = VoicePrintGeometry.normalized(atan2(pixel.y, pixel.x) * 180 / .pi)
                assertFalse(Plan.isInGap(angle: angle, gapCenter: gaps[pixel.band]), "\(seed) square in ring \(pixel.band)'s gap")
                let distance = hypot(pixel.x, pixel.y)
                assertTrue(distance >= Plan.innerClearRadius && distance <= Plan.outerRadius, "\(seed) square on a ring band, play button clear")
            }
            for dot in Plan.burst(gapAngles: gaps, seedBase: seed) {
                let angle = VoicePrintGeometry.normalized(atan2(dot.y, dot.x) * 180 / .pi)
                let ring = Plan.burstRings[dot.ring]
                // Start points are rounded to whole points, so allow a few degrees.
                assertTrue(VoicePrintStyle.angularDistance(angle, gaps[ring.gapRing]) > VoicePrintGeometry.gapHalfAngle - 4, "\(seed) burst dot in its gap")
            }
        }
        assertEqual(Plan.pixels(gapAngles: [0, 90], litRings: 3, kind: .small, seedBase: "x").count, 0, "a malformed style draws nothing")
    }

    runSuite("The timeline matches the mockup's keyframes and ends by 1.9 s") {
        let small = Plan.timing(.small)
        let full = Plan.timing(.full)
        assertEqual([small.pixelDuration, small.ringDuration, small.bandStagger], [1.0, 1.12, 0.035], "small timing")
        assertEqual([full.pixelDuration, full.ringDuration, full.bandStagger], [1.15, 1.3, 0.04], "full timing")
        assertEqual([small.twinkles, full.twinkles], [1, 2], "twinkle repeats")
        assertEqual(Plan.pixelPush.keyTimes, [0, 0.12, 0.38, 0.46, 0.68, 1], "push out by 38%, snap back by 68%")
        assertEqual(Plan.pixelPush.values, [0, 0, 1, 1, 0, 0])
        assertEqual(Plan.pixelScale.values, [0.3, 1, 1, 1, 1, 1], "squares grow in from 0.3")
        assertEqual(Plan.pixelOpacity.keyTimes, [0, 0.12, 0.68, 0.8, 1])
        assertEqual(Plan.ringOpacity.values, [1, 0.05, 0.05, 1, 1], "rings dissolve to 5% and return")
        assertEqual(Plan.newRingWidth.values.max(), 2.9, "the new ring bumps to 2.9")
        assertEqual(Plan.glowDuration, 1.35)
        assertEqual(Plan.glowBlur.values, [0, 0, 13, 7], "bloom to 13, settle at the resting 7")
        assertEqual(Plan.glowOpacity(steady: 0.5).values, [0, 0, 1, 0.5])
        assertEqual(Plan.landedDelay, 0.82)
        assertEqual(Plan.rippleDuration, 0.8)
        assertEqual(Plan.rippleStagger, 0.11)
        let tracks = [Plan.pixelOpacity, Plan.pixelScale, Plan.pixelPush, Plan.twinkle, Plan.ringOpacity, Plan.newRingWidth, Plan.glowBlur, Plan.burstOpacity, Plan.ripple, Plan.reducedPixelOpacity, Plan.glowOpacity(steady: 0)]
        for track in tracks {
            assertEqual(track.values.count, track.keyTimes.count, "a value per key time")
            assertEqual(track.curves.count, track.keyTimes.count - 1, "a curve between key times")
            assertEqual(track.keyTimes.first, 0)
            assertEqual(track.keyTimes.last, 1)
        }

        for seed in ["priya-13", "marcus-264", "dana-1"] {
            let gaps = VoicePrintStyle(seedString: seed).gapAngles
            for (lit, kind) in [(1, Plan.Kind.small), (4, .small), (5, .full)] {
                let timing = Plan.timing(kind)
                for pixel in Plan.pixels(gapAngles: gaps, litRings: lit, kind: kind, seedBase: seed) {
                    assertTrue(pixel.delay + timing.pixelDuration <= Plan.finishedBy, "\(seed) square done in time")
                    if let twinkle = pixel.twinkleDelay {
                        assertTrue(twinkle + Double(timing.twinkles) * Plan.pixelTwinkleDuration <= Plan.finishedBy, "\(seed) twinkle done in time")
                    }
                }
                let lastRing = Double(VoicePrintGeometry.ringCount - 1) * timing.bandStagger + timing.ringDuration
                assertTrue(lastRing <= Plan.finishedBy, "rings back in time")
            }
            for dot in Plan.burst(gapAngles: gaps, seedBase: seed) {
                assertTrue(dot.delay + dot.duration <= Plan.finishedBy, "\(seed) burst done in time")
            }
        }
    }

    runSuite("Small on every yes, full when the print completes; Reduce Motion only crossfades") {
        assertNil(Plan.kind(forLitRings: 0), "an empty print doesn't celebrate")
        assertEqual(Plan.kind(forLitRings: 1), .small)
        assertEqual(Plan.kind(forLitRings: 4), .small)
        assertEqual(Plan.kind(forLitRings: 5), .full)
        assertEqual(Plan.kind(forLitRings: 7), .full, "past five is still complete")

        let full = Plan.steps(.full, reduceMotion: false, isPlaying: false)
        assertTrue(full.movesPixels && full.twinkles && full.dissolvesRings && full.bursts && full.bloomsGlow, "full version runs everything")
        assertFalse(full.fadesGlow)
        let small = Plan.steps(.small, reduceMotion: false, isPlaying: false)
        assertTrue(small.movesPixels && small.dissolvesRings, "small version moves squares and dissolves rings")
        assertFalse(small.bursts || small.bloomsGlow, "no burst or bloom until the print completes")
        assertFalse(Plan.steps(.small, reduceMotion: false, isPlaying: true).dissolvesRings, "the playback ripple keeps the rings")

        for kind in [Plan.Kind.small, .full] {
            let calm = Plan.steps(kind, reduceMotion: true, isPlaying: false)
            assertFalse(calm.movesPixels || calm.twinkles || calm.dissolvesRings || calm.bursts || calm.bloomsGlow, "Reduce Motion: no movement")
            assertEqual(calm.pixelDuration, 0.45, "squares just fade, quickly")
        }
        assertTrue(Plan.steps(.full, reduceMotion: true, isPlaying: false).fadesGlow, "a completed print's glow fades in")
        assertFalse(Plan.steps(.small, reduceMotion: true, isPlaying: false).fadesGlow)
        assertEqual(Plan.reducedPixelOpacity.values, [0, 1, 0], "fade in and out where they sit")
    }

    runSuite("Hosts know how far past the print the cascade draws") {
        assertTrue(Plan.outset(.full) >= 63 + 1 - 21, "the burst's outer ring lands 63 out")
        assertTrue(Plan.outset(.small) < Plan.outset(.full), "the small version stays close")
        assertTrue(Plan.outset(.small) >= Plan.outerRadius + 4.8 - 21, "covers the farthest push")
        let style = VoicePrintStyle(seedString: "priya-13")
        let farthestBurst = Plan.burst(gapAngles: style.gapAngles, seedBase: "priya-13").map { hypot($0.x + $0.dx, $0.y + $0.dy) }.max() ?? 0
        assertTrue(farthestBurst + 1 <= Plan.reach(.full), "every burst dot inside the reach")
        let farthestPush = Plan.pixels(gapAngles: style.gapAngles, litRings: 4, kind: .small, seedBase: "priya-13").map { hypot($0.x + $0.dx, $0.y + $0.dy) }.max() ?? 0
        assertTrue(farthestPush + 1.5 <= Plan.reach(.small), "every pushed square inside the reach")
    }

    runSuite("The footer's named-automatically moment plays after the print, one beat at a time") {
        typealias Landing = Plan.FooterLanding
        let fullPrintSettles = Plan.timing(.full).pixelDuration
        assertTrue(Landing.dotDelay >= fullPrintSettles, "the dot waits until the print has settled")
        assertTrue(Landing.sparkleDelay > 0 && Landing.sparkleDelay < Landing.dotPopDuration, "the sparkle follows the dot, mid-pop")
        assertTrue(Landing.countDelay > Landing.sparkleDelay, "the count ticks up last")
        assertTrue(Landing.dotPopDuration > 0.55 && Landing.countTickDuration > 0.5 && Landing.sparkleDuration > 0.62,
                   "each beat is slower than the first cut")
    }
}
