import SwiftUI

/// The Today page: one sentence for the day, the week as a strip, the picked
/// day as three lanes (meetings, dictation, writing) with a preview of the
/// picked capture under them, then the latest captures. Pure view assembly;
/// loading lives in `TodayViewModel`, numbers and copy in
/// `TodayPresentation.swift`, and every navigation or capture action is
/// injected by the settings shell.
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

    /// Shared by the week strip and the day card; nil means today.
    @State private var selectedDayID: TimeInterval?

    private var snapshot: TodaySnapshot { todayViewModel.snapshot }
    private var stats: TodayContextStats { snapshot.stats }
    private var selectedDay: TodayTapeDay? {
        snapshot.tapeDays.first { $0.id == selectedDayID } ?? snapshot.tapeDays.last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header

            if todayViewModel.hasLoaded && !stats.hasAnyCapture && snapshot.recent.isEmpty {
                emptyState
            } else {
                if let selectedDay {
                    TodayDayCard(day: selectedDay, now: now, onOpen: onOpenRecentItem)
                }
                recentSection
            }
        }
        .accessibilityIdentifier("transcripted.today.page")
    }

    // MARK: Header

    /// Today's numbers, or the picked day's from its tape.
    private var headerStats: TodayContextStats {
        guard let selectedDay, !selectedDay.isToday else { return stats }
        return TodayTapeBuilder.dayStats(selectedDay)
    }

    private var header: some View {
        let day = selectedDay
        let isToday = day?.isToday ?? true
        return HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text(TodayCopy.dateLine(for: day?.day ?? now))
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                Text(isToday ? "Today" : TodayCopy.weekdayLong(for: day?.day ?? now))
                    .font(LibraryTokens.title)
                    .contentTransition(.opacity)
                TodaySentence(stats: headerStats, isToday: isToday)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !snapshot.tapeDays.isEmpty {
                HStack(spacing: 4) {
                    ForEach(snapshot.tapeDays) { day in
                        TodayWeekCell(day: day, isSelected: day.id == selectedDay?.id) {
                            withAnimation(.easeOut(duration: 0.15)) {
                                selectedDayID = day.isToday ? nil : day.id
                            }
                        }
                    }
                }
                .frame(width: 330)
            }
        }
    }

    // MARK: Recent

    private var recentSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("RECENT CONTEXT", help: "The latest meetings, dictations and writing saved on this Mac")

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

extension TodayRecentItem.Kind {
    var streamColor: Color {
        switch self {
        case .meeting: return LibraryTokens.meetingsStream
        case .dictation: return LibraryTokens.dictationStream
        case .writing: return LibraryTokens.writingStream
        }
    }

    var systemImage: String {
        switch self {
        case .meeting: return "bubble.left.and.bubble.right"
        case .dictation: return "mic"
        case .writing: return "pencil"
        }
    }
}

/// "4 meetings (2h 10m), 12 dictations, and 1,280 words written across 5
/// apps." Each stream in its color; the app count opens a per-app breakdown.
private struct TodaySentence: View {
    let stats: TodayContextStats
    let isToday: Bool

    @State private var showsApps = false

    var body: some View {
        let parts = TodayTapeBuilder.headerParts(stats)
        HStack(spacing: 0) {
            if parts.isEmpty {
                Text(isToday ? "Nothing saved yet today." : "Nothing saved this day.")
                    .foregroundStyle(LibraryTokens.ink2)
            } else {
                sentence(parts)
                if stats.todayWritingApps.count > 1 {
                    Text(" ")
                    Button {
                        showsApps.toggle()
                    } label: {
                        Text("across \(stats.todayWritingApps.count) apps")
                            .underline(pattern: .dot)
                    }
                    .buttonStyle(.plain)
                    .onHover { showsApps = $0 }
                    .popover(isPresented: $showsApps, arrowEdge: .bottom) { appBreakdown }
                    .accessibilityIdentifier("transcripted.today.header.apps")
                }
                Text(".")
            }
        }
        .font(.system(size: 15))
        .lineLimit(1)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcripted.today.header.sentence")
    }

    private func sentence(_ parts: [(kind: TodayRecentItem.Kind, text: String)]) -> Text {
        var text = Text("")
        for (index, part) in parts.enumerated() {
            if index > 0 {
                text = text + Text(index == parts.count - 1 ? (parts.count > 2 ? ", and " : " and ") : ", ")
            }
            text = text + Text(part.text).foregroundColor(part.kind.streamColor)
        }
        return text
    }

    private var appBreakdown: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(stats.todayWritingApps, id: \.appName) { app in
                HStack {
                    Text(app.appName)
                    Spacer(minLength: 16)
                    Text(TodayCopy.words(app.words))
                        .foregroundStyle(LibraryTokens.ink3)
                        .monospacedDigit()
                }
            }
        }
        .font(LibraryTokens.meta)
        .padding(12)
        .frame(width: 220)
    }
}

/// The picked day as three lanes, 6 AM to midnight, after the Context app's
/// Days view. A meeting or a writing entry is a capsule, a dictation is a dot.
/// Click a mark to pick it: it lights up, the rest dim, and the card under
/// the lanes shows what it was. Prev and Next step through the day.
private struct TodayDayCard: View {
    let day: TodayTapeDay
    let now: Date
    let onOpen: (TodayRecentItem) -> Void

    @State private var pickedMarkID: String?
    @State private var hoveredMarkID: String?

    private static let laneLabelWidth: CGFloat = 84

    /// The picked mark, or the day's latest one.
    private var picked: TodayTapeMark? {
        let marks = day.allMarks
        return marks.first { $0.id == pickedMarkID } ?? marks.max { $0.item.date < $1.item.date }
    }

    /// What the preview shows: the hovered mark, else the picked one.
    private var shown: TodayTapeMark? {
        day.allMarks.first { $0.id == hoveredMarkID } ?? picked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("YOUR DAY")
                    .font(LibraryTokens.label)
                    .tracking(LibraryTokens.labelTracking)
                    .foregroundStyle(LibraryTokens.ink3)
                Spacer()
                if day.isToday {
                    Text("Now \(TodayCopy.rowWhen(for: now, now: now))")
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.ink3)
                } else {
                    Text(TodayCopy.dateLine(for: day.day))
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.ink3)
                }
            }

            VStack(alignment: .leading, spacing: 9) {
                lane("Meetings", kind: .meeting, marks: day.meetings)
                lane("Dictation", kind: .dictation, marks: day.dictations)
                lane("Writing", kind: .writing, marks: day.writing)
                HStack(spacing: 0) {
                    ForEach(TodayTapeBuilder.hourLabels, id: \.self) { hour in
                        Text(hour)
                            .font(.system(size: 10))
                            .foregroundStyle(LibraryTokens.ink3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.leading, Self.laneLabelWidth + 12)
            }

            Group {
                if let shown {
                    preview(shown)
                } else {
                    Text(day.isToday ? "Nothing saved yet today." : "Nothing saved this day.")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                }
            }
            .padding(.leading, Self.laneLabelWidth + 12)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 0.5)
        )
        .onChange(of: day.id) { _, _ in pickedMarkID = nil }
        .accessibilityIdentifier("transcripted.today.day-tape")
    }

    private func lane(_ title: String, kind: TodayRecentItem.Kind, marks: [TodayTapeMark]) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(kind.streamColor).frame(width: 7, height: 7)
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
                        markView(mark, color: kind.streamColor, width: geo.size.width)
                    }
                    if day.isToday {
                        Rectangle()
                            .fill(LibraryTokens.accent)
                            .frame(width: 2, height: 22)
                            .offset(x: geo.size.width * TodayTapeBuilder.fraction(of: now, onDayStarting: day.day) - 1)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: 20)
            }
            .frame(height: 20)
        }
    }

    private func markView(_ mark: TodayTapeMark, color: Color, width: CGFloat) -> some View {
        let markWidth: CGFloat = mark.isDot ? 10 : max(8, width * CGFloat((mark.end ?? mark.start) - mark.start))
        let isPicked = shown?.id == mark.id
        let isHovered = hoveredMarkID == mark.id
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { pickedMarkID = mark.id }
        } label: {
            Capsule()
                .fill(color)
                .frame(width: markWidth, height: isPicked ? 14 : 12)
                .opacity(isPicked || isHovered ? 1 : 0.42)
                .overlay(
                    Capsule()
                        .stroke(color, lineWidth: 1.5)
                        .padding(-3.5)
                        .opacity(isPicked ? 1 : 0)
                )
                .frame(height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .offset(x: min(width * CGFloat(mark.start), max(0, width - markWidth)))
        .zIndex(isPicked ? 2 : (isHovered ? 1 : 0))
        .onHover { hovering in
            if hovering {
                hoveredMarkID = mark.id
            } else if hoveredMarkID == mark.id {
                hoveredMarkID = nil
            }
        }
        .help(TodayTapeBuilder.markDescription(mark, now: now))
        .accessibilityLabel(TodayTapeBuilder.markDescription(mark, now: now))
        .accessibilityHint("Shows it below the timeline")
        .accessibilityAddTraits(isPicked ? .isSelected : [])
        .accessibilityIdentifier("transcripted.today.tape.mark")
    }

    private func preview(_ mark: TodayTapeMark) -> some View {
        let item = mark.item
        let marks = day.allMarks
        let index = marks.firstIndex { $0.id == mark.id }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.kind.systemImage)
                .font(.system(size: 13))
                .foregroundStyle(item.kind.streamColor)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(TodayPreviewCopy.meta(for: item, now: now))
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.ink3)
                        .lineLimit(1)
                }
                if let body = TodayPreviewCopy.body(for: item) {
                    Text(body)
                        .font(.system(size: 12.5))
                        .foregroundStyle(LibraryTokens.ink2)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                arrowButton("chevron.left", label: "Previous") {
                    if let index, index > 0 { pickedMarkID = marks[index - 1].id }
                }
                .disabled(index == nil || index == 0)
                .accessibilityIdentifier("transcripted.today.preview.prev")
                arrowButton("chevron.right", label: "Next") {
                    if let index, index + 1 < marks.count { pickedMarkID = marks[index + 1].id }
                }
                .disabled(index == nil || index == marks.count - 1)
                .accessibilityIdentifier("transcripted.today.preview.next")
                arrowButton("arrow.up.right", label: "Open") { onOpen(item) }
                    .accessibilityIdentifier("transcripted.today.preview.open")
            }
            .padding(.top, -2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.contentBackground)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.today.preview")
    }
}

/// A small borderless arrow for the preview card.
private func arrowButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
    TodayArrowButton(systemImage: systemImage, label: label, action: action)
}

private struct TodayArrowButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isEnabled ? (isHovering ? Color.primary : LibraryTokens.ink2) : LibraryTokens.ink3.opacity(0.5))
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                        .fill(isHovering && isEnabled ? LibraryTokens.rowHover : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Meta line and body for the preview card.
private enum TodayPreviewCopy {
    static func meta(for item: TodayRecentItem, now: Date) -> String {
        var parts: [String] = []
        switch item.kind {
        case .meeting:
            parts.append("Meeting")
            parts.append(TodayCopy.rowWhen(for: item.date, now: now))
            if let duration = TodayCopy.rowDuration(seconds: item.durationSeconds) { parts.append(duration) }
        case .dictation:
            parts.append(item.appName ?? "Dictation")
            parts.append(TodayCopy.rowWhen(for: item.date, now: now))
            if let words = item.words { parts.append(TodayCopy.words(words)) }
        case .writing:
            parts.append(item.appName ?? "Writing")
            parts.append(TodayCopy.rowWhen(for: item.date, now: now))
            if let words = item.words {
                let accepted = item.acceptedWords ?? 0
                parts.append(TodayCopy.words(words) + (accepted > 0 ? ", \(accepted) from Tab" : ""))
            }
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func body(for item: TodayRecentItem) -> String? {
        guard let preview = item.preview else { return nil }
        let collapsed = preview.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
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
                    miniLane(day.writing, color: LibraryTokens.writingStream)
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 7)
            .padding(.top, 7)
            .padding(.bottom, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? LibraryTokens.raisedFill : (isHovering ? LibraryTokens.rowHover : Color.clear))
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
        .accessibilityLabel("\(TodayCopy.dateLine(for: day.day)): \(TodayCopy.count(day.meetings.count, singular: "meeting", plural: "meetings")), \(TodayCopy.count(day.dictations.count, singular: "dictation", plural: "dictations")), \(TodayCopy.count(day.writing.count, singular: "writing entry", plural: "writing entries"))")
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
                Image(systemName: item.kind.systemImage)
                    .font(.system(size: 12))
                    .foregroundStyle(item.kind.streamColor)
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
        .help(helpText)
        .accessibilityIdentifier("transcripted.today.recent.row")
    }

    private var helpText: String {
        switch item.kind {
        case .meeting: return "Open in Meetings"
        case .dictation: return "Open in Dictations"
        case .writing: return "Open the day's writing file"
        }
    }

    private var meta: String {
        let when = TodayCopy.rowWhen(for: item.date, now: now)
        switch item.kind {
        case .writing:
            let app = item.appName.map { "\($0) \u{00B7} " } ?? ""
            return "\(app)\(when)"
        case .meeting, .dictation:
            guard let duration = TodayCopy.rowDuration(seconds: item.durationSeconds) else { return when }
            return "\(duration) \u{00B7} \(when)"
        }
    }
}
