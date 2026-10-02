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
}
