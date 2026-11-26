// lint-fixture-path: Sources/UI/Settings/TodayClockViews.swift
import SwiftUI

struct TodayDayRollover: View {
    let storedDay: Date
    let onRollover: () -> Void

    var body: some View {
        TimelineView(TodayMidnightSchedule()) { context in
            Color.clear
                .onChange(of: TodayClockPolicy.dayKey(context.date)) { _, newDay in
                    if TodayClockPolicy.needsRollover(storedDay: storedDay, now: newDay) {
                        onRollover()
                    }
                }
        }
    }
}
