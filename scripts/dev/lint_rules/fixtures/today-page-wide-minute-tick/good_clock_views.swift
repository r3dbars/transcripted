// lint-fixture-path: Sources/UI/Settings/TodayClockViews.swift
import SwiftUI

struct TodayNowLabel: View {
    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(TodayClockPolicy.nowLabelText(now: context.date))
        }
    }
}

struct TodayNowMarker: View {
    let tapeDay: Date
    let width: CGFloat

    var body: some View {
        TimelineView(.everyMinute) { context in
            if let fraction = TodayClockPolicy.nowMarkerFraction(now: context.date, tapeDay: tapeDay) {
                Rectangle().offset(x: width * fraction - 1)
            }
        }
    }
}
