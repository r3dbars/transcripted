// lint-fixture-path: Sources/UI/Settings/Pages/TodaySettingsPage.swift
import SwiftUI

private struct TodayDayCard: View, Equatable {
    let day: TodayTapeDay
    let now: Date
    let pickedMarkID: String?
    let formatKey: String

    var body: some View { Text("x") }
}
