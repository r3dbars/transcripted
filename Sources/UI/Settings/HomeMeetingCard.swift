import SwiftUI
import TranscriptedCore

// The Meetings page row (2026-11-18, owner-approved "minimal" mockup).
//
// Closed, a row is only: a small round play button (when audio was kept),
// the title, one summary under it, and the start time on the right. No card,
// no borders, no actions; whitespace separates rows. Clicking anywhere but
// play opens it in place as a quiet card: filled play, the title, "2:00 PM ·
// 48 min · You, Priya", Copy and ⋯ on the right, a thin scrubber, the
// meeting's short summary, the amber line when something needs a hand, and a
// "Transcript" reveal that is closed every time the card opens. Closed rows
// never read the transcript; the opened card's one background read happens in
// `TranscriptedSettingsView.toggleHomeMeetingExpansion`. Rules and words:
// `HomeMeetingCardPresentation`.

// MARK: - Layout

enum HomeMeetingRowLayout {
    /// The play column.
    static let playColumn: CGFloat = HomeMeetingPlayButton.size
    /// Between the play column, the text and the time.
    static let columnGap: CGFloat = 14
    /// Above and below a closed row's text.
    static let rowPadding: CGFloat = 11
    /// The opened card reaches this far past the list column on each side,
    /// so its text stays where the closed row's was.
    static let cardInset: CGFloat = 16
    /// The opened card's body lines up under the title.
    static var bodyIndent: CGFloat { playColumn + columnGap }
}

/// A row that can open into a quiet card in place: no surface while closed,
/// the card fill at 12 pt radius while open, reaching `cardInset` past the
/// list column so the text never moves.
private struct HomeMeetingRowSurface: ViewModifier {
    let isOpen: Bool

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, HomeMeetingRowLayout.cardInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                    .fill(isOpen ? LibraryTokens.raisedFill : Color.clear)
            )
            .padding(.horizontal, -HomeMeetingRowLayout.cardInset)
            .padding(.vertical, isOpen ? 6 : 0)
    }
}

extension View {
    func homeMeetingRowSurface(isOpen: Bool) -> some View {
        modifier(HomeMeetingRowSurface(isOpen: isOpen))
    }

    /// Return opens a focused row, like Space does for any button.
    func homeMeetingRowKeys(_ action: @escaping () -> Void) -> some View {
        onKeyPress(.return) {
            action()
            return .handled
        }
    }
}

/// Each row action as a named VoiceOver action on the row, including the
/// ones the pointer reaches only once the row is open, by Option, or from
/// the amber line.
struct HomeMeetingMenuAccessibilityActions: ViewModifier {
    let items: [HomeRowMenuItem]

    func body(content: Content) -> some View {
        items.filter(\.isEnabled).reduce(AnyView(content)) { view, item in
            AnyView(view.accessibilityAction(named: Text(item.title), item.action))
        }
    }
}

/// The text under a row's title: a summary, the fallback line, or the amber
/// or working wording with its quiet action.
struct HomeMeetingSlotText: View {
    let slot: HomeMeetingCardPresentation.Slot
    var onAction: (() -> Void)? = nil
    var actionIsDisabled = false
    var actionHelp: String? = nil
    var actionIdentifier: String? = nil
    var showsSpinner = true

    var body: some View {
        switch slot {
        case .summary(let text), .fallback(let text):
            Text(text)
                .font(LibraryTokens.body)
                .foregroundStyle(LibraryTokens.ink2)
                .lineLimit(HomeMeetingCardPresentation.summaryLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .working(let text, let percent):
            HStack(spacing: 6) {
                if showsSpinner {
                    ProgressView().controlSize(.mini)
                }
                Text(text)
                    .foregroundStyle(LibraryTokens.ink2)
                if let percent {
                    Text("\(percent)%")
                        .monospacedDigit()
                        .foregroundStyle(LibraryTokens.ink3)
                }
            }
            .font(LibraryTokens.body)
            .lineLimit(1)
        case .problem(let text, let actionTitle):
            HStack(spacing: 10) {
                Text(text)
                    .foregroundStyle(LibraryTokens.attention)
                    .lineLimit(1)
                if let actionTitle, let onAction {
                    Button(actionTitle, action: onAction)
                        .buttonStyle(.transcriptedQuiet)
                        .controlSize(.small)
                        .disabled(actionIsDisabled)
                        .help(actionHelp ?? "")
                        .homeAutomationIdentifier(actionIdentifier)
                }
            }
            .font(LibraryTokens.body)
        case .empty:
            EmptyView()
        }
    }
}

// MARK: - Saved meeting row

struct QuietMeetingCard: View {
    let item: RecentMeetingItem
    /// The day header above it ("Today"), for its VoiceOver label.
    var dayHeader: String = ""
    let isExpanded: Bool
    /// The full transcript, once an opened card has read it.
    let preview: HomeMeetingPreview?
    let isCopied: Bool
    let menuItems: [HomeRowMenuItem]
    var showsMicBoostHint: Bool = false
    /// Voices this meeting still has to name: the amber "2 to name", which
    /// opens its "Who spoke?" card on Speakers.
    var voicesToName: Int = 0
    var isTranscriptShown: Bool = false
    var showsAllLines: Bool = false
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    let onToggleExpanded: () -> Void
    let onCollapse: () -> Void
    let onCopy: () -> Void
    let onWhoSpoke: () -> Void
    var onToggleTranscript: () -> Void = {}
    var onShowAllLines: () -> Void = {}
    let onAssignSpeakers: ([HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    private typealias P = HomeMeetingCardPresentation
    private typealias Layout = HomeMeetingRowLayout

    private var people: [String] {
        P.people(speakerNames: item.speakerNames, isImported: item.importedAt != nil)
    }

    private var timeText: String {
        HomeActivityRowFormatting.timeFormatter.string(from: item.startDate ?? item.date)
    }

    private var slot: P.Slot {
        P.savedSlot(summaryLine: item.summaryLine, start: item.startDate, end: item.endDate, people: people)
    }

    private var accessibilityLabel: String {
        P.accessibilityLabel(
            title: item.displayTitle,
            dayHeader: dayHeader.isEmpty ? P.dayHeader(for: item.listDate) : dayHeader,
            time: timeText,
            start: item.startDate,
            end: item.endDate
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isExpanded {
                openedHeader
                openedBody
                    .transition(.opacity)
            } else {
                closedRow
            }
        }
        .homeMeetingRowSurface(isOpen: isExpanded)
        // Swallow taps inside the row so the page's click-away collapse
        // doesn't fire for clicks on the card's own quiet areas.
        .onTapGesture {}
        .background {
            if isExpanded {
                // Hidden control so Esc collapses the opened card.
                Button(action: onCollapse) { EmptyView() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isExpanded)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copy"), onCopy)
        .modifier(HomeMeetingMenuAccessibilityActions(items: menuItems))
        .accessibilityIdentifier(isExpanded ? "transcripted.home.expansion" : "transcripted.home.meeting.card")
    }

    // MARK: Closed

    private var closedRow: some View {
        Button(action: onToggleExpanded) {
            HStack(alignment: .center, spacing: Layout.columnGap) {
                Color.clear.frame(width: Layout.playColumn, height: Layout.playColumn)
                HStack(alignment: .firstTextBaseline, spacing: Layout.columnGap) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle)
                            .font(TextRole.body.font(weight: .semibold))
                            .foregroundStyle(LibraryTokens.ink)
                            .underline(isHovering, color: LibraryTokens.ink3)
                            .lineLimit(1)
                            .accessibilityIdentifier("transcripted.home.meeting.preview")
                        HomeMeetingSlotText(slot: slot)
                    }
                    Spacer(minLength: 8)
                    Text(timeText)
                        .font(LibraryTokens.meta)
                        .monospacedDigit()
                        .foregroundStyle(LibraryTokens.ink3)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, Layout.rowPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .homeMeetingRowKeys(onToggleExpanded)
        .accessibilityLabel(Text(accessibilityLabel))
        .accessibilityValue(Text(slotSpokenText))
        .accessibilityHint(Text("Opens the meeting"))
        .overlay(alignment: .leading) {
            if let audio = item.audio {
                HomeMeetingPlayButton(audio: audio)
            }
        }
    }

    private var slotSpokenText: String {
        switch slot {
        case .summary(let text), .fallback(let text): return text
        case .working(let text, _), .problem(let text, _): return text
        case .empty: return ""
        }
    }

    // MARK: Opened

    private var openedHeader: some View {
        HStack(alignment: .top, spacing: Layout.columnGap) {
            Button(action: onToggleExpanded) {
                HStack(alignment: .top, spacing: Layout.columnGap) {
                    Color.clear.frame(width: Layout.playColumn, height: Layout.playColumn)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.displayTitle)
                            .textRole(.heading)
                            .foregroundStyle(LibraryTokens.ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("transcripted.home.expansion.title")
                        Text(P.openedSubtitle(time: timeText, start: item.startDate, end: item.endDate, people: people))
                            .font(LibraryTokens.meta)
                            .monospacedDigit()
                            .foregroundStyle(LibraryTokens.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
            .homeMeetingRowKeys(onToggleExpanded)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityHint(Text("Closes the meeting"))
            .overlay(alignment: .topLeading) {
                if let audio = item.audio {
                    HomeMeetingPlayButton(audio: audio, look: .filled)
                }
            }

            HStack(spacing: 2) {
                Button(isCopied ? "Copied" : "Copy", action: onCopy)
                    .buttonStyle(.transcriptedQuiet)
                    .controlSize(.small)
                    .accessibilityIdentifier("transcripted.home.row.copy")
                HomeRowMoreMenuButton(items: menuItems)
                    .frame(width: 28, height: 24)
                    .help("More options")
            }
            .padding(.top, -2)
        }
        .padding(.top, 16)
    }

    private var openedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let audio = item.audio {
                HomeMeetingScrubber(
                    audio: audio,
                    fallbackDuration: P.durationSeconds(start: item.startDate, end: item.endDate)
                )
                .padding(.top, 12)
                .padding(.bottom, 16)
            } else {
                Spacer().frame(height: 14)
            }

            if let summary = item.summary {
                Text(summary)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(.bottom, 12)
            }

            if hasIssues {
                issueLine
                    .padding(.bottom, 8)
            }

            if let preview, let readError = preview.readError {
                Text(readError)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.attention)
                    .padding(.bottom, 8)
            }

            HomeMeetingTranscriptReveal(
                item: item,
                content: openedContent,
                isLoading: preview == nil,
                isShown: isTranscriptShown,
                showsAllLines: showsAllLines,
                knownPeople: knownPeople,
                savedSpeakerIDs: savedSpeakerIDs,
                onToggle: onToggleTranscript,
                onShowAll: onShowAllLines,
                onAssignSpeakers: onAssignSpeakers
            )
        }
        .padding(.leading, Layout.bodyIndent)
        .padding(.top, 2)
    }

    private var openedContent: HomeMeetingPreviewContent? {
        guard let preview, preview.readError == nil else { return nil }
        return preview.content
    }

    // MARK: Amber line

    private var boostMicItem: HomeRowMenuItem? {
        menuItems.first { $0.placement == .issueLine }
    }

    private var whoSpokeTitle: String? {
        SpeakerMeetingReviewPolicy.rowPill(voicesToName: voicesToName)
    }

    private var hasIssues: Bool {
        item.systemAudioVerificationWarning != nil
            || (showsMicBoostHint && boostMicItem != nil)
            || whoSpokeTitle != nil
    }

    private var issueLine: some View {
        HStack(spacing: 6) {
            if let warning = item.systemAudioVerificationWarning {
                Text(warning)
                    .help("Didn't hear anyone else on the call. They may have been quiet, or call audio wasn't recorded.")
                    .accessibilityIdentifier("transcripted.home.meeting.system-audio-unverified")
            }
            if showsMicBoostHint, let boostMicItem {
                if item.systemAudioVerificationWarning != nil { issueDot }
                Button(action: boostMicItem.action) {
                    Text("Mic was muffled")
                        .underline(pattern: .dot)
                }
                .buttonStyle(.plain)
                .help("Another call app muffled your mic. Click to boost it next meeting.")
                .accessibilityLabel("Mic was muffled. Boost mic next meeting")
                .accessibilityIdentifier("transcripted.home.meeting.boost-mic")
            }
            if let whoSpokeTitle {
                if item.systemAudioVerificationWarning != nil || (showsMicBoostHint && boostMicItem != nil) { issueDot }
                Button(action: onWhoSpoke) {
                    Text(whoSpokeTitle)
                        .monospacedDigit()
                        .underline(pattern: .dot)
                }
                .buttonStyle(.plain)
                .help("Name who spoke in this meeting")
                .accessibilityLabel("Who spoke? \(whoSpokeTitle)")
                .accessibilityIdentifier("transcripted.home.meeting.who-spoke")
            }
        }
        .font(LibraryTokens.meta)
        .foregroundStyle(LibraryTokens.attention)
        .lineLimit(1)
    }

    private var issueDot: some View {
        Text("\u{00B7}")
            .foregroundStyle(LibraryTokens.ink3)
            .accessibilityHidden(true)
    }
}
