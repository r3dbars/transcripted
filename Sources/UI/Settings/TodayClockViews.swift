import AppKit
import SwiftUI

/// "Now 2:41 PM" on today's tape. Its own minute TimelineView so the rest
/// of the day card can skip a tick.
struct TodayNowLabel: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(TodayClockPolicy.nowLabelText(now: context.date))
                .font(.system(size: 11))
                .foregroundStyle(LibraryTokens.ink3)
        }
    }
}

/// The accent line at the current time of day on today's tape. The day it
/// sits on comes from the TimelineView clock, not the snapshot's stored
/// `isToday`, so a stale tape after midnight or sleep hides the marker
/// instead of pinning it to yesterday's right edge.
struct TodayNowMarker: View {
    let tapeDay: Date
    let width: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let fraction = TodayClockPolicy.nowMarkerFraction(now: context.date, tapeDay: tapeDay) {
                Rectangle()
                    .fill(LibraryTokens.accent)
                    .frame(width: 2, height: 22)
                    .offset(x: width * fraction - 1)
                    .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Zero-size leaf that refreshes the snapshot when the calendar day of
/// `storedDay` is no longer today: local midnight, appear, wake, the app
/// becoming active, or the window becoming key.
struct TodayDayRollover: View {
    let storedDay: Date
    let onRollover: () -> Void

    var body: some View {
        TimelineView(TodayMidnightSchedule()) { context in
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .onAppear { consider(now: Date()) }
                .onChange(of: TodayClockPolicy.dayKey(context.date)) { _, newDay in
                    consider(now: newDay)
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                    consider(now: Date())
                }
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    consider(now: Date())
                }
                .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                    consider(now: Date())
                }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func consider(now: Date) {
        if TodayClockPolicy.needsRollover(storedDay: storedDay, now: now) {
            onRollover()
        }
    }
}

/// `now`, then each following local midnight. DST-safe: the next entry is
/// `Calendar.date(byAdding: .day, 1)` from the start of the current day.
struct TodayMidnightSchedule: TimelineSchedule {
    func entries(from startDate: Date, mode: TimelineScheduleMode) -> TodayMidnightEntries {
        TodayMidnightEntries(from: startDate)
    }
}

struct TodayMidnightEntries: Sequence, IteratorProtocol {
    private var nextDate: Date?

    init(from startDate: Date) {
        nextDate = startDate
    }

    mutating func next() -> Date? {
        guard let current = nextDate else { return nil }
        nextDate = TodayClockPolicy.nextMidnight(after: current)
        return current
    }
}
