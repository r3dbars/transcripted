import AppKit

func testCapturePillPlacementPolicy() {
    runSuite("CapturePillPlacementPolicy anchors to the screen containing the mouse") {
        let primary = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let secondary = NSRect(x: 1440, y: 0, width: 1920, height: 1080)

        let chosen = CapturePillPlacementPolicy.selectedScreenFrame(
            mouseLocation: NSPoint(x: 1700, y: 600),
            screenFrames: [primary, secondary],
            fallbackScreenFrame: primary
        )

        assertEqual(chosen, secondary, "detected-meeting prompts should appear where the user is looking")
    }

    runSuite("CapturePillPlacementPolicy keeps the pill top-centered inside the visible frame") {
        let visibleFrame = NSRect(x: 1440, y: 0, width: 1920, height: 1040)
        let origin = CapturePillPlacementPolicy.origin(
            panelSize: NSSize(width: 360, height: 64),
            visibleFrame: visibleFrame,
            inset: 18
        )

        assertEqual(origin.x, 2220, "pill should be centered on the selected display")
        assertEqual(origin.y, 958, "pill should sit below the selected display's menu bar area")
    }
}
