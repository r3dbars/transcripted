import AppKit
import SwiftUI

/// Zero-size leaf that refreshes the Stats snapshot when the calendar day of
/// `storedDay` is no longer today: local midnight, appear, wake, the app
/// becoming active, or the window becoming key. No per-minute timers.
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
