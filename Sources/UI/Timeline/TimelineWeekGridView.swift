import SwiftUI

protocol TimelineWeekGridProviding {
    var weekStart: Date { get }
    var entries: [TimelineEntryRecord] { get }
}

struct TimelineWeekGridModel: TimelineWeekGridProviding {
    let weekStart: Date
    let entries: [TimelineEntryRecord]
}

struct TimelineWeekGridView: View {
    let model: TimelineWeekGridProviding
    var calendar: Calendar = .current
    var onSelectDay: (Date) -> Void = { _ in }

    private let hourHeight: CGFloat = 42
    private let daySpacing: CGFloat = 8
    private let gutterWidth: CGFloat = 52

    var body: some View {
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: daySpacing) {
                hourGutter
                    .frame(width: gutterWidth)

                ForEach(dayColumns) { day in
                    dayColumn(day)
                }
            }
            .padding(16)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var dayColumns: [TimelineWeekDayColumn] {
        (0..<7).map { index in
            let date = calendar.date(byAdding: .day, value: index, to: model.weekStart) ?? model.weekStart
            return TimelineWeekDayColumn(id: index, date: date, entries: entries(forDayStarting: date))
        }
    }

    private var hourGutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text("")
                .frame(height: 34)

            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(hour))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(height: hourHeight, alignment: .topTrailing)
            }
        }
    }

    private func dayColumn(_ day: TimelineWeekDayColumn) -> some View {
        VStack(spacing: 6) {
            Button {
                onSelectDay(day.date)
            } label: {
                VStack(spacing: 2) {
                    Text(weekdayFormatter.string(from: day.date))
                        .font(.caption.weight(.semibold))
                    Text(dayNumberFormatter.string(from: day.date))
                        .font(.title3.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .help("Open day")

            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.035))

                VStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.primary.opacity(0.06))
                            .frame(height: 1)
                            .frame(maxHeight: hourHeight, alignment: .top)
                            .padding(.top, hourHeight - 1)
                    }
                }

                ForEach(day.entries) { entry in
                    TimelineWeekEntryBlock(
                        entry: entry,
                        yOffset: yOffset(for: entry, dayStart: day.date),
                        height: blockHeight(for: entry, dayStart: day.date)
                    )
                }
            }
            .frame(minWidth: 92, maxWidth: .infinity)
            .frame(height: hourHeight * 24)
        }
    }

    private func entries(forDayStarting dayStart: Date) -> [TimelineEntryRecord] {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return model.entries
            .filter { $0.end > dayStart && $0.start < dayEnd }
            .sorted { $0.start < $1.start }
    }

    private func yOffset(for entry: TimelineEntryRecord, dayStart: Date) -> CGFloat {
        let clippedStart = max(entry.start, dayStart)
        let seconds = max(0, clippedStart.timeIntervalSince(dayStart))
        return CGFloat(seconds / 3_600) * hourHeight
    }

    private func blockHeight(for entry: TimelineEntryRecord, dayStart: Date) -> CGFloat {
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        let clippedStart = max(entry.start, dayStart)
        let clippedEnd = min(entry.end, dayEnd)
        let seconds = max(0, clippedEnd.timeIntervalSince(clippedStart))
        return max(10, CGFloat(seconds / 3_600) * hourHeight)
    }

    private func hourLabel(_ logicalHour: Int) -> String {
        let hour = (WeeklyStatsBuilder.logicalDayStartHour + logicalHour) % 24
        switch hour {
        case 0:
            return "12 AM"
        case 1..<12:
            return "\(hour) AM"
        case 12:
            return "12 PM"
        default:
            return "\(hour - 12) PM"
        }
    }

    private var weekdayFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter
    }

    private var dayNumberFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter
    }
}

private struct TimelineWeekDayColumn: Identifiable {
    let id: Int
    let date: Date
    let entries: [TimelineEntryRecord]
}

private struct TimelineWeekEntryBlock: View {
    let entry: TimelineEntryRecord
    let yOffset: CGFloat
    let height: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.caption2.weight(.semibold))
                Text(entry.title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(2)
            }
            if height > 24 {
                Text(entry.category)
                    .font(.caption2)
                    .lineLimit(1)
                    .opacity(0.82)
            }
        }
        .foregroundStyle(.white)
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.timelineHex(entry.colorHex).opacity(entry.kind == .idle ? 0.45 : 0.88))
        )
        .offset(y: yOffset)
        .padding(.horizontal, 4)
        .help("\(entry.title) - \(entry.category)")
    }

    private var iconName: String {
        switch entry.kind {
        case .activity:
            return "rectangle.stack"
        case .meeting:
            return "mic"
        case .dictation:
            return "keyboard"
        case .idle:
            return "moon"
        }
    }
}

extension TimelineWeekGridView {
    static var sample: TimelineWeekGridView {
        TimelineWeekGridView(model: TimelineSampleData.model)
    }
}

extension Color {
    static func timelineHex(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let value = Int(cleaned, radix: 16) ?? 0x6AADFF
        let red = Double((value >> 16) & 0xff) / 255
        let green = Double((value >> 8) & 0xff) / 255
        let blue = Double(value & 0xff) / 255
        return Color(red: red, green: green, blue: blue)
    }
}

enum TimelineSampleData {
    static var model: TimelineWeekGridModel {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let weekStart = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 4)) ?? Date()
        return TimelineWeekGridModel(weekStart: weekStart, entries: entries(weekStart: weekStart, calendar: calendar))
    }

    private static func entries(weekStart: Date, calendar: Calendar) -> [TimelineEntryRecord] {
        [
            entry("deep-work", "Launch polish", 0, 9, 120, .activity, "Work", "#B984FF", "Xcode"),
            entry("standup", "Product standup", 0, 12, 45, .meeting, "Meetings", "#1DAE9F", "Zoom"),
            entry("notes", "Dictation cleanup", 1, 10, 35, .dictation, "Meetings", "#1DAE9F", "Transcripted"),
            entry("research", "Pricing research", 2, 14, 160, .activity, "Work", "#B984FF", "Safari"),
            entry("admin", "Inbox and errands", 3, 11, 50, .activity, "Personal", "#6AADFF", "Mail"),
            entry("idle", "Away", 4, 18, 80, .idle, "Idle", "#A0AEC0", nil),
            entry("review", "Weekly review", 5, 9, 95, .activity, "Work", "#B984FF", "Obsidian")
        ].compactMap { make in
            make(weekStart, calendar)
        }
    }

    private static func entry(
        _ id: String,
        _ title: String,
        _ dayOffset: Int,
        _ hour: Int,
        _ minutes: Int,
        _ kind: TimelineEntryKind,
        _ category: String,
        _ colorHex: String,
        _ appSiteLabel: String?
    ) -> (Date, Calendar) -> TimelineEntryRecord? {
        { weekStart, calendar in
            guard let day = calendar.date(byAdding: .day, value: dayOffset, to: weekStart),
                  let start = calendar.date(byAdding: .hour, value: hour - WeeklyStatsBuilder.logicalDayStartHour, to: day),
                  let end = calendar.date(byAdding: .minute, value: minutes, to: start) else {
                return nil
            }
            return TimelineEntryRecord(
                id: id,
                title: title,
                start: start,
                end: end,
                kind: kind,
                category: category,
                colorHex: colorHex,
                appSiteLabel: appSiteLabel
            )
        }
    }
}
