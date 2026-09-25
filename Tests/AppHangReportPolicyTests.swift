import Foundation

func testAppHangReportPolicy() {
    runSuite("app hang reports need 5+ seconds") {
        assertEqual(AppHangReportPolicy.timeoutSeconds, 5, "Sentry's 2 s default reported short stalls as freezes")
    }

    runSuite("only app hangs behind a popup are dropped") {
        assertTrue(
            AppHangReportPolicy.shouldDrop(mechanismType: "AppHang", popupLikely: true),
            "a hang while a modal popup is up is someone reading the popup"
        )
        assertFalse(
            AppHangReportPolicy.shouldDrop(mechanismType: "AppHang", popupLikely: false),
            "a hang with no popup is a real freeze"
        )
        assertFalse(
            AppHangReportPolicy.shouldDrop(mechanismType: "mach", popupLikely: true),
            "crashes are never dropped for a popup"
        )
        assertFalse(
            AppHangReportPolicy.shouldDrop(mechanismType: nil, popupLikely: true),
            "events without a mechanism are not hangs"
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
