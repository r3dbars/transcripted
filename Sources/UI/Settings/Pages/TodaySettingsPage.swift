import SwiftUI

/// The Stats page (kept under the `.today` route for stable automation ids
/// and analytics continuity): quiet-paper KPI cards across Today / 7 days /
/// 30 days / All time, a 7-day activity bar strip, streak & capture-mix
/// breakdowns, and a Recent Meetings quick jump. Pure view assembly; all disk
/// reads run off-main in `TodayViewModel` with zero per-minute timers.
struct TodaySettingsPage: View {
    @ObservedObject var todayViewModel: TodayViewModel
    let onOpenRecentItem: (TodayRecentItem) -> Void
    let onOpenMeetings: () -> Void
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void
    /// The person's own dictation key and behavior, for the empty state.
    let keyHint: TodayKeyHint
    let meetingShortcut: String?
    let setupChecklist: TodaySetupChecklistState
    let onSetupStep: (TodaySetupStep) -> Void
    let onDismissSetup: () -> Void
    let isRecordingMeeting: Bool

    @State private var selectedRange: TodayStatsRange = .last7Days

    private var snapshot: TodaySnapshot { todayViewModel.snapshot }
    private var overview: TodayStatsOverview { snapshot.overview }
    private var summary: TodayRangeSummary { overview.summary(for: selectedRange) }

    /// Nothing saved yet, ever (as far as the last read knows).
    private var isFirstDay: Bool {
        todayViewModel.hasLoaded && !overview.hasAnyCapture && snapshot.recent.isEmpty && !isRecordingMeeting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            header

            if !overview.hasAnyCapture && snapshot.recent.isEmpty && todayViewModel.isRefreshing && !isRecordingMeeting {
                Text("Loading…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            } else if isFirstDay {
                TodayFirstDayIntro(
                    hint: keyHint,
                    meetingShortcut: meetingShortcut,
                    showsTranscribeFile: !setupChecklist.isShown,
                    onStartMeeting: onStartMeeting,
                    onImportAudioFile: onImportAudioFile
                )
            } else if todayViewModel.hasLoaded || overview.hasAnyCapture {
                kpiGrid
                StatsSevenDayCard(
                    days: overview.dailyActivity,
                    activeDaysLast7: overview.streak.activeDaysLast7,
                    showsWriting: overview.hasWriting
                )
                breakdownRow
                recentMeetingsSection
            } else {
                Text("Loading…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }

            if todayViewModel.hasLoaded && setupChecklist.isShown {
                TodaySetupChecklist(state: setupChecklist, onStep: onSetupStep, onDismiss: onDismissSetup)
                    .padding(.top, isFirstDay ? 6 : 4)
            }
        }
        .overlay(alignment: .topLeading) {
            TodayDayRollover(storedDay: snapshot.builtAt) {
                todayViewModel.refresh(force: true)
            }
            .allowsHitTesting(false)
        }
        .accessibilityIdentifier("transcripted.today.page")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Stats")
                    .font(LibraryTokens.title)
                    .foregroundStyle(LibraryTokens.ink)
                Text("Local activity stored on this Mac.")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if overview.hasAnyCapture {
                StatsRangeControl(selection: $selectedRange)
            }
        }
    }

    // MARK: Summary KPI cards

    private var kpiGrid: some View {
        let meetingSubtitle: String = {
            if summary.meetings == 0 { return "No meetings in range" }
            if summary.meetingMinutes > 0 {
                return "\(TodayCopy.duration(minutes: summary.meetingMinutes)) recorded"
            }
            return "Duration not recorded"
        }()

        let meetingTimeSubtitle: String = {
            guard let avg = summary.averageMeetingMinutes else {
                return summary.meetings > 0 ? "No durations saved" : "Across recorded calls"
            }
            return "\(TodayCopy.duration(minutes: avg)) avg per meeting"
        }()

        let dictationsSubtitle: String = {
            if summary.dictations == 0 { return "No dictations in range" }
            return TodayCopy.words(summary.dictationWords)
        }()

        let wordsSubtitle: String = {
            if summary.totalWords == 0 { return "Dictations & notes" }
            if summary.writingWords > 0 && summary.dictationWords > 0 {
                return "\(TodayFormatterCache.decimalString(summary.dictationWords)) dictated · \(TodayFormatterCache.decimalString(summary.writingWords)) written"
            }
            if summary.writingWords > 0 {
                return "From writing"
            }
            return "From dictations"
        }()

        return HStack(spacing: 12) {
            StatsKPICard(
                label: "Meetings",
                value: TodayFormatterCache.decimalString(summary.meetings),
                subtitle: meetingSubtitle,
                streamColor: LibraryTokens.meetingsStream
            )
            StatsKPICard(
                label: "Meeting time",
                value: TodayCopy.duration(minutes: summary.meetingMinutes),
                subtitle: meetingTimeSubtitle,
                streamColor: nil
            )
            StatsKPICard(
                label: "Dictations",
                value: TodayFormatterCache.decimalString(summary.dictations),
                subtitle: dictationsSubtitle,
                streamColor: LibraryTokens.dictationStream
            )
            StatsKPICard(
                label: "Words captured",
                value: TodayFormatterCache.decimalString(summary.totalWords),
                subtitle: wordsSubtitle,
                streamColor: nil
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.today.kpis")
    }

    // MARK: Breakdowns

    private var breakdownRow: some View {
        HStack(alignment: .top, spacing: 12) {
            StatsStreakCard(streak: overview.streak)
            StatsCaptureMixCard(
                segments: overview.captureMix(for: selectedRange),
                rangeTitle: selectedRange.title
            )
        }
    }

    // MARK: Recent meetings quick jump

    private var recentMeetingsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                LibrarySectionLabel(text: "Recent meetings")
                Spacer(minLength: 12)
                Button(action: onOpenMeetings) {
                    HStack(spacing: 4) {
                        Text("Open Meetings")
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcripted.today.open-meetings")
            }

            if snapshot.recentMeetings.isEmpty {
                HStack(spacing: 12) {
                    Text("No meetings recorded yet.")
                        .font(LibraryTokens.body)
                        .foregroundStyle(LibraryTokens.ink2)
                    Spacer(minLength: 12)
                    Button("Record a meeting", action: onStartMeeting)
                        .buttonStyle(.transcriptedSecondary)
                        .controlSize(.small)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .statsCardSurface()
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(snapshot.recentMeetings.enumerated()), id: \.element.id) { index, item in
                        StatsRecentMeetingRow(item: item, referenceDate: snapshot.builtAt) {
                            onOpenRecentItem(item)
                        }
                        if index + 1 < snapshot.recentMeetings.count {
                            Rectangle()
                                .fill(LibraryTokens.hairline)
                                .frame(height: 1)
                                .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.vertical, 4)
                .statsCardSurface()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.today.recent-meetings")
    }
}

// MARK: - Subviews

extension TodayRecentItem.Kind {
    var streamColor: Color {
        switch self {
        case .meeting: return LibraryTokens.meetingsStream
        case .dictation: return LibraryTokens.dictationStream
        case .writing: return LibraryTokens.writingStream
        }
    }
}

private extension View {
    func statsCardSurface() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                    .fill(LibraryTokens.raisedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                    .stroke(LibraryTokens.raisedStroke, lineWidth: 0.5)
            )
    }
}

/// Quiet segmented range switcher: Today | 7 days | 30 days | All time.
private struct StatsRangeControl: View {
    @Binding var selection: TodayStatsRange

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TodayStatsRange.allCases) { range in
                let isSelected = selection == range
                Button {
                    withAnimation(.easeOut(duration: 0.14)) {
                        selection = range
                    }
                } label: {
                    Text(range.title)
                        .font(TextRole.meta.font(weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? LibraryTokens.ink : LibraryTokens.ink2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                                .fill(isSelected ? DesignTokens.fillStrong : Color.clear)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
                .accessibilityIdentifier("transcripted.today.range.\(range.rawValue)")
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 2, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 2, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.today.range")
    }
}

private struct StatsKPICard: View {
    let label: String
    let value: String
    let subtitle: String
    let streamColor: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let streamColor {
                    Circle()
                        .fill(streamColor)
                        .frame(width: 6, height: 6)
                }
                Text(label.uppercased())
                    .font(LibraryTokens.label)
                    .tracking(LibraryTokens.labelTracking)
                    .foregroundStyle(LibraryTokens.ink3)
                    .lineLimit(1)
            }
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(LibraryTokens.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(subtitle)
                .font(LibraryTokens.small)
                .foregroundStyle(LibraryTokens.ink2)
                .lineLimit(1)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCardSurface()
        .accessibilityElement(children: .combine)
    }
}

/// Rolling 7-day stacked activity bar strip. Static between snapshots and
/// midnight rollover — no minute-ticking view rebuilds.
private struct StatsSevenDayCard: View {
    let days: [TodayActivityDay]
    let activeDaysLast7: Int
    let showsWriting: Bool

    private static let maxBarHeight: CGFloat = 68

    private var peakCaptures: Int {
        max(1, days.map(\.totalCaptures).max() ?? 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                LibrarySectionLabel(
                    text: "Last 7 days",
                    trailing: "\(activeDaysLast7) of \(TodayStatsBuilder.activityDayCount) active"
                )
                Spacer(minLength: 8)
                legend
            }

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(days) { day in
                    dayColumn(day)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.today.activity-7d")
    }

    private var legend: some View {
        HStack(spacing: 12) {
            legendDot("Meetings", color: LibraryTokens.meetingsStream)
            legendDot("Dictations", color: LibraryTokens.dictationStream)
            if showsWriting {
                legendDot("Writing", color: LibraryTokens.writingStream)
            }
        }
    }

    private func legendDot(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(LibraryTokens.small)
                .foregroundStyle(LibraryTokens.ink2)
        }
    }

    private func dayColumn(_ day: TodayActivityDay) -> some View {
        let total = day.totalCaptures
        let scaledHeight = total > 0
            ? max(8, Self.maxBarHeight * CGFloat(total) / CGFloat(peakCaptures))
            : 4
        let tooltip = TodayCopy.dayActivityTooltip(day)

        return VStack(spacing: 6) {
            Text(total > 0 ? "\(total)" : " ")
                .font(LibraryTokens.small)
                .monospacedDigit()
                .foregroundStyle(day.isToday ? LibraryTokens.ink : LibraryTokens.ink3)

            ZStack(alignment: .bottom) {
                Color.clear
                    .frame(height: Self.maxBarHeight)
                if total == 0 {
                    Capsule()
                        .fill(LibraryTokens.hairline)
                        .frame(maxWidth: 26)
                        .frame(height: 3)
                } else {
                    VStack(spacing: 1.5) {
                        if day.writingEntries > 0 {
                            segment(count: day.writingEntries, total: total, barHeight: scaledHeight, color: LibraryTokens.writingStream)
                        }
                        if day.dictations > 0 {
                            segment(count: day.dictations, total: total, barHeight: scaledHeight, color: LibraryTokens.dictationStream)
                        }
                        if day.meetings > 0 {
                            segment(count: day.meetings, total: total, barHeight: scaledHeight, color: LibraryTokens.meetingsStream)
                        }
                    }
                    .frame(maxWidth: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
            }

            VStack(spacing: 1) {
                Text(day.isToday ? "Today" : TodayCopy.weekdayShort(for: day.day))
                    .font(TextRole.small.font(weight: day.isToday ? .semibold : .regular))
                    .foregroundStyle(day.isToday ? LibraryTokens.ink : LibraryTokens.ink2)
                Text(TodayCopy.dayNumber(for: day.day))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink3)
            }
        }
        .frame(maxWidth: .infinity)
        .help(tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tooltip)
    }

    private func segment(count: Int, total: Int, barHeight: CGFloat, color: Color) -> some View {
        let height = max(3, barHeight * CGFloat(count) / CGFloat(total))
        return Rectangle()
            .fill(color)
            .frame(height: height)
    }
}

private struct StatsStreakCard: View {
    let streak: TodayStreakSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibrarySectionLabel(text: "Streak")

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(TodayFormatterCache.decimalString(streak.currentDays))
                    .font(.system(size: 26, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink)
                Text(streak.currentDays == 1 ? "active day in a row" : "active days in a row")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
            }

            VStack(spacing: 7) {
                metricRow("Best streak", value: TodayCopy.count(streak.longestDays, singular: "day", plural: "days"))
                metricRow("Last 30 days", value: "\(streak.activeDaysLast30) of \(TodayStatsBuilder.rollingMonthDayCount) days")
                metricRow("All-time active", value: TodayCopy.count(streak.totalActiveDays, singular: "day", plural: "days"))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.today.streak")
    }

    private func metricRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
            Spacer(minLength: 12)
            Text(value)
                .font(TextRole.meta.font(weight: .medium))
                .monospacedDigit()
                .foregroundStyle(LibraryTokens.ink)
        }
    }
}

private struct StatsCaptureMixCard: View {
    let segments: [TodayCaptureMixSegment]
    let rangeTitle: String

    private var hasCaptures: Bool {
        segments.contains { $0.count > 0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LibrarySectionLabel(text: "Capture mix", trailing: rangeTitle)

            GeometryReader { geo in
                let active = segments.filter { $0.count > 0 }
                let spacing: CGFloat = 2
                let availableWidth = max(0, geo.size.width - spacing * CGFloat(max(0, active.count - 1)))
                HStack(spacing: spacing) {
                    if active.isEmpty {
                        Capsule()
                            .fill(LibraryTokens.hairline)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(active) { segment in
                            Rectangle()
                                .fill(segment.kind.streamColor)
                                .frame(width: max(4, availableWidth * CGFloat(segment.share)))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)

            VStack(spacing: 7) {
                ForEach(segments) { segment in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(segment.kind.streamColor)
                            .frame(width: 7, height: 7)
                        Text(segment.title)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink)
                        Spacer(minLength: 8)
                        Text(segment.detail)
                            .font(LibraryTokens.small)
                            .foregroundStyle(LibraryTokens.ink3)
                            .monospacedDigit()
                        Text(hasCaptures ? "\(segment.percentage)%" : "0%")
                            .font(TextRole.meta.font(weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(LibraryTokens.ink2)
                            .frame(width: 34, alignment: .trailing)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .statsCardSurface()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.today.capture-mix")
    }
}

private struct StatsRecentMeetingRow: View {
    let item: TodayRecentItem
    let referenceDate: Date
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Circle()
                    .fill(LibraryTokens.meetingsStream)
                    .frame(width: 7, height: 7)
                Text(item.title)
                    .font(LibraryTokens.rowTitle)
                    .foregroundStyle(LibraryTokens.ink)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if let duration = TodayCopy.rowDuration(seconds: item.durationSeconds) {
                    Text(duration)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink3)
                        .monospacedDigit()
                }
                Text(TodayCopy.rowWhen(for: item.date, now: referenceDate))
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isHovering ? LibraryTokens.ink2 : LibraryTokens.ink3)
            }
            .padding(.horizontal, 12)
            .frame(minHeight: LibraryTokens.minimumHitTarget)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
                    .padding(.horizontal, 4)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Open in Meetings")
        .accessibilityIdentifier("transcripted.today.recent-meeting")
    }
}
