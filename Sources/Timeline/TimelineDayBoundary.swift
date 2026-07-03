import Foundation

struct TimelineDayBoundary {
    var calendar: Calendar
    var boundaryHour: Int

    init(calendar: Calendar = .current, boundaryHour: Int = 4) {
        self.calendar = calendar
        self.boundaryHour = boundaryHour
    }

    func day(for date: Date) -> String {
        var workingCalendar = calendar
        workingCalendar.timeZone = calendar.timeZone
        let hour = workingCalendar.component(.hour, from: date)
        let startOfCalendarDay = workingCalendar.startOfDay(for: date)
        let logicalDay = hour < boundaryHour
            ? (workingCalendar.date(byAdding: .day, value: -1, to: startOfCalendarDay) ?? startOfCalendarDay)
            : startOfCalendarDay
        let components = workingCalendar.dateComponents([.year, .month, .day], from: logicalDay)
        let year = components.year ?? 1970
        let month = components.month ?? 1
        let day = components.day ?? 1
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func day(for date: Date, calendar: Calendar = .current) -> String {
        TimelineDayBoundary(calendar: calendar).day(for: date)
    }
}
