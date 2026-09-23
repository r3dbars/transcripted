// Source-text pins: the first suite reads Sources/TranscriptedApp.swift as text instead of calling
// refreshStatusItemPresentation(), because that method is private on TranscriptedAppDelegate (@MainActor
// NSApplicationDelegate) and only does anything once statusItem?.button exists — a real NSStatusItem this
// runner never creates, since it never runs applicationDidFinishLaunching. It greps the sliced method body
// for the glyph states and accessibility labels, and guards against a red or non-template treatment that
// would make the always-visible capture icon alarming instead of quiet. The second suite is real behavioral
// coverage: it renders every MenuBarGlyph into a bitmap and checks the silhouettes actually differ where
// they are meant to. If you rename refreshStatusItemPresentation, update statusItemPresentationSlice below
// to match.

import AppKit
import Foundation

func testStatusItemPresentation() {
    runSuite("status item uses the app icon's bubble with quiet, distinct capture states") {
        let source = readSourceFixture("Sources/TranscriptedApp.swift")
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

        let glyphSource = readSourceFixture("Sources/UI/MenuBar/MenuBarGlyph.swift")
        assertTrue(
            glyphSource.contains("image.isTemplate = true") && !glyphSource.contains("systemRed"),
            "menu bar glyphs should follow the menu bar appearance instead of baking in an attention color"
        )
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

        // The T's stem runs down the centre (design x 512 -> pixel 18 of 36, bar middle y 450 -> row 14).
        assertTrue(menuBarGlyphAlpha(idle, x: 17, y: 14) > 0.9, "idle should draw the T's stem in ink")
        assertTrue(menuBarGlyphAlpha(dictating, x: 17, y: 14) < 0.1, "dictating should cut the stem out of the filled bubble")
        assertTrue(menuBarGlyphAlpha(meeting, x: 17, y: 14) < 0.1, "meeting should cut the stem out of the filled bubble")

        // Inside the bubble between the stem and a side bar: empty when idle, solid when filled.
        assertTrue(menuBarGlyphAlpha(idle, x: 13, y: 16) < 0.1, "idle should be an outline")
        assertTrue(menuBarGlyphAlpha(dictating, x: 13, y: 16) > 0.9, "dictating should be a filled bubble")

        // The recording dot sits off the bubble's bottom-right corner (design 744,757 -> pixel 31,31).
        assertTrue(menuBarGlyphAlpha(meeting, x: 31, y: 31) > 0.9, "meeting should draw the recording dot")
        assertTrue(menuBarGlyphAlpha(dictating, x: 31, y: 31) < 0.1, "dictating should have no recording dot")
        assertTrue(menuBarGlyphAlpha(idle, x: 31, y: 31) < 0.1, "idle should have no recording dot")

        // Knockouts must stay inside the glyph: drawing over an opaque background keeps it opaque.
        let composited = renderMenuBarGlyph(.meetingRecording, overOpaqueBackground: true)
        assertTrue(menuBarGlyphAlpha(composited, x: 17, y: 14) > 0.99, "knockouts should not punch through what is behind the glyph")
    }
}

private func renderMenuBarGlyph(_ glyph: MenuBarGlyph, overOpaqueBackground: Bool = false) -> NSBitmapImageRep {
    let pixels = 36
    let rep = NSBitmapImageRep(
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
    )!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let bounds = NSRect(x: 0, y: 0, width: pixels, height: pixels)
    if overOpaqueBackground {
        NSColor.white.setFill()
        bounds.fill()
    }
    glyph.image(accessibilityDescription: nil).draw(in: bounds)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// Alpha at a pixel, with (0, 0) at the top-left like the design space.
private func menuBarGlyphAlpha(_ rep: NSBitmapImageRep, x: Int, y: Int) -> CGFloat {
    rep.colorAt(x: x, y: y)?.alphaComponent ?? 0
}

private func statusItemPresentationSlice(_ source: String) -> String {
    guard let start = source.range(of: "private func refreshStatusItemPresentation()") else {
        return ""
    }
    let tail = source[start.lowerBound...]
    guard let end = tail.range(of: "private func installSettingsMenuHandler()") else {
        return String(tail)
    }
    return String(tail[..<end.lowerBound])
}
