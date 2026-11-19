import SwiftUI
import TranscriptedCore

// The opened Meetings card's last row: "Transcript" with a chevron and
// "214 lines" on the right. It is closed every time the card opens
// (`MeetingsPageOpenState`), so the lines are only laid out once asked for.
// Revealed, each line is the speaker's name in bold, then the words, upright
// and always selectable. Hovering a line shows "▶ 0:42" at its end and
// clicking that plays the kept audio from there; rows never follow the
// playhead. The name is still the one-voice fix (`QuietMeetingSpeakerLabel`).
// After 60 lines, "Show all N lines".

struct HomeMeetingTranscriptReveal: View {
    let item: RecentMeetingItem
    /// The read transcript, or nil while it loads (or when the read failed).
    let content: HomeMeetingPreviewContent?
    let isLoading: Bool
    let isShown: Bool
    let showsAllLines: Bool
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    let onToggle: () -> Void
    let onShowAll: () -> Void
    let onAssignSpeakers: ([HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private typealias P = HomeMeetingCardPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            revealRow
            if isShown {
                lines
                    .padding(.bottom, 12)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: isShown)
    }

    private var revealRow: some View {
        Button {
            onToggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8.5, weight: .semibold))
                    .rotationEffect(.degrees(isShown ? 90 : 0))
                    .frame(width: 10)
                Text(P.revealTitle(isShown: isShown))
                Spacer(minLength: 8)
                if let count = P.lineCountText(content?.transcriptLines.count) {
                    Text(count)
                        .monospacedDigit()
                        .foregroundStyle(LibraryTokens.ink3)
                } else if isLoading {
                    ProgressView().controlSize(.mini)
                }
            }
            .font(LibraryTokens.meta)
            .foregroundStyle(isHovering ? LibraryTokens.ink : LibraryTokens.ink2)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(DesignTokens.hairlineStrong)
                .frame(height: 1)
        }
        .padding(.top, 10)
        // Looks like the mockup's reveal row; reads as a disclosure.
        .accessibilityRepresentation {
            DisclosureGroup(isExpanded: Binding(get: { isShown }, set: { if $0 != isShown { onToggle() } })) {
                EmptyView()
            } label: {
                Text(revealAccessibilityLabel)
            }
        }
        .accessibilityIdentifier("transcripted.home.meeting.show-more")
    }

    /// "Transcript, 214 lines".
    private var revealAccessibilityLabel: String {
        ["Transcript", P.lineCountText(content?.transcriptLines.count)].compactMap { $0 }.joined(separator: ", ")
    }

    @ViewBuilder
    private var lines: some View {
        if let content {
            if content.transcriptLines.isEmpty {
                // Old or hand-edited transcripts with no speaker lines.
                Text(content.fallbackText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                let all = content.transcriptLines
                let shown = P.shownLineCount(total: all.count, showsAll: showsAllLines)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(0..<shown, id: \.self) { index in
                        let line = all[index]
                        HomeMeetingTranscriptLineRow(
                            line: line,
                            index: index,
                            audio: item.audio,
                            knownPeople: knownPeople,
                            isSavedPerson: line.identity.persistentSpeakerID.map(savedSpeakerIDs.contains) ?? false,
                            onAssign: { assignment, completion in
                                onAssignSpeakers([assignment], completion)
                            }
                        )
                    }
                    if let showAll = showsAllLines ? nil : P.showAllTitle(totalLineCount: all.count) {
                        Button(showAll, action: onShowAll)
                            .buttonStyle(.plain)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                            .padding(.top, 8)
                            .accessibilityIdentifier("transcripted.home.expansion.show-all")
                    }
                }
            }
        } else if isLoading {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Loading\u{2026}")
            }
            .font(LibraryTokens.meta)
            .foregroundStyle(LibraryTokens.ink3)
        }
    }
}

// MARK: - Transcript line

/// One "Name words" line. The words are always selectable. With kept audio,
/// hovering shows "▶ 0:42" at the end, in a slot the line always leaves
/// free so hovering never rewraps the text, and only that plays from there.
private struct HomeMeetingTranscriptLineRow: View {
    let line: HomeMeetingTranscriptLine
    let index: Int
    let audio: MeetingAudioAttachment?
    let knownPeople: [SpeakerNameChoice]
    let isSavedPerson: Bool
    let onAssign: (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void

    @State private var isHovering = false

    /// The name column and the "▶ 1:02:03" slot.
    static let nameColumnWidth: CGFloat = 64
    static let timeSlotWidth: CGFloat = 52

    private var playableStart: TimeInterval? {
        guard audio != nil, !line.time.isEmpty else { return nil }
        return line.startSeconds
    }

    private var clock: String? {
        playableStart.map(MeetingAudioPlayback.clockText)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
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
                .foregroundStyle(LibraryTokens.ink)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            if let clock, let start = playableStart {
                Button {
                    play(from: start)
                } label: {
                    Text("\u{25B6}\u{FE0E} \(clock)")
                        .font(TextRole.small.font())
                        .monospacedDigit()
                        .foregroundStyle(LibraryTokens.ink3)
                        .frame(width: Self.timeSlotWidth, alignment: .trailing)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, 2)
                .opacity(isHovering ? 1 : 0)
                .allowsHitTesting(isHovering)
                .help("Play from \(clock)")
                // The line's own action says the same for VoiceOver.
                .accessibilityHidden(true)
                .accessibilityIdentifier("transcripted.home.expansion.timestamp.\(index)")
            }
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .fill(isHovering && playableStart != nil ? DesignTokens.fillStrong : Color.clear)
        )
        .padding(.horizontal, -6)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovering = hovering }
        }
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

    /// Retained-audio file stem that holds a channel's speech.
    private static func retainedAudioStem(for channel: HomeMeetingSpeakerChannel) -> String {
        switch channel {
        case .mic: return "microphone"
        case .system: return "system_audio"
        }
    }
}

/// VoiceOver can play from a line without hovering it.
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
