import Foundation

func testAppHangReportPolicy() {
    runSuite("app hang reports need 5+ seconds") {
        assertEqual(AppHangReportPolicy.timeoutSeconds, 5, "Sentry's 2 s default reported short stalls as freezes")
    }

    runSuite("only app hang events can be dropped") {
        assertFalse(
            AppHangReportPolicy.shouldDrop(mechanismType: "mach", popupLikely: true, mainThreadFunctions: ["runModal"]),
            "crashes are never dropped for a popup"
        )
        assertFalse(
            AppHangReportPolicy.shouldDrop(mechanismType: nil, popupLikely: true, mainThreadFunctions: []),
            "events without a mechanism are not hangs"
        )
    }

    runSuite("app hangs behind a popup are dropped, real ones are kept") {
        assertTrue(
            AppHangReportPolicy.shouldDrop(mechanismType: "AppHang", popupLikely: true, mainThreadFunctions: []),
            "a hang while a popup is on screen is someone reading the popup"
        )
        assertTrue(
            AppHangReportPolicy.shouldDrop(
                mechanismType: "AppHang",
                popupLikely: false,
                mainThreadFunctions: ["-[NSApplication runModalForWindow:]"]
            ),
            "a main thread inside runModal is waiting on a popup"
        )
        assertFalse(
            AppHangReportPolicy.shouldDrop(
                mechanismType: "AppHang",
                popupLikely: false,
                mainThreadFunctions: ["-[AVAudioEngine inputNode]", "_dispatch_sync_f_slow"]
            ),
            "a main thread stuck in app work is a real freeze"
        )
    }

    runSuite("popup tracker covers open popups and a short grace after close") {
        let tracker = PopupPresenceTracker()
        let popup = ObjectIdentifier(NSObject())
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        assertFalse(tracker.isPopupLikely(now: start), "nothing open yet")

        tracker.popupOpened(popup)
        assertTrue(tracker.isPopupLikely(now: start.addingTimeInterval(60)), "an open popup covers any hang")

        tracker.popupClosed(popup, now: start.addingTimeInterval(60))
        assertTrue(
            tracker.isPopupLikely(now: start.addingTimeInterval(60.5)),
            "a hang detected just after close can still be the popup"
        )
        assertFalse(
            tracker.isPopupLikely(now: start.addingTimeInterval(62)),
            "a freeze after the grace window is real"
        )
    }

    runSuite("popup tracker ignores closes for popups it never saw") {
        let tracker = PopupPresenceTracker()
        tracker.popupClosed(ObjectIdentifier(NSObject()), now: Date())
        assertFalse(tracker.isPopupLikely(), "an unknown window closing is not a popup")
    }
}
