// Source-text pins: the first suite reads Sources/App/TranscriptedApp.swift as text instead of calling
// refreshStatusItemPresentation(), because that method lives on TranscriptedAppDelegate (@MainActor
// NSApplicationDelegate) and only does anything once statusItem?.button exists — a real NSStatusItem this
// runner never creates, since it never runs applicationDidFinishLaunching. It greps the sliced method body
// for the glyph states and accessibility labels, and guards against a red or stock-symbol treatment that
// would make the always-visible capture icon alarming instead of quiet; its MenuBarGlyph checks render the
// real images (template flag, neutral ink) instead of reading MenuBarGlyph.swift. The second suite is real behavioral
// coverage: it renders every MenuBarGlyph into a bitmap and checks the silhouettes actually differ where
// they are meant to. The third keeps MenuBarGlyphGeometry (numbers and the drawn tail curves) in step with
// the generator that draws the committed SVGs in docs/assets/menu-bar-icon/. If you rename refreshStatusItemPresentation or the
// method after it, update statusItemPresentationSlice below to match.

import AppKit
import Foundation

func testStatusItemPresentation() {
    runSuite("status item uses the app icon's bubble with quiet, distinct capture states") {
        let source = readSourceFixture("Sources/App/TranscriptedApp.swift")
        let presentation = statusItemPresentationSlice(source)

        assertTrue(
            presentation.contains("glyph = .meetingRecording")
                && presentation.contains("label = \"Transcripted — recording meeting\""),
            "meeting recording should use the filled bubble with a dot while preserving its accessible state"
        )
        assertTrue(
            presentation.contains("glyph = .dictating")
                && presentation.contains("label = \"Transcripted — dictating\""),
            "dictation should use the filled bubble while preserving its accessible state"
        )
        assertTrue(
            presentation.contains("glyph = .idle") && presentation.contains("label = \"Transcripted\""),
            "idle should use the outline bubble"
        )
        assertTrue(
            presentation.contains("glyph.image(accessibilityDescription: label)"),
            "the status item image should come from MenuBarGlyph so every state matches the app icon"
        )
        assertFalse(
            presentation.contains("systemSymbolName")
                || presentation.contains("systemRed")
                || presentation.contains("isTemplate = false"),
            "the always-visible capture glyphs should not fall back to stock symbols or a red treatment"
        )
        assertTrue(
            source.contains("button.image = MenuBarGlyph.idle.image(accessibilityDescription: \"Transcripted\")"),
            "the status item should launch showing the idle bubble, not a stock symbol"
        )

        // MenuBarGlyph is compiled here: check the images it actually makes
        // instead of grepping its source for isTemplate and systemRed.
        for glyph in MenuBarGlyph.allCases {
            assertTrue(
                glyph.image(accessibilityDescription: "Transcripted").isTemplate,
                "\(glyph) should follow the menu bar appearance instead of baking in an attention color"
            )
            let pixels = renderMenuBarGlyph(glyph)
            var tintedPixels = 0
            for offset in stride(from: 0, to: pixels.count, by: 4) where pixels[offset + 3] > 128 {
                let red = Int(pixels[offset]), green = Int(pixels[offset + 1]), blue = Int(pixels[offset + 2])
                if abs(red - green) > 8 || abs(red - blue) > 8 {
                    tintedPixels += 1
                }
            }
            assertEqual(tintedPixels, 0, "\(glyph) should draw in neutral ink, not an attention color")
        }
    }

    runSuite("menu bar glyphs render distinct template silhouettes") {
        for glyph in MenuBarGlyph.allCases {
            let image = glyph.image(accessibilityDescription: "Transcripted")
            assertTrue(image.isTemplate, "\(glyph) should be a template image")
            assertEqual(image.size, NSSize(width: 18, height: 18), "\(glyph) should be menu bar sized")
            assertEqual(image.accessibilityDescription, "Transcripted", "\(glyph) should carry its label")
        }

        let idle = renderMenuBarGlyph(.idle)
        let dictating = renderMenuBarGlyph(.dictating)
        let meeting = renderMenuBarGlyph(.meetingRecording)

        // Pixels are 36 per 700 design units, starting at the box origin (162, 175).
        // The T's stem runs down the centre (design x 512, bar middle y 450 -> pixel 17, row 14).
        assertTrue(menuBarGlyphAlpha(idle, x: 17, y: 14) > 0.9, "idle should draw the T's stem in ink")
        assertTrue(menuBarGlyphAlpha(dictating, x: 17, y: 14) < 0.1, "dictating should cut the stem out of the filled bubble")
        assertTrue(menuBarGlyphAlpha(meeting, x: 17, y: 14) < 0.1, "meeting should cut the stem out of the filled bubble")

        // Inside the bubble between the stem and a side bar: empty when idle, solid when filled.
        // (design ~443, ~495 -> pixel 14, row 16).
        assertTrue(menuBarGlyphAlpha(idle, x: 14, y: 16) < 0.1, "idle should be an outline")
        assertTrue(menuBarGlyphAlpha(dictating, x: 14, y: 16) > 0.9, "dictating should be a filled bubble")

        // The recording dot sits off the bubble's bottom-right corner (design 744, 757 -> pixel 29, row 29).
        assertTrue(menuBarGlyphAlpha(meeting, x: 29, y: 29) > 0.9, "meeting should draw the recording dot")
        assertTrue(menuBarGlyphAlpha(dictating, x: 29, y: 29) < 0.1, "dictating should have no recording dot")
        assertTrue(menuBarGlyphAlpha(idle, x: 29, y: 29) < 0.1, "idle should have no recording dot")

        // A clear ring separates the dot from the bubble. Pixel 28, row 24 (design ~706...726, ~642...661)
        // is inside the bubble's corner and inside that ring: solid when dictating, cleared for a meeting.
        assertTrue(menuBarGlyphAlpha(dictating, x: 28, y: 24) > 0.9, "the bubble corner should be solid while dictating")
        assertTrue(menuBarGlyphAlpha(meeting, x: 28, y: 24) < 0.1, "a clear ring should keep the dot from merging into the bubble")

        // Knockouts must stay inside the glyph: drawing over an opaque background keeps it opaque.
        let composited = renderMenuBarGlyph(.meetingRecording, overOpaqueBackground: true)
        assertTrue(menuBarGlyphAlpha(composited, x: 17, y: 14) > 0.99, "knockouts should not punch through what is behind the glyph")
        assertTrue(menuBarGlyphAlpha(composited, x: 28, y: 24) > 0.99, "the dot's ring should not punch through what is behind the glyph")

        // The real NSImage path draws too, and the filled states ink more than the outline.
        let idleInk = inkedPixelsThroughNSImage(.idle)
        assertTrue(idleInk > 100, "the idle NSImage should draw the glyph (inked \(idleInk) px)")
        assertTrue(inkedPixelsThroughNSImage(.dictating) > idleInk, "the dictating NSImage should be a filled bubble")

        assertTrue(
            MenuBarGlyph.dictating.image(accessibilityDescription: "Transcripted — dictating")
                === MenuBarGlyph.dictating.image(accessibilityDescription: "Transcripted — dictating"),
            "repeat refreshes should reuse the same image instead of redrawing it"
        )
    }

    runSuite("menu bar glyph geometry matches the SVG generator") {
        let generator = readSourceFixture("docs/assets/menu-bar-icon/make_menu_bar_icons.py")
        let g = MenuBarGlyphGeometry.self
        let expected: [(String, [CGFloat])] = [
            ("SW", [g.strokeWidth]),
            ("L, R, TOP, BOT, RAD", [g.left, g.right, g.top, g.bottom, g.radius]),
            ("CX, MID", [g.centerX, g.barMidY]),
            ("CB", [g.crossbarHalfLength]),
            ("GAP", [g.crossbarGap]),
            ("STEM_BOT", [g.stemBottom]),
            ("SIDE_BARS", [g.sideBarOffset, g.sideBarHeight]),
            ("DOT_C, DOT_R, DOT_RING", [g.dotCenter.x, g.dotCenter.y, g.dotRadius, g.dotRing]),
            ("BOX_X, BOX_Y, BOX", [g.box.minX, g.box.minY, g.box.width]),
        ]
        for (names, values) in expected {
            assertEqual(
                pythonAssignmentNumbers(generator, names: names),
                values,
                "\(names) in make_menu_bar_icons.py should match MenuBarGlyphGeometry"
            )
        }
        assertEqual(g.box.width, g.box.height, "the glyph box should be square")

        // The tail: walk the path the glyph really draws and compare its two
        // quadratic curves with the generator's `Q` commands.
        let tailCommand = generator.split(separator: "\n")
            .first { $0.contains("d += f'L 404 {BOT} Q ") }
            .map(String.init) ?? ""
        let generatorQuads = svgQuadCurves(tailCommand, bottom: g.bottom)
        assertEqual(generatorQuads.count, 2, "the generator should draw the tail as two Q curves")
        for (name, path) in [("outline", g.outlinePath()), ("body", g.bodyPath())] {
            assertEqual(
                quadCurves(in: path),
                generatorQuads,
                "the \(name) path's tail should match the generator's curves"
            )
        }
    }
}

/// Quadratic curves in a CGPath as [start.x, start.y, control.x, control.y, end.x, end.y].
private func quadCurves(in path: CGPath) -> [[CGFloat]] {
    var curves: [[CGFloat]] = []
    var current = CGPoint.zero
    path.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint, .addLineToPoint:
            current = e.points[0]
        case .addQuadCurveToPoint:
            curves.append([current.x, current.y, e.points[0].x, e.points[0].y, e.points[1].x, e.points[1].y])
            current = e.points[1]
        case .addCurveToPoint:
            current = e.points[2]
        default:
            break
        }
    }
    return curves
}

/// `Q cx cy x y` commands in an SVG path f-string, each with the point it
/// starts from, and `{BOT}` filled in.
private func svgQuadCurves(_ command: String, bottom: CGFloat) -> [[CGFloat]] {
    let tokens = command
        .replacingOccurrences(of: "{BOT}", with: "\(Int(bottom))")
        .split(whereSeparator: { $0 == " " || $0 == "'" })
        .map(String.init)
    func number(_ index: Int) -> CGFloat? {
        index < tokens.count ? Double(tokens[index]).map { CGFloat($0) } : nil
    }
    var curves: [[CGFloat]] = []
    var current: [CGFloat] = []
    var index = 0
    while index < tokens.count {
        if tokens[index] == "L", let x = number(index + 1), let y = number(index + 2) {
            current = [x, y]
            index += 3
        } else if tokens[index] == "Q",
                  let cx = number(index + 1), let cy = number(index + 2),
                  let x = number(index + 3), let y = number(index + 4) {
            curves.append(current + [cx, cy, x, y])
            current = [x, y]
            index += 5
        } else {
            index += 1
        }
    }
    return curves
}

/// Numbers on the right of a line like `DOT_C, DOT_R, DOT_RING = (744, 757), 84, 44`, ignoring any
/// trailing comment.
private func pythonAssignmentNumbers(_ source: String, names: String) -> [CGFloat] {
    let prefix = "\(names) = "
    guard let line = source.split(separator: "\n").first(where: { $0.hasPrefix(prefix) }) else {
        return []
    }
    let rhs = line.dropFirst(prefix.count).split(separator: "#", maxSplits: 1).first ?? ""
    let numbers = rhs.split(whereSeparator: { !($0.isNumber || $0 == ".") })
    return numbers.compactMap { Double($0) }.map { CGFloat($0) }
}

/// Renders a glyph straight through MenuBarGlyph.draw(in:context:) into a 36 px bitmap, so the pixel
/// samples don't depend on how NSImage caches its drawing-handler renders.
private func renderMenuBarGlyph(_ glyph: MenuBarGlyph, overOpaqueBackground: Bool = false) -> [UInt8] {
    let pixels = menuBarGlyphTestPixels
    var data = [UInt8](repeating: 0, count: pixels * pixels * 4)
    data.withUnsafeMutableBytes { raw in
        guard let context = CGContext(
            data: raw.baseAddress,
            width: pixels,
            height: pixels,
            bitsPerComponent: 8,
            bytesPerRow: pixels * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return
        }
        let bounds = CGRect(x: 0, y: 0, width: pixels, height: pixels)
        if overOpaqueBackground {
            context.setFillColor(NSColor.white.cgColor)
            context.fill(bounds)
        }
        // Flip to y-down like the flipped NSImage the status item uses, so memory row 0 is the top.
        context.translateBy(x: 0, y: CGFloat(pixels))
        context.scaleBy(x: 1, y: -1)
        glyph.draw(in: bounds, context: context)
    }
    return data
}

private let menuBarGlyphTestPixels = 36

/// Alpha at a pixel, with (0, 0) at the top-left like the design space.
private func menuBarGlyphAlpha(_ data: [UInt8], x: Int, y: Int) -> CGFloat {
    CGFloat(data[(y * menuBarGlyphTestPixels + x) * 4 + 3]) / 255
}

/// Counts pixels the NSImage (drawing handler and all) inks when AppKit draws it at menu bar size.
private func inkedPixelsThroughNSImage(_ glyph: MenuBarGlyph) -> Int {
    let pixels = menuBarGlyphTestPixels
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        return 0
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    glyph.image(accessibilityDescription: nil).draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()
    var inked = 0
    for y in 0..<pixels {
        for x in 0..<pixels where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5 {
            inked += 1
        }
    }
    return inked
}

private func statusItemPresentationSlice(_ source: String) -> String {
    guard let start = source.range(of: "func refreshStatusItemPresentation()") else {
        return ""
    }
    let tail = source[start.lowerBound...]
    guard let end = tail.range(of: "func closePopover()") else {
        return String(tail)
    }
    return String(tail[..<end.lowerBound])
}
