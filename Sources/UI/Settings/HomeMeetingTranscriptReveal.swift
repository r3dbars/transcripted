import SwiftUI
import TranscriptedCore

// Unified expandable, auto-following transcript for an opened Meetings card
// (owner-approved 2026-11-27): sits directly below the milled playback bar as a
// compact scrollable transcript window (~156 pt) with an "Expand transcript"
// button at the bottom that smoothly grows the same scrollable view (~420 pt)
// to read and scroll through the entire meeting.
//
// While audio plays (or while scrubbing the rail), the active spoken line is
// highlighted with a vertical VoicePrint bar and the scroll view smoothly
// follows along whenever the spoken line advances. Clicking any line's
// timestamp plays from there, and clicking a speaker name opens the inline
// one-voice fix (`QuietMeetingSpeakerLabel`).

struct HomeMeetingTranscriptReveal: View {
    let item: RecentMeetingItem
    /// The read transcript, or nil while it loads (or when the read failed).
    let content: HomeMeetingPreviewContent?
    let isLoading: Bool
    /// False = compact scrollable viewport (~156 pt); true = tall expanded viewport (~420 pt).
    let isShown: Bool
    let showsAllLines: Bool
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    /// Live drag time while scrubbing the rail above, or nil when not scrubbing.
    var scrubTime: TimeInterval? = nil
    let onToggle: () -> Void
    let onShowAll: () -> Void
    let onAssignSpeakers: ([HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpandHovered = false

    private typealias P = HomeMeetingCardPresentation

    private static let compactHeight: CGFloat = 156
    private static let expandedHeight: CGFloat = 420
    private static let compactLineThreshold = 4

    private var isAudioActiveHere: Bool {
        guard let audio = item.audio else { return false }
        return playback.isActive(audio)
    }

    private var isPlayingHere: Bool {
        isAudioActiveHere && playback.isPlaying
    }

    private var followTime: TimeInterval? {
        if let scrubTime { return scrubTime }
        guard isAudioActiveHere else { return nil }
        return playback.currentTime
    }

    private var timedLines: HomeMeetingTimedLines {
        content.map { HomeMeetingTimedLines($0.transcriptLines) } ?? .empty
    }

    private var activeLineIndex: Int? {
        guard let followTime else { return nil }
        return timedLines.activeIndex(at: followTime)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle()
                .fill(LibraryTokens.hairline)
                .frame(height: 1)
                .padding(.top, 12)

            transcriptBody
                .padding(.top, 8)
        }
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.88), value: isShown)
    }

    @ViewBuilder
    private var transcriptBody: some View {
        if let content {
            if content.transcriptLines.isEmpty {
                let text = content.fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    ScrollView {
                        Text(text)
                            .font(LibraryTokens.body)
                            .foregroundStyle(LibraryTokens.ink)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                    }
                    .frame(maxHeight: isShown ? Self.expandedHeight : Self.compactHeight)
                    expandFooter(lineCount: nil)
                }
            } else {
                let all = content.transcriptLines
                let needsExpand = all.count > Self.compactLineThreshold
                let targetHeight: CGFloat? = needsExpand
                    ? (isShown ? Self.expandedHeight : Self.compactHeight)
                    : nil

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(all.indices, id: \.self) { index in
                                let line = all[index]
                                let isActiveLine = index == activeLineIndex
                                HomeMeetingTranscriptLineRow(
                                    line: line,
                                    index: index,
                                    audio: item.audio,
                                    isActive: isActiveLine,
                                    knownPeople: knownPeople,
                                    isSavedPerson: line.identity.persistentSpeakerID.map(savedSpeakerIDs.contains) ?? false,
                                    onAssign: { assignment, completion in
                                        onAssignSpeakers([assignment], completion)
                                    }
                                )
                                .id(index)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                    }
                    .frame(height: targetHeight)
                    .overlay(alignment: .bottom) {
                        if needsExpand && !isShown {
                            LinearGradient(
                                colors: [Color.clear, HomeMeetingCardSurface.liftedFill.opacity(0.92)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 26)
                            .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: activeLineIndex) { _, newIndex in
                        guard let newIndex, isPlayingHere || scrubTime != nil else { return }
                        scroll(proxy, to: newIndex)
                    }
                    .onChange(of: isPlayingHere) { _, playing in
                        guard playing, let current = activeLineIndex else { return }
                        scroll(proxy, to: current)
                    }
                }

                if needsExpand {
                    expandFooter(lineCount: all.count)
                }
            }
        } else if isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading transcript\u{2026}")
            }
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.ink3)
            .padding(.vertical, 10)
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int) {
        if reduceMotion || scrubTime != nil {
            proxy.scrollTo(index, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.28)) {
                proxy.scrollTo(index, anchor: .center)
            }
        }
    }

    private func expandFooter(lineCount: Int?) -> some View {
        let countText = P.lineCountText(lineCount)
        return Button(action: onToggle) {
            HStack(spacing: 6) {
                Image(systemName: isShown ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                Text(isShown ? "Show less" : "Expand transcript")
                    .fontWeight(.medium)
                if let countText {
                    Text("\u{00B7}")
                        .foregroundStyle(LibraryTokens.ink3)
                    Text(countText)
                        .monospacedDigit()
                        .foregroundStyle(LibraryTokens.ink3)
                }
            }
            .font(LibraryTokens.meta)
            .foregroundStyle(isExpandHovered ? LibraryTokens.ink : LibraryTokens.ink2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isExpandHovered ? DesignTokens.fill : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isExpandHovered = $0 }
        .padding(.top, 4)
        .accessibilityLabel(Text(isShown ? "Collapse transcript" : "Expand transcript"))
        .accessibilityIdentifier("transcripted.home.meeting.show-more")
    }
}

// MARK: - Transcript line

/// One speaker + text + timestamp line inside the unified transcript view.
/// Highlights cleanly with the speaker's VoicePrint accent bar when active,
/// supports inline speaker renaming, text selection, and clicking to play from
/// that line's timestamp.
private struct HomeMeetingTranscriptLineRow: View {
    let line: HomeMeetingTranscriptLine
    let index: Int
    let audio: MeetingAudioAttachment?
    let isActive: Bool
    let knownPeople: [SpeakerNameChoice]
    let isSavedPerson: Bool
    let onAssign: (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void

    @State private var isHovering = false

    static let nameColumnWidth: CGFloat = 68
    static let timeSlotWidth: CGFloat = 52

    private var playableStart: TimeInterval? {
        guard audio != nil, !line.time.isEmpty else { return nil }
        return line.startSeconds
    }

    private var clock: String? {
        playableStart.map(MeetingAudioPlayback.clockText)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(HomeMeetingRailInk.accent(for: line))
                .frame(width: 2, height: 15)
                .padding(.top, 2)
                .opacity(isActive ? 1 : 0)

            if !line.speaker.isEmpty {
                QuietMeetingSpeakerLabel(
                    identity: line.identity,
                    knownPeople: knownPeople,
                    isSavedPerson: isSavedPerson,
                    columnWidth: Self.nameColumnWidth,
                    showsChevronAtRest: false,
                    onAssign: onAssign
                )
            }

            Text(line.text)
                .font(LibraryTokens.body)
                .foregroundStyle(isActive ? LibraryTokens.ink : LibraryTokens.ink.opacity(0.86))
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)

            if let clock, let start = playableStart {
                Button {
                    play(from: start)
                } label: {
                    Text(isHovering ? "\u{25B6}\u{FE0E} \(clock)" : clock)
                        .font(TextRole.small.font())
                        .monospacedDigit()
                        .foregroundStyle(isActive ? HomeMeetingRailInk.accent(for: line) : LibraryTokens.ink3)
                        .frame(width: Self.timeSlotWidth, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .opacity(isHovering || isActive ? 1 : 0)
                .allowsHitTesting(isHovering || isActive)
                .help("Play from \(clock)")
                .accessibilityHidden(true)
                .accessibilityIdentifier("transcripted.home.expansion.timestamp.\(index)")
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .fill(
                    isActive
                        ? DesignTokens.fillStrong
                        : (isHovering && playableStart != nil ? DesignTokens.fill : Color.clear)
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .modifier(LinePlayAccessibilityAction(clock: clock) {
            if let start = playableStart { play(from: start) }
        })
    }

    private func play(from start: TimeInterval) {
        guard let audio else { return }
        MeetingAudioPlayback.shared.play(
            audio,
            from: start,
            rowSourceStem: line.identity.channel.map(Self.retainedAudioStem(for:))
        )
    }

    private static func retainedAudioStem(for channel: HomeMeetingSpeakerChannel) -> String {
        switch channel {
        case .mic: return "microphone"
        case .system: return "system_audio"
        }
    }
}

private struct LinePlayAccessibilityAction: ViewModifier {
    let clock: String?
    let action: () -> Void

    func body(content: Content) -> some View {
        if let clock {
            content.accessibilityAction(named: Text("Play from \(clock)"), action)
        } else {
            content
        }
    }
}
