import SwiftUI
import TranscriptedCore

// The opened Meetings card's last row: "Transcript" with a chevron and
// "214 lines" on the right. It is closed every time the card opens
// (`MeetingsPageOpenState`), so the lines are only laid out once asked for.
// Revealed, each line is the speaker's name in bold, then the words, upright.
// Hovering a line shows "▶ 0:42" at its end and clicking it plays the kept
// audio from there; rows never follow the playhead. The name is still the
// one-voice fix (`QuietMeetingSpeakerLabel`). After 60 lines, "Show all N
// lines".

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
        .accessibilityLabel(Text("Transcript"))
        .accessibilityValue(Text(isShown ? "Expanded" : "Collapsed"))
        .accessibilityHint(Text(isShown ? "Hides the transcript" : "Shows the transcript"))
        .accessibilityIdentifier("transcripted.home.meeting.show-more")
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

/// One "Name words" line. With kept audio the whole line plays from its time
/// on click and shows "▶ 0:42" at its end on hover; the time sits in a slot
/// the line always leaves free, so hovering never rewraps the text. Without
/// audio the words are selectable instead.
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
            words
            if let clock {
                Text("\u{25B6}\u{FE0E} \(clock)")
                    .font(TextRole.small.font())
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink3)
                    .frame(width: Self.timeSlotWidth, alignment: .trailing)
                    .padding(.top, 2)
                    .opacity(isHovering ? 1 : 0)
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
        .onTapGesture {
            if let start = playableStart { play(from: start) }
        }
        .help(clock.map { "Play from \($0)" } ?? "")
        .modifier(LinePlayAccessibilityAction(clock: clock) {
            if let start = playableStart { play(from: start) }
        })
    }

    @ViewBuilder
    private var words: some View {
        let text = Text(line.text)
            .font(LibraryTokens.body)
            .foregroundStyle(LibraryTokens.ink)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        if playableStart == nil {
            text.textSelection(.enabled)
        } else {
            text
        }
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
