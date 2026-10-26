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

/// The accent line at the current time of day on today's tape.
struct TodayNowMarker: View {
    let dayStart: Date
    let width: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            Rectangle()
                .fill(LibraryTokens.accent)
                .frame(width: 2, height: 22)
                .offset(x: width * TodayTapeBuilder.fraction(of: context.date, onDayStarting: dayStart) - 1)
                .allowsHitTesting(false)
        }
        .allowsHitTesting(false)
    }
}

/// Zero-size leaf that fires at local midnight so the snapshot can rebuild
/// the seven-day window and the "Today" label without a page-wide minute tick.
struct TodayDayRollover: View {
    let onRollover: () -> Void

    var body: some View {
        TimelineView(TodayMidnightSchedule()) { context in
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .onChange(of: TodayClockPolicy.dayKey(context.date)) { _, _ in
                    onRollover()
                }
        }
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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
