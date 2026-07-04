import AppKit

func testDictationOverlayPlacementPolicy() {
    runSuite("DictationOverlayPlacementPolicy converts AX rects against the primary screen") {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let axRect = CGRect(x: 1600, y: 120, width: 320, height: 40)

        let cocoaRect = DictationOverlayPlacementPolicy.cocoaRect(
            fromAccessibilityRect: axRect,
            primaryScreenFrame: primary
        )

        assertEqual(cocoaRect?.origin.x, 1600, "AX x should stay in global coordinates")
        assertEqual(cocoaRect?.origin.y, 740, "AX y should flip from the primary display height using rect.maxY")
        assertEqual(cocoaRect?.size.width, 320, "width should be preserved")
        assertEqual(cocoaRect?.size.height, 40, "height should be preserved")
    }

    runSuite("DictationOverlayPlacementPolicy chooses the screen containing the converted field") {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let converted = NSRect(x: 1600, y: 740, width: 320, height: 40)
        let mouseOnPrimary = NSPoint(x: 300, y: 300)

        let chosen = DictationOverlayPlacementPolicy.screenFrame(
            containing: converted,
            mouseLocation: mouseOnPrimary,
            screenFrames: [primary, secondary],
            fallbackScreenFrame: primary
        )

        assertEqual(chosen, secondary, "the target field's screen should beat the mouse screen")
    }

    runSuite("DictationOverlayPlacementPolicy falls back to the mouse screen without a valid field") {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let mouseOnSecondary = NSPoint(x: 1700, y: 300)

        let chosen = DictationOverlayPlacementPolicy.screenFrame(
            containing: nil,
            mouseLocation: mouseOnSecondary,
            screenFrames: [primary, secondary],
            fallbackScreenFrame: primary
        )

        assertEqual(chosen, secondary, "mouse location should be the fallback when AX has no usable rect")
    }

    runSuite("DictationOverlayPlacementPolicy rejects oversized accessibility rects") {
        let screen = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let oversized = NSRect(x: 1440, y: 0, width: 3000, height: 100)

        assertNil(
            DictationOverlayPlacementPolicy.validatedTargetRect(oversized, on: screen),
            "terminal-sized AX areas should not anchor the compact overlay"
        )
    }
}
