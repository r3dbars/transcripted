// The first suite drives StatusItemPresentation, the same code the app delegate runs at launch and on
// every recording change, against a plain NSButton, and renders every MenuBarGlyph to check it stays a
// neutral template. The second renders every MenuBarGlyph into a bitmap and checks the silhouettes
// actually differ where they are meant to. MenuBarGlyphGeometry staying in step with the SVG generator
// in docs/assets/menu-bar-icon/ is checked by scripts/dev/check-menu-bar-glyph-sync.py.

import AppKit
import Foundation

@MainActor
func testStatusItemPresentation() {
    runSuite("status item uses the app icon's bubble with quiet, distinct capture states") {
        let cases: [(meeting: Bool, dictating: Bool, glyph: MenuBarGlyph, label: String)] = [
            (false, false, .idle, "Transcripted"),
            (false, true, .dictating, "Transcripted — dictating"),
            (true, false, .meetingRecording, "Transcripted — recording meeting"),
            (true, true, .meetingRecording, "Transcripted — recording meeting"),
        ]
        for state in cases {
            let presentation = StatusItemPresentation.for(meetingRecording: state.meeting, dictating: state.dictating)
            assertEqual(presentation.glyph, state.glyph, "meeting \(state.meeting), dictating \(state.dictating) glyph")
            assertEqual(presentation.label, state.label, "meeting \(state.meeting), dictating \(state.dictating) label")

            // The button the delegate writes: a template bubble, no tint, the state's label everywhere.
            let button = NSButton(frame: .zero)
            button.contentTintColor = .systemRed
            StatusItemPresentation.apply(
                to: button,
                meetingRecording: state.meeting,
                dictating: state.dictating,
                updateTooltip: nil
            )
            assertTrue(
                button.image === state.glyph.image(accessibilityDescription: state.label),
                "\(state.label) should show the MenuBarGlyph image so every state matches the app icon"
            )
            assertTrue(button.image?.isTemplate == true, "\(state.label) should stay a template image")
            assertEqual(button.image?.accessibilityDescription, state.label, "the image should carry the state's label")
            assertNil(button.contentTintColor, "\(state.label) should not be tinted an attention color")
            assertEqual(button.accessibilityLabel(), state.label, "VoiceOver should hear the capture state")
            assertEqual(button.toolTip, state.label, "the tooltip should name the capture state")
        }

        // Launch shows the idle bubble, the same thing a refresh with nothing recording shows.
        let launch = StatusItemPresentation.for(meetingRecording: false, dictating: false)
        assertEqual(launch.glyph, .idle, "the status item should launch showing the idle bubble")
        assertEqual(launch.label, StatusItemPresentation.idleLabel, "launch should use the plain app name")

        let updating = NSButton(frame: .zero)
        StatusItemPresentation.apply(
            to: updating,
            meetingRecording: false,
            dictating: true,
            updateTooltip: "update 1.2.3 available"
        )
        assertEqual(
            updating.toolTip,
            "Transcripted — dictating - update 1.2.3 available",
            "an available update should add to the tooltip without hiding the capture state"
        )
        assertEqual(updating.accessibilityLabel(), "Transcripted — dictating", "the update note should stay out of the label")

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
