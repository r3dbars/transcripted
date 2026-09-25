import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

@Suite("Window attribution")
struct WindowAttributionTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedDisplayRect {
        NormalizedDisplayRect(x: x, y: y, width: w, height: h)
    }

    @Test("A block inside a single window attributes to it")
    func singleWindowMatch() {
        let editor = WindowAttribution.WindowInfo(
            bundleIdentifier: "com.apple.TextEdit",
            title: "Untitled",
            frame: rect(0, 0, 0.5, 1.0)
        )
        let block = rect(0.1, 0.1, 0.1, 0.05)
        let match = WindowAttribution.attribute(boundingBox: block, frontToBackWindows: [editor])
        #expect(match?.bundleIdentifier == "com.apple.TextEdit")
    }

    @Test("Overlapping windows: the frontmost (first) one wins")
    func overlapPrefersFrontmost() {
        let front = WindowAttribution.WindowInfo(
            bundleIdentifier: "com.apple.Notes",
            title: "Note",
            frame: rect(0, 0, 0.6, 0.6)
        )
        let back = WindowAttribution.WindowInfo(
            bundleIdentifier: "com.apple.Safari",
            title: "Page",
            frame: rect(0, 0, 1.0, 1.0)
        )
        // Both frames contain this block's center; front-to-back order says Notes wins.
        let block = rect(0.2, 0.2, 0.1, 0.1)
        let match = WindowAttribution.attribute(boundingBox: block, frontToBackWindows: [front, back])
        #expect(match?.bundleIdentifier == "com.apple.Notes")

        // Reversing the (still valid) front-to-back order flips the winner —
        // this proves attribution trusts caller-supplied order, it doesn't
        // infer it.
        let reversedMatch = WindowAttribution.attribute(boundingBox: block, frontToBackWindows: [back, front])
        #expect(reversedMatch?.bundleIdentifier == "com.apple.Safari")
    }

    @Test("A block outside every window frame attributes to nothing")
    func noMatchReturnsNil() {
        let editor = WindowAttribution.WindowInfo(
            bundleIdentifier: "com.apple.TextEdit",
            title: "Untitled",
            frame: rect(0, 0, 0.3, 0.3)
        )
        let block = rect(0.8, 0.8, 0.05, 0.05)
        #expect(WindowAttribution.attribute(boundingBox: block, frontToBackWindows: [editor]) == nil)
    }

    @Test("Attribution keys off the block's center, not its corner")
    func usesCenterPoint() {
        // Block straddles the window's right edge; its top-left corner is
        // outside but its center is inside.
        let window = WindowAttribution.WindowInfo(
            bundleIdentifier: "com.example.app",
            title: nil,
            frame: rect(0.0, 0.0, 0.5, 0.5)
        )
        let block = rect(0.4, 0.2, 0.2, 0.05) // spans 0.4...0.6, center at 0.5 — on the boundary, inclusive
        #expect(WindowAttribution.attribute(boundingBox: block, frontToBackWindows: [window])?.bundleIdentifier
            == "com.example.app")
    }

    @Test("Empty window list attributes to nothing")
    func emptyWindowListReturnsNil() {
        #expect(WindowAttribution.attribute(boundingBox: rect(0, 0, 1, 1), frontToBackWindows: []) == nil)
    }

    // MARK: - mapWindowRelativeBox (window-only capture's coordinate mapping)

    @Test("A window-relative box at the window's origin/full-size maps to exactly the window's own frame")
    func fullWindowBoxMapsToWindowFrame() {
        let windowFrame = rect(0.2, 0.1, 0.4, 0.5)
        let mapped = WindowAttribution.mapWindowRelativeBox(rect(0, 0, 1, 1), windowFrame: windowFrame)
        #expect(mapped == windowFrame)
    }

    @Test("A window-relative box in the window's bottom-right quadrant maps into the matching display-relative quadrant")
    func partialBoxMapsProportionally() {
        // Window occupies the right half of the display (x: 0.5...1.0).
        let windowFrame = rect(0.5, 0.0, 0.5, 1.0)
        // A box covering the window's own right half (its local x: 0.5...1.0,
        // width 0.5) should land at the display's far-right quarter.
        let localBox = rect(0.5, 0.25, 0.5, 0.1)
        let mapped = WindowAttribution.mapWindowRelativeBox(localBox, windowFrame: windowFrame)
        #expect(mapped.x == 0.75)
        #expect(mapped.y == 0.25)
        #expect(mapped.width == 0.25)
        #expect(mapped.height == 0.1)
    }

    @Test("A tiny window shrinks a full-width local box down to the window's own display-relative width")
    func mappingPreservesDisplayRelativeWidthForBubbleGates() {
        // A narrow chat window pinned to a corner: 0.15 wide, 0.2 tall.
        let windowFrame = rect(0.0, 0.0, 0.15, 0.2)
        // Vision sees a message bubble spanning most of the window locally
        // (width 0.8 in window space) — well above ScreenScene's
        // bubbleMinWidth (0.12) if read as display-relative, but the mapped,
        // TRUE display-relative width must reflect the window's own small
        // footprint (0.8 * 0.15 = 0.12), not the unmapped local value.
        let localBox = rect(0.1, 0.4, 0.8, 0.1)
        let mapped = WindowAttribution.mapWindowRelativeBox(localBox, windowFrame: windowFrame)
        #expect(abs(mapped.width - 0.12) < 0.0001)
        #expect(mapped.width != localBox.width)
    }

    @Test("Mapping through the identity (full-display) window frame is a no-op")
    func identityWindowFrameIsNoOp() {
        let windowFrame = rect(0, 0, 1, 1)
        let box = rect(0.33, 0.44, 0.1, 0.2)
        #expect(WindowAttribution.mapWindowRelativeBox(box, windowFrame: windowFrame) == box)
    }
}
