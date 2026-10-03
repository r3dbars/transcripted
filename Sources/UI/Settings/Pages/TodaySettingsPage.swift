import SwiftUI

/// The Today page: one sentence for the day, the week as a strip, the picked
/// day as three lanes (meetings, dictation, writing) with a preview of the
/// picked capture under them, then the day in sessions. Pure view assembly;
/// loading lives in `TodayViewModel`, numbers and copy in
/// `TodayPresentation.swift`, and every navigation or capture action is
/// injected by the settings shell.
struct TodaySettingsPage: View {
    @ObservedObject var todayViewModel: TodayViewModel
    let now: Date
    let onOpenRecentItem: (TodayRecentItem) -> Void
    let onShowMeetings: () -> Void
    let onShowDictations: () -> Void
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void
    let onStartDictation: () -> Void

    /// Shared by the week strip and the day card; nil means today.
    @State private var selectedDayID: TimeInterval?
    /// The mark the day card shows; a session click picks one too.
    @State private var pickedMarkID: String?
    @State private var openSessionID: String?

    private var snapshot: TodaySnapshot { todayViewModel.snapshot }
    private var stats: TodayContextStats { snapshot.stats }
    private var selectedDay: TodayTapeDay? {
        snapshot.tapeDays.first { $0.id == selectedDayID } ?? snapshot.tapeDays.last
    }

    /// The region settings the cards' copy depends on, beyond `now` and the
    /// data: a locale or time zone change re-renders on the next pass, as before.
    private var formatKey: String {
        Locale.current.identifier + "|" + TimeZone.current.identifier + "|" + "\(Calendar.current.identifier)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            header

            if todayViewModel.hasLoaded && !stats.hasAnyCapture && snapshot.recent.isEmpty {
                emptyState
            } else if let selectedDay {
                // Equatable: the shell publishes up to 20 times a second
                // during a capture, and the card only changes with its day,
                // the picked mark, the minute, or the region.
                TodayDayCard(
                    day: selectedDay,
                    now: now,
                    pickedMarkID: pickedMarkID,
                    onPick: { pickedMarkID = $0 },
                    onOpen: onOpenRecentItem,
                    formatKey: formatKey
                )
                .equatable()
                sessionsSection(selectedDay)
            } else if !todayViewModel.hasLoaded {
                Text("Loading…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
        }
        .onChange(of: selectedDay?.id) { _, _ in
            pickedMarkID = nil
            openSessionID = nil
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
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .bottom, spacing: 24) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(TodayCopy.dateLine(for: day?.day ?? now))
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                    Text(isToday ? "Today" : TodayCopy.weekdayLong(for: day?.day ?? now))
                        .font(LibraryTokens.title)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if !snapshot.tapeDays.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(snapshot.tapeDays) { day in
                            TodayWeekCell(day: day, isSelected: day.id == selectedDay?.id, formatKey: formatKey) {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    selectedDayID = day.isToday ? nil : day.id
                                }
                            }
                            .equatable()
                        }
                    }
                    .frame(width: 330)
                }
            }
            // Its own full-width line: next to the week strip it got clipped.
            TodaySentence(stats: headerStats, isToday: isToday)
        }
    }

    // MARK: Sessions

    /// The picked day in sessions, oldest first. Opening one picks its
    /// latest mark on the tape; picking a mark opens its session.
    private func sessionsSection(_ day: TodayTapeDay) -> some View {
        let sessions = day.sessions
        return VStack(spacing: 2) {
            ForEach(sessions) { session in
                TodaySessionRow(
                    session: session,
                    isOpen: openSessionID == session.id,
                    onToggle: {
                        withAnimation(.easeOut(duration: 0.15)) {
                            if openSessionID == session.id {
                                openSessionID = nil
                            } else {
                                openSessionID = session.id
                                pickedMarkID = session.items.last?.id
                            }
                        }
                    },
                    onOpen: onOpenRecentItem
                )
            }
        }
        .onChange(of: pickedMarkID) { _, picked in
            guard let picked, let owner = sessions.first(where: { $0.items.contains { $0.id == picked } }) else { return }
            withAnimation(.easeOut(duration: 0.15)) { openSessionID = owner.id }
        }
        .accessibilityIdentifier("transcripted.today.sessions")
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
private struct TodayDayCard: View, Equatable {
    let day: TodayTapeDay
    let now: Date
    /// Owned by the page so a session click can pick a mark; it clears it
    /// when the day changes.
    let pickedMarkID: String?
    let onPick: (String?) -> Void
    let onOpen: (TodayRecentItem) -> Void
    /// Locale, time zone and calendar, so a region change still re-renders.
    let formatKey: String

    @State private var hoveredMarkID: String?

    private static let laneLabelWidth: CGFloat = 84

    /// Closures and hover state stay out: hover is the card's own state and
    /// re-renders it by itself.
    nonisolated static func == (lhs: TodayDayCard, rhs: TodayDayCard) -> Bool {
        lhs.day == rhs.day
            && lhs.pickedMarkID == rhs.pickedMarkID
            && TodayCopy.minuteKey(lhs.now) == TodayCopy.minuteKey(rhs.now)
            && lhs.formatKey == rhs.formatKey
    }

    var body: some View {
        let marks = day.allMarks
        // What the preview shows: the hovered mark, else the picked one,
        // else the day's latest.
        let shown = marks.first { $0.id == hoveredMarkID }
            ?? marks.first { $0.id == pickedMarkID }
            ?? marks.max { $0.item.date < $1.item.date }
        let shownID = shown?.id
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
                lane("Meetings", kind: .meeting, marks: day.meetings, shownID: shownID)
                lane("Dictation", kind: .dictation, marks: day.dictations, shownID: shownID)
                lane("Writing", kind: .writing, marks: day.writing, shownID: shownID)
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
                    preview(shown, marks: marks)
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
        .accessibilityIdentifier("transcripted.today.day-tape")
    }

    private func lane(_ title: String, kind: TodayRecentItem.Kind, marks: [TodayTapeMark], shownID: String?) -> some View {
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
                        markView(mark, color: kind.streamColor, width: geo.size.width, shownID: shownID)
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

    private func markView(_ mark: TodayTapeMark, color: Color, width: CGFloat, shownID: String?) -> some View {
        let markWidth: CGFloat = mark.isDot ? 10 : max(8, width * CGFloat((mark.end ?? mark.start) - mark.start))
        let isPicked = shownID == mark.id
        let isHovered = hoveredMarkID == mark.id
        return Button {
            withAnimation(.easeOut(duration: 0.12)) { onPick(mark.id) }
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

    private func preview(_ mark: TodayTapeMark, marks: [TodayTapeMark]) -> some View {
        let item = mark.item
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
                    if let index, index > 0 { onPick(marks[index - 1].id) }
                }
                .disabled(index == nil || index == 0)
                .accessibilityIdentifier("transcripted.today.preview.prev")
                arrowButton("chevron.right", label: "Next") {
                    if let index, index + 1 < marks.count { onPick(marks[index + 1].id) }
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
@MainActor
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
private struct TodayWeekCell: View, Equatable {
    let day: TodayTapeDay
    let isSelected: Bool
    /// Locale, time zone and calendar, so a region change still re-renders.
    let formatKey: String
    let select: () -> Void

    @State private var isHovering = false

    /// The select closure stays out; it only sets the page's picked day.
    nonisolated static func == (lhs: TodayWeekCell, rhs: TodayWeekCell) -> Bool {
        lhs.day == rhs.day && lhs.isSelected == rhs.isSelected && lhs.formatKey == rhs.formatKey
    }

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

/// One session: start time, a rule-made title, and a dot per stream. Open,
/// it lists what's inside; clicking one of those opens it where it lives.
private struct TodaySessionRow: View {
    let session: TodaySession
    let isOpen: Bool
    let onToggle: () -> Void
    let onOpen: (TodayRecentItem) -> Void

    @State private var isHovering = false

    /// Fits "11:15 AM – 12:31 PM".
    private static let timeWidth: CGFloat = 124

    private var time: String { TodayCopy.sessionTime(start: session.start, end: session.end) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 14) {
                    Text(time)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink3)
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: Self.timeWidth, alignment: .leading)
                    Text(session.title)
                        .font(LibraryTokens.rowTitle)
                        .lineLimit(1)
                    Spacer(minLength: 12)
                    HStack(spacing: 4) {
                        ForEach(session.kinds, id: \.self) { kind in
                            Circle().fill(kind.streamColor).frame(width: 7, height: 7)
                        }
                    }
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .accessibilityLabel("\(session.title), \(time)")
            .accessibilityAddTraits(isOpen ? .isSelected : [])
            .accessibilityIdentifier("transcripted.today.session.row")

            if isOpen {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(session.items) { item in
                        TodaySessionItemRow(item: item) { onOpen(item) }
                    }
                }
                .padding(.leading, 10 + Self.timeWidth + 14 - 8)
                .padding(.trailing, 4)
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(isOpen ? LibraryTokens.raisedFill : (isHovering ? LibraryTokens.rowHover : Color.clear))
        )
    }
}

private struct TodaySessionItemRow: View {
    let item: TodayRecentItem
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle().fill(item.kind.streamColor).frame(width: 6, height: 6)
                Text(TodaySessionBuilder.line(for: item))
                    .font(.system(size: 12.5))
                    .foregroundStyle(isHovering ? Color.primary : LibraryTokens.ink2)
                    .lineLimit(1)
                Spacer(minLength: 12)
                if isHovering {
                    Text(TodayCopy.sessionTime(start: item.date, end: item.date))
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.ink3)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 8)
            .frame(minHeight: 26)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                    .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(helpText)
        .accessibilityIdentifier("transcripted.today.session.item")
    }

    private var helpText: String {
        switch item.kind {
        case .meeting: return "Open in Meetings"
        case .dictation: return "Open in Dictations"
        case .writing: return "Open the day's writing file"
        }
    }
}
