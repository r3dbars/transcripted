import SwiftUI

/// Monthly activity heat map showing recording activity per day
/// "Night Studio" aesthetic with 5-step color gradient and premium styling
@available(macOS 14.0, *)
struct HeatMapView: View {

    @ObservedObject var statsService: StatsService

    @State private var selectedDate: Date = Date()
    @State private var hoveredDay: String?
    @State private var tooltipActivity: DailyActivity?
    @State private var isHovered = false

    private let calendar = Calendar.current
    private let dayLabels = ["S", "M", "T", "W", "T", "F", "S"]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Header with month navigation
            headerView

            // Day labels
            dayLabelsRow

            // Calendar grid
            calendarGrid

            // Legend and stats
            footerView
        }
        .padding(Spacing.md)
        .premiumCard(isHovered: isHovered, glowColor: .recordingCoral)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Monthly Activity")
                .font(.headingSmall)
                .foregroundColor(.panelTextPrimary)

            Spacer()

            // Month navigation
            HStack(spacing: Spacing.sm) {
                Button {
                    withAnimation {
                        selectedDate = calendar.date(byAdding: .month, value: -1, to: selectedDate) ?? selectedDate
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.caption)
                        .foregroundColor(.panelTextSecondary)
                }
                .buttonStyle(.plain)

                Text(monthYearString)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                    .frame(width: 100)

                Button {
                    withAnimation {
                        selectedDate = calendar.date(byAdding: .month, value: 1, to: selectedDate) ?? selectedDate
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.panelTextSecondary)
                }
                .buttonStyle(.plain)
                .disabled(calendar.isDate(selectedDate, equalTo: Date(), toGranularity: .month))
            }
        }
    }

    private var monthYearString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM yyyy"
        return formatter.string(from: selectedDate)
    }

    // MARK: - Day Labels

    private var dayLabelsRow: some View {
        HStack(spacing: Spacing.xs) {
            ForEach(dayLabels, id: \.self) { day in
                Text(day)
                    .font(.tiny)
                    .foregroundColor(.panelTextMuted)
                    .frame(width: cellSize, height: 16)
            }
        }
    }

    // MARK: - Calendar Grid

    private let cellSize: CGFloat = 24
    private let cellSpacing: CGFloat = 4

    private var calendarGrid: some View {
        let days = daysInMonth()
        let firstWeekday = firstDayOfMonthWeekday()
        let totalCells = firstWeekday + days.count

        return VStack(spacing: cellSpacing) {
            ForEach(0..<6, id: \.self) { week in
                HStack(spacing: cellSpacing) {
                    ForEach(0..<7, id: \.self) { day in
                        let cellIndex = week * 7 + day

                        if cellIndex < firstWeekday || cellIndex >= totalCells {
                            // Empty cell
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.clear)
                                .frame(width: cellSize, height: cellSize)
                        } else {
                            let dayIndex = cellIndex - firstWeekday
                            if dayIndex < days.count {
                                let dayDate = days[dayIndex]
                                HeatMapCell(
                                    date: dayDate,
                                    activity: activityFor(date: dayDate),
                                    isHovered: hoveredDay == dateString(for: dayDate),
                                    onHover: { isHovered in
                                        if isHovered {
                                            hoveredDay = dateString(for: dayDate)
                                            tooltipActivity = activityFor(date: dayDate)
                                        } else {
                                            hoveredDay = nil
                                            tooltipActivity = nil
                                        }
                                    }
                                )
                            }
                        }
                    }
                }
            }
        }
        .overlay(alignment: .top) {
            // Tooltip
            if let hoveredDay = hoveredDay, let activity = tooltipActivity {
                HeatMapTooltip(dateString: hoveredDay, activity: activity)
                    .offset(y: -60)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    .animation(.easeOut(duration: 0.15), value: hoveredDay)
            }
        }
    }

    // MARK: - Footer

    private var footerView: some View {
        HStack {
            // Active days count
            HStack(spacing: Spacing.xs) {
                Text("🔥")
                    .font(.caption)
                Text("\(statsService.activeDaysThisMonth) active days")
                    .font(.caption)
                    .foregroundColor(.panelTextSecondary)
            }

            Spacer()

            // Intensity legend
            HStack(spacing: 2) {
                Text("Less")
                    .font(.tiny)
                    .foregroundColor(.panelTextMuted)

                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(colorForIntensity(level))
                        .frame(width: 12, height: 12)
                }

                Text("More")
                    .font(.tiny)
                    .foregroundColor(.panelTextMuted)
            }
        }
    }

    // MARK: - Helpers

    private func daysInMonth() -> [Date] {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate)),
              let monthEnd = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: monthStart) else {
            return []
        }

        var days: [Date] = []
        var current = monthStart

        while current <= monthEnd {
            days.append(current)
            current = calendar.date(byAdding: .day, value: 1, to: current) ?? current
        }

        return days
    }

    private func firstDayOfMonthWeekday() -> Int {
        guard let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: selectedDate)) else {
            return 0
        }
        return calendar.component(.weekday, from: monthStart) - 1 // 0-indexed
    }

    private func dateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func activityFor(date: Date) -> DailyActivity? {
        let key = dateString(for: date)
        return statsService.monthlyActivity[key]
    }

    private func colorForIntensity(_ level: Int) -> Color {
        // 5-step gradient: Empty → Faint warmth → Warming → Engaged → Maximum coral
        switch level {
        case 0: return Color.heatMapLevel0
        case 1: return Color.heatMapLevel1
        case 2: return Color.heatMapLevel2
        case 3: return Color.heatMapLevel3
        case 4: return Color.heatMapLevel4
        default: return Color.heatMapLevel0
        }
    }
}

// MARK: - Heat Map Cell

@available(macOS 14.0, *)
struct HeatMapCell: View {

    let date: Date
    let activity: DailyActivity?
    let isHovered: Bool
    let onHover: (Bool) -> Void

    private let calendar = Calendar.current

    var body: some View {
        let isToday = calendar.isDateInToday(date)
        let isFuture = date > Date()

        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(cellColor)
            .frame(width: 24, height: 24)
            .overlay {
                if isToday {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(Color.panelTextPrimary.opacity(0.5), lineWidth: 1)
                }
            }
            .scaleEffect(isHovered ? 1.15 : 1.0)
            .animation(.easeOut(duration: 0.1), value: isHovered)
            .onHover { hovering in
                if !isFuture {
                    onHover(hovering)
                }
            }
    }

    private var cellColor: Color {
        let isFuture = date > Date()

        if isFuture {
            return Color.heatMapLevel0.opacity(0.3)
        }

        guard let activity = activity else {
            return Color.heatMapLevel0
        }

        // 5-step gradient: Empty → Faint warmth → Warming → Engaged → Maximum coral
        switch activity.intensityLevel {
        case 0: return Color.heatMapLevel0
        case 1: return Color.heatMapLevel1
        case 2: return Color.heatMapLevel2
        case 3: return Color.heatMapLevel3
        case 4: return Color.heatMapLevel4
        default: return Color.heatMapLevel0
        }
    }
}

// MARK: - Heat Map Tooltip

@available(macOS 14.0, *)
struct HeatMapTooltip: View {

    let dateString: String
    let activity: DailyActivity

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // Date
            Text(formattedDate)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.panelTextPrimary)

            // Stats
            if activity.recordingCount > 0 {
                HStack(spacing: Spacing.sm) {
                    Label("\(activity.recordingCount)", systemImage: "doc.text")
                    Label(activity.formattedDuration, systemImage: "clock")
                    if activity.actionItemsCount > 0 {
                        Label("\(activity.actionItemsCount)", systemImage: "checkmark.circle")
                    }
                }
                .font(.tiny)
                .foregroundColor(.panelTextSecondary)
            } else {
                Text("No activity")
                    .font(.tiny)
                    .foregroundColor(.panelTextMuted)
            }
        }
        .padding(Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.panelCharcoal)
                .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
        }
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: dateString) else { return dateString }

        let displayFormatter = DateFormatter()
        displayFormatter.dateStyle = .medium
        return displayFormatter.string(from: date)
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    HeatMapView(statsService: StatsService.shared)
        .frame(width: 300)
        .padding()
        .background(Color.panelCharcoal)
}
