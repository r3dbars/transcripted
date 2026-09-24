import SwiftUI

/// The Today page: what the app captured today and this week, the week as
/// tape, and the latest captures. Pure view assembly; loading lives in
/// `TodayViewModel`, numbers and copy in `TodayPresentation.swift`, and every
/// navigation or capture action is injected by the settings shell.
struct TodaySettingsPage: View {
    @ObservedObject var todayViewModel: TodayViewModel
    let now: Date
    let onOpenRecentItem: (TodayRecentItem) -> Void
    let onLoadMoreRecent: () -> Void
    let onShowMeetings: () -> Void
    let onShowDictations: () -> Void
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void
    let onStartDictation: () -> Void

    private var snapshot: TodaySnapshot { todayViewModel.snapshot }
    private var stats: TodayContextStats { snapshot.stats }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header

            if todayViewModel.hasLoaded && !stats.hasAnyCapture && snapshot.recent.isEmpty {
                emptyState
            } else {
                countsSection
                recentSection
            }
        }
        .accessibilityIdentifier("transcripted.today.page")
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Today")
                .font(LibraryTokens.title)
            Text(TodayCopy.dateLine(for: now))
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
        }
    }

    // MARK: Counts and the week

    private var countsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                TodayStatTile(
                    systemImage: "bubble.left.and.bubble.right.fill",
                    tint: LibraryTokens.meetingsStream,
                    value: "\(stats.todayMeetings)",
                    label: stats.todayMeetings == 1 ? "meeting today" : "meetings today",
                    detail: "\(stats.weekMeetings) this week",
                    automationIdentifier: "transcripted.today.stat.meetings",
                    action: onShowMeetings
                )
                TodayStatTile(
                    systemImage: "mic.fill",
                    tint: LibraryTokens.dictationStream,
                    value: "\(stats.todayDictations)",
                    label: stats.todayDictations == 1 ? "dictation today" : "dictations today",
                    detail: "\(stats.weekDictations) this week · \(TodayCopy.words(stats.weekDictationWords))",
                    automationIdentifier: "transcripted.today.stat.dictations",
                    action: onShowDictations
                )
                TodayStatTile(
                    systemImage: "clock.fill",
                    tint: LibraryTokens.meetingsStream,
                    value: TodayCopy.duration(minutes: stats.todayMeetingMinutes),
                    label: "in meetings today",
                    detail: "\(TodayCopy.duration(minutes: stats.weekMeetingMinutes)) this week",
                    automationIdentifier: "transcripted.today.stat.minutes",
                    action: nil
                )
            }

            if !snapshot.tapeDays.isEmpty {
                TodayDayTapeCard(days: snapshot.tapeDays, now: now, onOpen: onOpenRecentItem)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("RECENT CONTEXT", help: "The latest meetings and dictations saved on this Mac")

            if snapshot.recent.isEmpty {
                Text(todayViewModel.hasLoaded ? "Nothing saved yet." : "Loading…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .padding(.vertical, 6)
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.recent) { item in
                        TodayRecentRow(item: item, now: now) {
                            onOpenRecentItem(item)
                        }
                    }
                }
                if snapshot.canLoadMoreRecent {
                    Button("Load more", action: onLoadMoreRecent)
                        .buttonStyle(.plain)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.accent)
                        .padding(.horizontal, 8)
                        .padding(.top, 4)
                        .accessibilityIdentifier("transcripted.today.recent.load-more")
                }
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Nothing captured yet.")
                .font(.system(size: 15, weight: .semibold))
            Text("Dictate into any app or record a meeting. Everything you save lands here, and your AI tools can read it.")
                .font(LibraryTokens.body)
                .foregroundStyle(LibraryTokens.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 460, alignment: .leading)
            HStack(spacing: 8) {
                Button("Start dictation", action: onStartDictation)
                    .accessibilityIdentifier("transcripted.today.empty.start-dictation")
                Button("Record a meeting", action: onStartMeeting)
                    .accessibilityIdentifier("transcripted.today.empty.record-meeting")
                Button("Transcribe a file…", action: onImportAudioFile)
                    .accessibilityIdentifier("transcripted.today.empty.transcribe-file")
            }
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    private func sectionLabel(_ title: String, help: String?) -> some View {
        Text(title)
            .font(LibraryTokens.label)
            .tracking(LibraryTokens.labelTracking)
            .foregroundStyle(LibraryTokens.ink3)
            .help(help ?? "")
    }
}

// MARK: - Pieces

private struct TodayStatTile: View {
    let systemImage: String
    let tint: Color
    let value: String
    let label: String
    let detail: String
    let automationIdentifier: String
    let action: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(label)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(LibraryTokens.ink3)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(isHovering && action != nil ? LibraryTokens.rowHover : LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous))
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(automationIdentifier)

        if let action {
            Button(action: action) { content }
                .buttonStyle(.plain)
        } else {
            content
        }
    }
}

/// The week as tape, after the Context app's Days view: seven small day
/// cards across the top, each with one mini line per stream, and the picked
/// day (today to start) drawn full width below it, 6 AM to midnight. A
/// meeting is a capsule as long as the meeting, a dictation is a dot. Hover a
/// mark to see what it is; click it to open it on its own page.
private struct TodayDayTapeCard: View {
    let days: [TodayTapeDay]
    let now: Date
    let onOpen: (TodayRecentItem) -> Void

    @State private var selectedDayID: TimeInterval?
    @State private var hoveredMarkID: String?

    private var selectedDay: TodayTapeDay? {
        days.first { $0.id == selectedDayID } ?? days.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                ForEach(days) { day in
                    TodayWeekCell(day: day, isSelected: day.id == selectedDay?.id) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedDayID = day.id
                            hoveredMarkID = nil
                        }
                    }
                }
            }

            if let selectedDay {
                fullTape(selectedDay)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 0.5)
        )
        .accessibilityIdentifier("transcripted.today.day-tape")
    }

    private func fullTape(_ day: TodayTapeDay) -> some View {
        let hovered = (day.meetings + day.dictations).first { $0.id == hoveredMarkID }
        return VStack(alignment: .leading, spacing: 9) {
            lane("Meetings", color: LibraryTokens.meetingsStream, marks: day.meetings, day: day)
            lane("Dictation", color: LibraryTokens.dictationStream, marks: day.dictations, day: day)
            HStack(spacing: 0) {
                ForEach(TodayTapeBuilder.hourLabels, id: \.self) { hour in
                    Text(hour)
                        .font(.system(size: 10))
                        .foregroundStyle(LibraryTokens.ink3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, Self.laneLabelWidth + 12)

            Group {
                if let hovered {
                    Text(TodayTapeBuilder.markDescription(hovered, now: now) + "  \u{00B7}  Click to open")
                } else if day.isEmpty {
                    Text(day.isToday ? "Nothing saved yet today." : "Nothing saved this day.")
                } else {
                    Text("Hover a mark to see it. Click to open it.")
                }
            }
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.ink2)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.leading, Self.laneLabelWidth + 12)
        }
        .padding(.top, 2)
    }

    private static let laneLabelWidth: CGFloat = 80

    private func lane(_ title: String, color: Color, marks: [TodayTapeMark], day: TodayTapeDay) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(LibraryTokens.ink2)
            }
            .frame(width: Self.laneLabelWidth, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                        .frame(height: 2)
                    ForEach(marks) { mark in
                        markView(mark, color: color, width: geo.size.width)
                    }
                    if day.isToday {
                        let nowFraction = TodayTapeBuilder.fraction(of: now, onDayStarting: day.day)
                        Rectangle()
                            .fill(LibraryTokens.accent)
                            .frame(width: 2, height: 22)
                            .offset(x: geo.size.width * nowFraction - 1)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 18)
            }
            .frame(height: 18)
        }
    }

    private func markView(_ mark: TodayTapeMark, color: Color, width: CGFloat) -> some View {
        let markWidth: CGFloat = mark.isDot ? 10 : max(8, width * CGFloat((mark.end ?? mark.start) - mark.start))
        let isHovered = hoveredMarkID == mark.id
        return Button {
            onOpen(mark.item)
        } label: {
            Capsule()
                .fill(color)
                .frame(width: markWidth, height: 10)
                .scaleEffect(isHovered ? 1.2 : 1)
                .frame(height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: min(width * CGFloat(mark.start), max(0, width - markWidth)))
        .zIndex(isHovered ? 1 : 0)
        .onHover { hovering in
            if hovering {
                hoveredMarkID = mark.id
            } else if hoveredMarkID == mark.id {
                hoveredMarkID = nil
            }
        }
        .help(TodayTapeBuilder.markDescription(mark, now: now))
        .accessibilityLabel(TodayTapeBuilder.markDescription(mark, now: now))
        .accessibilityHint(mark.item.kind == .meeting ? "Opens the meeting" : "Opens Dictations")
        .accessibilityIdentifier("transcripted.today.tape.mark")
    }
}

/// One day in the week strip: weekday, date, and one mini line per stream.
private struct TodayWeekCell: View {
    let day: TodayTapeDay
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 2) {
                Text(TodayCopy.weekdayShort(for: day.day))
                    .font(.system(size: 10.5))
                    .foregroundStyle(day.isToday ? LibraryTokens.accent : LibraryTokens.ink3)
                Text(TodayCopy.dayNumber(for: day.day))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(day.isEmpty ? LibraryTokens.ink3 : Color.primary)
                VStack(spacing: 4) {
                    miniLane(day.meetings, color: LibraryTokens.meetingsStream)
                    miniLane(day.dictations, color: LibraryTokens.dictationStream)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 8)
            .padding(.top, 7)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? LibraryTokens.contentBackground : (isHovering ? LibraryTokens.rowHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isSelected ? Color.primary.opacity(0.16) : Color.clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(TodayCopy.dateLine(for: day.day))
        .accessibilityLabel("\(TodayCopy.dateLine(for: day.day)): \(TodayCopy.count(day.meetings.count, singular: "meeting", plural: "meetings")), \(TodayCopy.count(day.dictations.count, singular: "dictation", plural: "dictations"))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("transcripted.today.week-cell")
    }

    private func miniLane(_ marks: [TodayTapeMark], color: Color) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                ForEach(marks) { mark in
                    let width = mark.isDot ? 4 : max(3, geo.size.width * CGFloat((mark.end ?? mark.start) - mark.start))
                    Capsule()
                        .fill(color)
                        .frame(width: width, height: 4)
                        .offset(x: min(geo.size.width * CGFloat(mark.start), geo.size.width - width))
                }
            }
        }
        .frame(height: 4)
    }
}

private struct TodayRecentRow: View {
    let item: TodayRecentItem
    let now: Date
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.kind == .meeting ? "bubble.left.and.bubble.right" : "mic")
                    .font(.system(size: 12))
                    .foregroundStyle(LibraryTokens.ink2)
                    .frame(width: 18)
                Text(item.title)
                    .font(LibraryTokens.rowTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 12)
                if isHovering {
                    Text("Open")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.accent)
                }
                Text(meta)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .monospacedDigit()
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 34)
            .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(item.kind == .meeting ? "Open in Meetings" : "Open in Dictations")
        .accessibilityIdentifier("transcripted.today.recent.row")
    }

    private var meta: String {
        let when = TodayCopy.rowWhen(for: item.date, now: now)
        guard let duration = TodayCopy.rowDuration(seconds: item.durationSeconds) else { return when }
        return "\(duration) · \(when)"
    }
}
