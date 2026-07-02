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

    runSuite("MenuBarHeaderLayoutPolicy shows the header only when it has something to say") {
        assertEqual(
            MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: true, hasWarning: false),
            0,
            "a ready, quiet, idle header should take no space"
        )
        assertEqual(
            MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: true, hasWarning: false, isRecording: true),
            MenuBarHeaderLayoutPolicy.recordingIntrinsicHeight,
            "an active meeting recording must make the header visible"
        )
        assertEqual(
            MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: true, hasWarning: true, isRecording: true),
            MenuBarHeaderLayoutPolicy.readyWarningIntrinsicHeight,
            "a warning while recording should keep the taller warning layout"
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
