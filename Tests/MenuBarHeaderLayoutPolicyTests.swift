import CoreGraphics

func testMenuBarHeaderLayoutPolicy() {
    runSuite("MenuBarHeaderLayoutPolicy keeps warnings below the status line") {
        let recordingWarningTop = MenuBarHeaderLayoutPolicy.warningTop(isReady: true, showsStatus: true) - 1
        assertTrue(
            recordingWarningTop >= MenuBarHeaderLayoutPolicy.statusRowHeight,
            "a warning while recording should start below the status line"
        )

        let warmupWarningTop = MenuBarHeaderLayoutPolicy.warningTop(isReady: false, showsStatus: true) - 1
        assertTrue(
            warmupWarningTop >= MenuBarHeaderLayoutPolicy.detailTop + 24,
            "a warning during warmup should start below the warmup detail text"
        )

        for (isReady, isRecording) in [(true, false), (true, true), (false, false)] {
            let top = MenuBarHeaderLayoutPolicy.warningTop(isReady: isReady, showsStatus: !isReady || isRecording)
            assertTrue(
                MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: isReady, hasWarning: true, isRecording: isRecording)
                    >= top + MenuBarHeaderLayoutPolicy.warningTextHeight,
                "the header should reserve room for the whole warning (ready: \(isReady), recording: \(isRecording))"
            )
        }
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
        assertTrue(
            MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: true, hasWarning: true)
                < MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: true, hasWarning: true, isRecording: true),
            "a warning on its own should not reserve space for a status line"
        )
        assertEqual(
            MenuBarHeaderLayoutPolicy.intrinsicHeight(isReady: false, hasWarning: false),
            MenuBarHeaderLayoutPolicy.nonReadyIntrinsicHeight,
            "warmup should show its status, progress, and detail"
        )
    }
}
