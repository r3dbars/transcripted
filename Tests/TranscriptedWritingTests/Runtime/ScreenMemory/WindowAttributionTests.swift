import Testing
@testable import TranscriptedWritingRuntime
@testable import TranscriptedWritingCore

@Suite("Window attribution")
struct WindowAttributionTests {
    private func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> NormalizedDisplayRect {
        NormalizedDisplayRect(x: x, y: y, width: w, height: h)
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

    @Test("Mapping through a window that covers the whole display is a no-op")
    func identityWindowFrameIsNoOp() {
        let windowFrame = rect(0, 0, 1, 1)
        let box = rect(0.33, 0.44, 0.1, 0.2)
        #expect(WindowAttribution.mapWindowRelativeBox(box, windowFrame: windowFrame) == box)
    }
}
