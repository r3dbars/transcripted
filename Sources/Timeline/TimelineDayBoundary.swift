import Foundation

enum TimelineDayBoundary {
    static let boundaryHour = 4

    static func day(
        for date: Date,
        calendar inputCalendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        let calendar = inputCalendar
        let shifted = calendar.date(
            byAdding: .hour,
            value: -boundaryHour,
            to: date
        ) ?? date

        let components = calendar.dateComponents([.year, .month, .day], from: shifted)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }
}
