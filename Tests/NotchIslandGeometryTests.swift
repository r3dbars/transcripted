import CoreGraphics
import Foundation

func testNotchIslandGeometry() {
    // A 14-inch MacBook Pro: 1512 points wide, a 185-point camera housing.
    let macBookFrame = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let macBook = NotchIslandGeometry.screenInfo(
        frame: macBookFrame,
        safeAreaTop: 32,
        leftAuxiliaryWidth: 663.5,
        rightAuxiliaryWidth: 663.5
    )
    // An external display to the right: no notch, no safe area.
    let external = NotchIslandGeometry.screenInfo(
        frame: CGRect(x: 1512, y: 0, width: 2560, height: 1440),
        safeAreaTop: 0,
        leftAuxiliaryWidth: nil,
        rightAuxiliaryWidth: nil
    )

    runSuite("NotchIslandGeometry finds the notch from the screen's top areas") {
        assertEqual(macBook.notchWidth, 185)
        assertEqual(macBook.rowHeight, 32, "the wing row is as tall as the notch")
        assertTrue(macBook.hasNotch)

        assertNil(external.notchWidth, "a display without a notch gets no fake notch")
        assertEqual(external.rowHeight, NotchIslandGeometry.tabRowHeight)

        let noAuxiliary = NotchIslandGeometry.screenInfo(
            frame: macBookFrame,
            safeAreaTop: 32,
            leftAuxiliaryWidth: nil,
            rightAuxiliaryWidth: nil
        )
        assertNil(noAuxiliary.notchWidth, "a safe area without the two top areas is not a notch")
    }

    runSuite("NotchIslandGeometry keeps the camera centered between equal wings") {
        let size = NotchIslandGeometry.islandSize(screen: macBook, leftContent: 80, rightContent: 40, dropHeight: nil)
        // Wider wing: 80 + 24 padding = 104, already on the 4-point grid.
        assertEqual(size.width, 185 + 2 * 104)
        assertEqual(size.height, 32)

        let frame = NotchIslandGeometry.frame(screen: macBook, size: size)
        assertEqual(frame.midX, macBookFrame.midX, "the island is centered on the notch")
        assertEqual(frame.maxY, macBookFrame.maxY, "the island hangs from the top edge")

        let tiny = NotchIslandGeometry.islandSize(screen: macBook, leftContent: 8, rightContent: 0, dropHeight: nil)
        assertEqual(tiny.width, 185 + 2 * NotchIslandGeometry.minimumWing, "a lone dot still gets a readable wing")
    }

    runSuite("NotchIslandGeometry sizes a tab to its content on other displays") {
        let size = NotchIslandGeometry.islandSize(screen: external, leftContent: 80, rightContent: 40, dropHeight: nil)
        assertEqual(size.width, 168, "both wings plus padding, on the 4-point grid")
        assertEqual(size.height, NotchIslandGeometry.tabRowHeight)

        let small = NotchIslandGeometry.islandSize(screen: external, leftContent: 10, rightContent: 0, dropHeight: nil)
        assertEqual(small.width, NotchIslandGeometry.minimumTabWidth)

        let frame = NotchIslandGeometry.frame(screen: external, size: size)
        assertEqual(frame.midX, external.frame.midX)
        assertEqual(frame.maxY, external.frame.maxY)
    }

    runSuite("NotchIslandGeometry makes room for the drop-down") {
        let notch = NotchIslandGeometry.islandSize(screen: macBook, leftContent: 80, rightContent: 40, dropHeight: 120)
        assertEqual(notch.width, NotchIslandGeometry.dropWidth)
        assertEqual(notch.height, 32 + NotchIslandGeometry.dropTopGap + 120)

        let tab = NotchIslandGeometry.islandSize(screen: external, leftContent: 80, rightContent: 40, dropHeight: 90)
        assertEqual(tab.width, NotchIslandGeometry.dropWidth, "the external drop-down is never clipped to the tab")
        assertEqual(tab.height, NotchIslandGeometry.tabRowHeight + NotchIslandGeometry.dropTopGap + 90)

        let wide = NotchIslandGeometry.islandSize(screen: macBook, leftContent: 200, rightContent: 40, dropHeight: 50)
        assertEqual(wide.width, 185 + 2 * 224, "wide wings keep their width under a drop-down")
    }

    runSuite("NotchIslandGeometry never runs off a narrow screen") {
        let narrow = NotchIslandGeometry.screenInfo(
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            safeAreaTop: 0,
            leftAuxiliaryWidth: nil,
            rightAuxiliaryWidth: nil
        )
        let size = NotchIslandGeometry.islandSize(screen: narrow, leftContent: 80, rightContent: 40, dropHeight: 100)
        assertEqual(size.width, 400 - 2 * NotchIslandGeometry.screenMargin)
    }

    runSuite("NotchIslandGeometry grows out of the notch and back into it") {
        let collapsed = NotchIslandGeometry.collapsedFrame(screen: macBook)
        assertEqual(collapsed.width, 185)
        assertEqual(collapsed.height, 32)
        assertEqual(collapsed.midX, macBookFrame.midX)
        assertEqual(collapsed.maxY, macBookFrame.maxY)

        let sliver = NotchIslandGeometry.collapsedFrame(screen: external)
        assertEqual(sliver.height, 2, "without a notch it drops from a sliver at the top edge")
        assertEqual(sliver.maxY, external.frame.maxY)
        assertEqual(sliver.midX, external.frame.midX)
    }

    runSuite("NotchIslandGeometry holds the island in a window that never resizes mid-spring") {
        let resting = NotchIslandGeometry.envelope(screen: macBook, containing: [], margin: 14)
        assertEqual(resting.size, NotchIslandGeometry.envelopeMinimumSize, "room for any everyday island")
        assertEqual(resting.midX, macBookFrame.midX)
        assertEqual(resting.maxY, macBookFrame.maxY, "hangs from the top edge")

        let island = CGRect(x: 526, y: macBookFrame.maxY - 150, width: 460, height: 150)
        let withDrop = NotchIslandGeometry.envelope(screen: macBook, containing: [island], margin: 14)
        assertTrue(withDrop.contains(island.insetBy(dx: -14, dy: 0)), "a drop-down and its overshoot fit")

        let wide = CGRect(x: 300, y: macBookFrame.maxY - 32, width: 912, height: 32)
        let grown = NotchIslandGeometry.envelope(screen: macBook, containing: [wide], margin: 14)
        assertTrue(grown.width >= 912 + 28, "an unusually wide island still fits with its margin")
        assertEqual(grown.midX, macBookFrame.midX, "and stays centered")

        let huge = CGRect(x: -500, y: 0, width: 3000, height: 2000)
        let clamped = NotchIslandGeometry.envelope(screen: macBook, containing: [huge], margin: 14)
        assertTrue(clamped.width <= macBookFrame.width && clamped.height <= macBookFrame.height, "never bigger than the screen")

        assertEqual(NotchIslandGeometry.collapsedRadius(screen: macBook), 10)
        assertEqual(NotchIslandGeometry.collapsedRadius(screen: external), 2)
        assertEqual(NotchIslandGeometry.collapsedFrame(screen: external).width, NotchIslandGeometry.edgeNubWidth)
    }

    runSuite("NotchIslandMotion springs out fast with a small bounce and back without one") {
        let grow = NotchIslandMotion.grow
        let shrink = NotchIslandMotion.shrink
        assertEqual(grow.progress(at: 0), 0)
        assertTrue(grow.progress(at: 0.1) > 0.4, "most of the grow happens in the first tenth of a second")
        let peak = stride(from: 0.0, through: 1.0, by: 0.005).map { grow.progress(at: CGFloat($0)) }.max() ?? 0
        assertTrue(peak > 1.01 && peak < 1.08, "a small Dynamic Island overshoot, not a wobble (peak \(peak))")
        assertTrue(abs(grow.progress(at: 0.6) - 1) < 0.01, "settled by 0.6 s")
        let shrinkPeak = stride(from: 0.0, through: 1.0, by: 0.005).map { shrink.progress(at: CGFloat($0)) }.max() ?? 0
        assertTrue(shrinkPeak <= 1.0001, "pulling back into the notch never overshoots")
        assertTrue(shrink.progress(at: 0.3) > 0.95, "hiding is nearly done in 0.3 s")

        let spring = NotchIslandMotion.Spring.response(0.5, dampingRatio: 0.8)
        assertTrue(abs(spring.dampingRatio - 0.8) < 0.0001, "response/damping converts to spring constants and back")
        assertTrue(abs(spring.stiffness - pow(2 * CGFloat.pi / 0.5, 2)) < 0.0001)
        assertTrue(NotchIslandMotion.blurInDuration >= NotchIslandMotion.contentFadeIn, "the blur lasts through the fade, while the shape uncovers the text")

        let edge = NotchIslandMotion.growFromEdge
        let edgePeak = stride(from: 0.0, through: 1.2, by: 0.005).map { edge.progress(at: CGFloat($0)) }.max() ?? 0
        assertTrue(edgePeak < peak, "out of a plain top edge it pours out softer than out of the notch")
        assertTrue(abs(edge.progress(at: 0.8) - 1) < 0.01, "and is still settled well under a second")
    }

    runSuite("NotchIslandGeometry rounds corners and snaps widths") {
        assertEqual(NotchIslandGeometry.cornerRadius(hasDrop: true, rowHeight: 32), NotchIslandGeometry.dropCornerRadius)
        assertEqual(NotchIslandGeometry.cornerRadius(hasDrop: false, rowHeight: 32), 16)
        assertEqual(NotchIslandGeometry.cornerRadius(hasDrop: false, rowHeight: 24), 12)
        assertEqual(NotchIslandGeometry.snap(101), 104)
        assertEqual(NotchIslandGeometry.snap(104), 104)
        assertEqual(NotchIslandGeometry.wingWidth(content: 0), 0, "an empty wing takes no room")
        assertEqual(NotchIslandGeometry.wingWidth(content: 30), 54)
    }
}
