import SwiftUI
import TranscriptedCore

// Unified expandable, auto-following transcript for an opened Meetings card
// (owner-approved 2026-11-27): sits directly below the milled playback bar as a
// compact scrollable transcript window (up to ~156 pt, sizing naturally to
// shorter content) with an "Expand transcript" button at the bottom that
// smoothly grows the same scrollable view (up to ~420 pt).
//
// While audio plays (or while scrubbing the rail), the active spoken line is
// highlighted with a vertical VoicePrint bar and the scroll view smoothly
// follows along. Manual scrolling pauses auto-follow briefly so the reader can
// freely scroll up and down without getting yanked back; scrubbing, jumping to
// a timestamp, or resuming playback resumes following right away.

struct HomeMeetingTranscriptReveal: View {
    let item: RecentMeetingItem
    /// The read transcript, or nil while it loads (or when the read failed).
    let content: HomeMeetingPreviewContent?
    /// Pre-parsed line start times, cached once per preview on the parent card.
    let timed: HomeMeetingTimedLines
    let isLoading: Bool
    /// False = compact scrollable viewport (up to 156 pt); true = tall expanded viewport (up to 420 pt).
    let isShown: Bool
    let showsAllLines: Bool
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    /// Live active line index while scrubbing the rail above, or nil when not scrubbing.
    var scrubActiveLineIndex: Int? = nil
    let onToggle: () -> Void
    let onShowAll: () -> Void
    let onAssignSpeakers: ([HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpandHovered = false
    /// Measured intrinsic content height so short transcripts never leave blank space.
    @State private var measuredContentHeight: CGFloat = 0
    /// Pauses auto-follow for a few seconds after the reader manually scrolls.
    @State private var manualScrollPauseUntil: Date = .distantPast

    private typealias P = HomeMeetingCardPresentation

    private static let compactMaxHeight: CGFloat = 156
    private static let expandedMaxHeight: CGFloat = 420
    private static let manualScrollGraceSeconds: TimeInterval = 6

    private var isAudioActiveHere: Bool {
        guard let audio = item.audio else { return false }
        return playback.isActive(audio)
    }

    private var isPlayingHere: Bool {
        isAudioActiveHere && playback.isPlaying
    }

    private var activeLineIndex: Int? {
        if let scrubActiveLineIndex { return scrubActiveLineIndex }
        guard isAudioActiveHere else { return nil }
        return timed.activeIndex(at: playback.currentTime)
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
                    let cap = isShown ? Self.expandedMaxHeight : Self.compactMaxHeight
                    let needsExpand = measuredContentHeight > Self.compactMaxHeight + 8
                    ScrollView {
                        Text(text)
                            .font(LibraryTokens.body)
                            .foregroundStyle(LibraryTokens.ink)
                            .lineSpacing(3)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 4)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                                measuredContentHeight = height
                            }
                    }
                    .frame(height: measuredContentHeight > 0 ? min(measuredContentHeight, cap) : nil)
                    .frame(maxHeight: cap)
                    if needsExpand {
                        expandFooter(lineCount: nil)
                    }
                }
            } else {
                let all = content.transcriptLines
                // Computed ONCE per render before ForEach (never inside the loop).
                let active = activeLineIndex
                let cap = isShown ? Self.expandedMaxHeight : Self.compactMaxHeight
                let estimatedHeight = CGFloat(all.count) * 30
                let effectiveContentHeight = measuredContentHeight > 0 ? measuredContentHeight : estimatedHeight
                let needsExpand = effectiveContentHeight > Self.compactMaxHeight + 8
                let viewportHeight = min(effectiveContentHeight, cap)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(all.indices, id: \.self) { index in
                                let line = all[index]
                                HomeMeetingTranscriptLineRow(
                                    line: line,
                                    index: index,
                                    audio: item.audio,
                                    isActive: index == active,
                                    knownPeople: knownPeople,
                                    isSavedPerson: line.identity.persistentSpeakerID.map(savedSpeakerIDs.contains) ?? false,
                                    onPlayRequested: {
                                        manualScrollPauseUntil = .distantPast
                                    },
                                    onAssign: { assignment, completion in
                                        onAssignSpeakers([assignment], completion)
                                    }
                                )
                                .id(index)
                            }
                        }
                        .padding(.vertical, 4)
                        .padding(.trailing, 4)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                            if height > 0 { measuredContentHeight = height }
                        }
                    }
                    .frame(height: viewportHeight)
                    .onScrollPhaseChange { _, newPhase in
                        if newPhase == .interacting || newPhase == .decelerating {
                            manualScrollPauseUntil = Date().addingTimeInterval(Self.manualScrollGraceSeconds)
                        }
                    }
                    .overlay(alignment: .bottom) {
                        if needsExpand && !isShown {
                            LinearGradient(
                                colors: [Color.clear, HomeMeetingCardSurface.liftedFill.opacity(0.92)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(height: 24)
                            .allowsHitTesting(false)
                        }
                    }
                    .onChange(of: active) { _, newIndex in
                        guard let newIndex else { return }
                        if scrubActiveLineIndex != nil {
                            manualScrollPauseUntil = .distantPast
                            scroll(proxy, to: newIndex, immediate: true)
                        } else if isPlayingHere, Date() >= manualScrollPauseUntil {
                            scroll(proxy, to: newIndex, immediate: false)
                        }
                    }
                    .onChange(of: isPlayingHere) { _, playing in
                        guard playing, let current = active else { return }
                        manualScrollPauseUntil = .distantPast
                        scroll(proxy, to: current, immediate: false)
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

    private func scroll(_ proxy: ScrollViewProxy, to index: Int, immediate: Bool) {
        if reduceMotion || immediate {
            proxy.scrollTo(index, anchor: .center)
        } else {
            withAnimation(.easeOut(duration: 0.26)) {
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

private struct HomeMeetingTranscriptLineRow: View {
    let line: HomeMeetingTranscriptLine
    let index: Int
    let audio: MeetingAudioAttachment?
    let isActive: Bool
    let knownPeople: [SpeakerNameChoice]
    let isSavedPerson: Bool
    let onPlayRequested: () -> Void
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
        onPlayRequested()
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
