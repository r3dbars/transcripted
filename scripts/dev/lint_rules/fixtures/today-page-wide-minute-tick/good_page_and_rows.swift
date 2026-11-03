// lint-fixture-path: Sources/UI/Settings/Pages/TodaySettingsPage.swift
import SwiftUI

struct TodaySettingsPage: View {
    @ObservedObject var todayViewModel: TodayViewModel

    var body: some View {
        TodayDayCard(day: day, pickedMarkID: nil, formatKey: formatKey)
        TodaySessionRow(session: session, isOpen: false, formatKey: formatKey)
    }
}

private struct TodayDayCard: View, Equatable {
    let day: TodayTapeDay
    let pickedMarkID: String?
    let formatKey: String

    var body: some View { Text("x") }
}

private struct TodaySessionRow: View, Equatable {
    let session: TodaySession
    let isOpen: Bool
    let formatKey: String

    var body: some View { Text("x") }
}

private enum TodayPreviewCopy {
    static func meta(for item: TodayRecentItem, now: Date = Date()) -> String { "" }
}
