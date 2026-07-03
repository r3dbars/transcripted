import SwiftUI

struct TimelineDashboardView: View {
    let stats: TimelineWeeklyStats

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                metricChip("Active", minutes: stats.totalActiveMinutes, systemImage: "clock")
                metricChip("Meetings", minutes: stats.meetingMinutes, systemImage: "mic")
                metricChip("Dictation", minutes: stats.dictationMinutes, systemImage: "keyboard")
                if let focus = stats.longestFocus {
                    metricChip("Longest focus", minutes: focus.minutes, systemImage: "scope")
                }
            }

            HStack(alignment: .top, spacing: 20) {
                categoryDonut
                    .frame(width: 172, height: 172)

                VStack(alignment: .leading, spacing: 14) {
                    categoryLegend
                    topAppsList
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            focusHeatmap
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.88))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func metricChip(_ title: String, minutes: Int, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(format(minutes: minutes))
                .font(.title3.weight(.semibold))
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var categoryDonut: some View {
        ZStack {
            TimelineDonutView(stats: stats.categoryStats)
                .frame(width: 140, height: 140)
            VStack(spacing: 2) {
                Text(format(minutes: stats.totalActiveMinutes))
                    .font(.title3.weight(.semibold))
                Text("tracked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var categoryLegend: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Categories")
                .font(.headline)
            ForEach(stats.categoryStats) { stat in
                HStack(spacing: 8) {
                    Circle()
                        .fill(Color.timelineHex(stat.colorHex))
                        .frame(width: 8, height: 8)
                    Text(stat.category)
                        .font(.callout)
                    Spacer()
                    Text("\(format(minutes: stat.minutes)) · \(stat.percentage)%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var topAppsList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Top apps/sites")
                .font(.headline)
            if stats.topAppSites.isEmpty {
                Text("No app/site data yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(stats.topAppSites) { app in
                    HStack {
                        Text(app.label)
                            .font(.callout)
                            .lineLimit(1)
                        Spacer()
                        Text(format(minutes: app.minutes))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var focusHeatmap: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Focus heatmap")
                .font(.headline)
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<7, id: \.self) { day in
                    VStack(spacing: 4) {
                        Text(shortDayLabel(day))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        ForEach(0..<24, id: \.self) { hour in
                            let minutes = stats.heatmapCells.first { $0.dayIndex == day && $0.hourIndex == hour }?.minutes ?? 0
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(heatmapColor(minutes: minutes))
                                .frame(height: 7)
                                .help("\(minutes) min")
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func shortDayLabel(_ offset: Int) -> String {
        let date = Calendar.current.date(byAdding: .day, value: offset, to: stats.weekStart) ?? stats.weekStart
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func heatmapColor(minutes: Int) -> Color {
        switch WeeklyStatsBuilder.bucket(minutes: minutes) {
        case .zero:
            return Color.primary.opacity(0.045)
        case .underFifteenMinutes:
            return Color.accentColor.opacity(0.18)
        case .underOneHour:
            return Color.accentColor.opacity(0.34)
        case .oneToThreeHours:
            return Color.accentColor.opacity(0.52)
        case .threeToSixHours:
            return Color.accentColor.opacity(0.72)
        case .sixHoursPlus:
            return Color.accentColor.opacity(0.92)
        }
    }

    private func format(minutes: Int) -> String {
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }
}

private struct TimelineDonutView: View {
    let stats: [TimelineCategoryStat]

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.08), lineWidth: 18)
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                Circle()
                    .trim(from: segment.start, to: segment.end)
                    .stroke(Color.timelineHex(segment.colorHex), style: StrokeStyle(lineWidth: 18, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        }
    }

    private var segments: [TimelineDonutSegment] {
        let total = max(1, stats.reduce(0) { $0 + $1.minutes })
        var cursor = 0.0
        return stats.map { stat in
            let start = cursor
            cursor += Double(stat.minutes) / Double(total)
            return TimelineDonutSegment(start: start, end: cursor, colorHex: stat.colorHex)
        }
    }
}

private struct TimelineDonutSegment {
    let start: Double
    let end: Double
    let colorHex: String
}

extension TimelineDashboardView {
    static var sample: TimelineDashboardView {
        let model = TimelineSampleData.model
        return TimelineDashboardView(
            stats: WeeklyStatsBuilder.build(entries: model.entries, weekStart: model.weekStart)
        )
    }
}
