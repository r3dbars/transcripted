import EventKit
import Foundation

@MainActor
func testCalendarAccessStatusCache() async {
    await runSuite("CalendarAccessStatusCache — reads return the last refreshed answer and the status check runs off main") {
        let status = SyntheticCalendarAuthorization(.notDetermined)
        let cache = CalendarAccessStatusCache(statusProvider: { status.read() })

        assertFalse(cache.isGranted, "an unknown status reads as not granted")
        assertEqual(status.readCount, 0, "reading the cache must not ask EventKit")

        status.set(.fullAccess)
        assertFalse(cache.isGranted, "a new status is not seen until a refresh")
        let refreshed = await cache.refresh()
        assertTrue(refreshed, "refresh returns the status it read")
        assertTrue(cache.isGranted, "the cache holds the refreshed answer")

        status.set(.denied)
        await cache.refresh()
        assertFalse(cache.isGranted, "a revocation shows after the next refresh")
        assertEqual(status.readCount, 2)
        assertEqual(status.mainThreadReadCount, 0, "the EventKit status check must never run on the main thread")
    }

    await runSuite("MeetingPromptDetector — a calendar permission change refreshes cached access and fetches events") {
        let status = SyntheticCalendarAuthorization(.denied)
        let cache = CalendarAccessStatusCache(statusProvider: { status.read() })
        var fetchCount = 0
        let detector = MeetingPromptDetector(
            calendarAccess: cache,
            fetchCalendarEventSnapshots: { start, end in
                fetchCount += 1
                let midpoint = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
                return [
                    MeetingPromptCalendarEventSnapshot(
                        id: "synthetic-calendar-after-grant",
                        title: "Synthetic calendar fixture",
                        startDate: midpoint,
                        endDate: midpoint.addingTimeInterval(600),
                        isAllDay: false,
                        url: URL(string: "https://zoom.us/j/123"),
                        location: nil,
                        notes: nil
                    )
                ]
            },
            learnedBackoffDefaults: nil,
            meetingShortcutDisplay: { "synthetic-shortcut" }
        )
        detector.frontmostBundleIDProvider = { nil }
        detector.runningBundleIDsProvider = { [] }
        detector.browserWindowTitlesProvider = { _ in [] }
        detector.callShortcutProvider = { _ in nil }
        detector.isAutoRecordEnabled = { false }
        detector.isOwnCaptureActive = { false }

        detector.start()
        defer { detector.stop() }
        await detector.waitUntilEvaluationsSettle()
        assertFalse(detector.calendarAccessGranted(), "denied access reads as not granted after launch")
        assertEqual(fetchCount, 0, "no calendar fetch without access")
        assertTrue(detector.calendarEventSnapshots.isEmpty)

        status.set(.fullAccess)
        assertFalse(detector.calendarAccessGranted(), "the detector reads the cache, not EventKit")
        NotificationCenter.default.post(
            name: .transcriptedPermissionsDidChange,
            object: TranscriptedPermissionKind.calendar
        )
        await detector.waitUntilEvaluationsSettle()

        assertTrue(detector.calendarAccessGranted(), "the permission change refreshed the cached access")
        assertTrue(cache.isGranted)
        assertEqual(fetchCount, 1, "a new grant fetches events at once, not after the cache lifetime")
        assertEqual(detector.calendarEventSnapshots.map(\.id), ["synthetic-calendar-after-grant"])
        assertEqual(status.mainThreadReadCount, 0, "the detector never asks EventKit on the main thread")
    }
}

/// A calendar authorization status the test sets, standing in for EventKit.
/// Counts reads and how many came on the main thread.
private final class SyntheticCalendarAuthorization: @unchecked Sendable {
    private let lock = NSLock()
    private var status: EKAuthorizationStatus
    private var reads = 0
    private var mainThreadReads = 0

    init(_ status: EKAuthorizationStatus) {
        self.status = status
    }

    func set(_ newStatus: EKAuthorizationStatus) {
        lock.lock()
        status = newStatus
        lock.unlock()
    }

    func read() -> EKAuthorizationStatus {
        let onMain = Thread.isMainThread
        lock.lock()
        defer { lock.unlock() }
        reads += 1
        if onMain { mainThreadReads += 1 }
        return status
    }

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    var mainThreadReadCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return mainThreadReads
    }
}
