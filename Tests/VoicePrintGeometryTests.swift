import Foundation

/// Promises of how a voice print is drawn (the approved Prints.dc.html):
///   - each ring is a 288-degree arc whose open part is centered on the
///     person's gap angle, measured clockwise on screen from 3 o'clock (y down);
///   - the first `litRings` rings take the person's color, the rest a faint
///     neutral, on dark and light surfaces;
///   - only a complete print glows, and only on dark surfaces;
///   - the print scales from the 42-point design box to any diameter;
///   - VoiceOver hears a play button named for the person.
func testVoicePrintGeometry() {
    typealias Geometry = VoicePrintGeometry

    runSuite("Each ring's gap sits at the person's angle, as in the mockup") {
        let people: [(String, [Double])] = [
            ("priya-13", [30, 120, 45, 135, 210]),
            ("marcus-264", [270, 195, 270, 135, 345]),
            ("dana-1", [180, 255, 135, 195, 135]),
        ]
        for (seed, gaps) in people {
            let arcs = Geometry.arcs(for: VoicePrintStyle(seedString: seed))
            assertEqual(arcs.map(\.gapCenter), gaps, "\(seed) gap centers")
            assertEqual(arcs.map(\.radius), [8, 10.9, 13.8, 16.7, 19.6], "\(seed) radii")
            for arc in arcs {
                assertEqual(arc.endAngle - arc.startAngle, 288, "\(seed) stroke runs 80% of the ring")
                assertTrue(arc.startAngle >= 0 && arc.startAngle < 360, "\(seed) start normalized")
            }
        }
    }

    runSuite("A ring's stroke starts just after its gap and ends just before it") {
        let priya = Geometry.arcs(for: VoicePrintStyle(seedString: "priya-13"))
        // The mockup rotates each dashed ring by gap + 36 degrees.
        assertEqual(priya.map(\.startAngle), [66, 156, 81, 171, 246], "priya starts")
        assertEqual(priya[0].endAngle, 354, "priya inner ring ends 36 degrees before its gap at 30")
        let marcus = Geometry.arcs(for: VoicePrintStyle(seedString: "marcus-264"))
        assertEqual(marcus[0].startAngle, 306, "gap at 270 starts the stroke at 306")
        assertEqual(marcus[0].endAngle, 594, "and runs on past 360 to 234 (594)")
        assertEqual(marcus[4].startAngle, 21, "gap at 345 wraps the start to 21")
    }

    runSuite("Angles run clockwise on screen from 3 o'clock with y down") {
        let right = Geometry.point(angle: 0, radius: 10)
        assertVoicePrintClose(right.x, 31, "0 degrees is to the right")
        assertVoicePrintClose(right.y, 21, "on the center line")
        let below = Geometry.point(angle: 90, radius: 10)
        assertVoicePrintClose(below.x, 21, "90 degrees is straight down")
        assertVoicePrintClose(below.y, 31, "y grows downward")
        let above = Geometry.point(angle: 270, radius: 10)
        assertVoicePrintClose(above.y, 11, "270 degrees is straight up")
    }

    runSuite("Lit rings take the person's color innermost first; the rest stay faint") {
        let dark = VoicePrintInk.ringColors(colorIndex: 0, litRings: 3, tone: .dark)
        let lavender = VoicePrintRGBA(hex: 0xB9A3FF)
        assertEqual(dark, [lavender, lavender, lavender, .white(0.14), .white(0.14)], "three of five lit on dark")
        let light = VoicePrintInk.ringColors(colorIndex: 0, litRings: 1, tone: .light)
        assertEqual(light[0], VoicePrintRGBA(hex: 0x7A5CF0), "light surfaces use the darker hex")
        assertEqual(Array(light[1...]), Array(repeating: VoicePrintRGBA.black(0.12), count: 4), "unlit on light")
        assertEqual(VoicePrintInk.ringColors(colorIndex: 2, litRings: 9, tone: .dark), Array(repeating: VoicePrintRGBA(hex: 0x6EC7FF), count: 5), "more than five counts as five")
        assertEqual(VoicePrintInk.ringColors(colorIndex: 2, litRings: -1, tone: .dark), Array(repeating: VoicePrintRGBA.white(0.14), count: 5), "below zero counts as none")
        assertEqual(VoicePrintInk.personColor(colorIndex: 9, tone: .dark), VoicePrintRGBA(hex: 0x8FA8FF), "index past the palette wraps")
        assertEqual(VoicePrintRGBA(hex: 0xFF86C2), VoicePrintRGBA(red: 1, green: 134.0 / 255, blue: 194.0 / 255), "hex unpacks to sRGB shares")
    }

    runSuite("Only a complete print glows, and only on dark surfaces") {
        assertVoicePrintClose(VoicePrintInk.glowOpacity(litRings: 5, tone: .dark), 136.0 / 255, "#RRGGBB88 glow")
        assertEqual(VoicePrintInk.glowOpacity(litRings: 4, tone: .dark), 0, "four rings don't glow")
        assertEqual(VoicePrintInk.glowOpacity(litRings: 5, tone: .light), 0, "light Settings shows no glow")
        assertEqual(Geometry.glowBlur, 7, "7-point blur as in the island mockup")
    }

    runSuite("The center well brightens while the clip plays") {
        assertEqual(VoicePrintInk.well(tone: .dark, isPlaying: false), .white(0.10), "resting well")
        assertEqual(VoicePrintInk.well(tone: .dark, isPlaying: true), .white(0.22), "playing well")
        assertEqual(VoicePrintInk.well(tone: .light, isPlaying: false), .black(0.45), "light well keeps the white glyph readable")
        assertEqual(VoicePrintInk.glyph, .white(1), "white glyph")
        assertEqual(Geometry.playTriangle.count, 3, "play is a triangle")
        assertEqual(Geometry.pauseBars.count, 2, "pause is two bars")
    }

    runSuite("The print scales from its 42-point design box") {
        assertEqual(Geometry.scale(forDiameter: 42), 1, "design size")
        assertEqual(Geometry.scale(forDiameter: 84), 2, "double")
        assertEqual(Geometry.scale(forDiameter: 21), 0.5, "half")
        assertEqual(Geometry.strokeWidth * Geometry.scale(forDiameter: 84), 3.6, "stroke scales with it")
        assertEqual(Geometry.wellRadius, 5.4, "well radius")
    }

    runSuite("VoiceOver hears a play button named for the person") {
        assertEqual(VoicePrintCopy.accessibilityLabel(name: "Priya", isPlaying: false), "Play Priya's clip")
        assertEqual(VoicePrintCopy.accessibilityLabel(name: "  ", isPlaying: false), "Play this voice", "a blank name falls back")
        assertEqual(VoicePrintCopy.accessibilityLabel(name: nil, isPlaying: false), "Play this voice")
        assertEqual(VoicePrintCopy.accessibilityLabel(name: "Priya", isPlaying: true), "Pause")
    }
}

func assertVoicePrintClose(_ actual: Double, _ expected: Double, _ message: String = "", tolerance: Double = 1e-9, file: String = #file, line: Int = #line) {
    assertTrue(abs(actual - expected) <= tolerance, "\(message): \(actual) != \(expected)", file: file, line: line)
}
