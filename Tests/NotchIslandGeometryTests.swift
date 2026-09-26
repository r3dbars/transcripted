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
