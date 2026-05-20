import CoreGraphics

func testMenuBarHeaderLayoutPolicy() {
    runSuite("MenuBarHeaderLayoutPolicy keeps ready warnings below the status row") {
        let statusBottom: CGFloat = 22 + 14
        let warningTop = MenuBarHeaderLayoutPolicy.warningTop(isReady: true) - 1

        assertTrue(
            warningTop > statusBottom,
            "ready warning text should start below the Ready status row"
        )
        assertTrue(
            MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: true, hasWarning: true)
                >= warningTop + MenuBarHeaderLayoutPolicy.warningTextHeight,
            "ready warning header should reserve enough vertical space"
        )
    }

    runSuite("MenuBarHeaderLayoutPolicy preserves existing non-ready heights") {
        assertEqual(
            MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: false, hasWarning: false),
            78,
            "non-ready header without warnings should keep its old height"
        )
        assertEqual(
            MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: false, hasWarning: true),
            110,
            "non-ready header with warnings should keep its old height"
        )
    }
}
