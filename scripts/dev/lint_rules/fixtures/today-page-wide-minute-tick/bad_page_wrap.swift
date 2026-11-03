// lint-fixture-path: Sources/UI/Settings/TranscriptedSettingsView+Pages.swift
import SwiftUI

extension ExampleSettingsView {
    private var todayPage: some View {
        TimelineView(.everyMinute) { context in
            TodaySettingsPage(
                todayViewModel: todayViewModel,
                now: context.date,
                onOpenRecentItem: { _ in }
            )
        }
    }
}
