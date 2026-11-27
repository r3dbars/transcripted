import AppKit
import SwiftUI
import TranscriptedCore

// The Meetings card (owner-approved matte editorial mockup, 2026-11-27).
//
// Every saved meeting is a borderless matte card (12 pt continuous corners,
// 16 pt padding, 11 pt between cards; a whisper of shadow on light windows,
// no outline, no play gutter):
//   1. the title, with Play & open (kept audio only), Copy and ⋯ on hover
//      (always while open);
//   2. "2:00 – 2:42 PM · 42m · " and who was there, as small voice prints
//      (names for up to three people, a fanned stack past that), plus a
//      quiet "1 voice to name" that opens "Who spoke?" right on the card;
//   3. the summary as a paragraph, four lines closed, whole when open.
// Clicking the card opens it in place: the whole summary, the amber line
// when something needs a hand, the milled player with its mini transcript
// (`HomeMeetingInstrumentShell`), and "Full transcript", closed every time
// the card opens. Dragging a card drops its Markdown file anywhere (Finder,
// Slack, an editor). Closed cards never read the transcript; the opened
// card's one background read happens in
// `TranscriptedSettingsView.toggleHomeMeetingExpansion`. Rules and words:
// `HomeMeetingCardPresentation` and `HomeMeetingRailPresentation`.

// MARK: - Layout

enum HomeMeetingRowLayout {
    /// The play column of the failed and in-progress rows.
    static let playColumn: CGFloat = HomeMeetingPlayButton.size
    /// Between the play column, the text and the time.
    static let columnGap: CGFloat = 14
    /// Above and below a closed row's text.
    static let rowPadding: CGFloat = 11
    /// A card's inner padding.
    static let cardPadding: CGFloat = 16
    /// Between one card and the next.
    static let cardSpacing: CGFloat = 11
    static let cardRadius: CGFloat = 12
    /// The opened card's body lines up under the title.
    static var bodyIndent: CGFloat { playColumn + columnGap }
}

/// The matte card every Meetings row sits on: the card fill, lifted while
/// hovered or open, a whisper of shadow on light windows.
private struct HomeMeetingRowSurface: ViewModifier {
    let isOpen: Bool
    var isHovering = false
    var horizontalPadding: CGFloat = HomeMeetingRowLayout.cardPadding

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: HomeMeetingRowLayout.cardRadius, style: .continuous)
        content
            .padding(.horizontal, horizontalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                shape
                    .fill(isOpen || isHovering ? HomeMeetingCardSurface.liftedFill : HomeMeetingCardSurface.fill)
                    .shadow(color: isOpen ? HomeMeetingCardSurface.openShadow : HomeMeetingCardSurface.shadow,
                            radius: isOpen ? 14 : 1, y: isOpen ? 8 : 1)
            )
            .padding(.bottom, HomeMeetingRowLayout.cardSpacing)
    }
}

extension View {
    func homeMeetingRowSurface(isOpen: Bool, isHovering: Bool = false) -> some View {
        modifier(HomeMeetingRowSurface(isOpen: isOpen, isHovering: isHovering))
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

/// The text under a failed or in-progress row's title: the fallback line, or
/// the amber or working wording with its quiet action.
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

// MARK: - Saved meeting card

struct QuietMeetingCard: View {
    let item: RecentMeetingItem
    /// The day header above it ("Today"), for its VoiceOver label: the same
    /// text the section shows.
    var dayHeader: String = ""
    /// The page's calendar, locale, time zone and now.
    var clock: MeetingsPageClock = .current()
    let isExpanded: Bool
    /// The full transcript, once an opened card has read it.
    let preview: HomeMeetingPreview?
    let isCopied: Bool
    let menuItems: [HomeRowMenuItem]
    var showsMicBoostHint: Bool = false
    /// Voices this meeting still has to name: "2 voices to name", which opens
    /// its "Who spoke?" right on the card.
    var voicesToName: Int = 0
    var isTranscriptShown: Bool = false
    var showsAllLines: Bool = false
    /// False while the search field has keyboard focus, so Esc clears the
    /// search there instead of closing this card.
    var escapeClosesCard: Bool = true
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    let onToggleExpanded: () -> Void
    /// Esc: closes the card and stops playback.
    let onCollapse: () -> Void
    /// Click outside the card: folds the card without stopping playback.
    var onOutsideCollapse: (() -> Void)? = nil
    let onCopy: () -> Void
    /// "Who spoke?" on Speakers, when no review can be built here.
    let onWhoSpoke: () -> Void
    /// Builds the inline "Who spoke?" for this meeting; nil falls back to
    /// `onWhoSpoke`. The closure closes the popover once it saves or Later.
    var makeWhoSpokeSession: ((_ onClose: @escaping @MainActor () -> Void) -> HomeMeetingWhoSpokeSession?)? = nil
    var onToggleTranscript: () -> Void = {}
    var onShowAllLines: () -> Void = {}
    let onAssignSpeakers: ([HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var whoSpokeSession: HomeMeetingWhoSpokeSession?
    @State private var scrubActiveLineIndex: Int?
    @State private var cachedTimedLines: HomeMeetingTimedLines = .empty
    @State private var cachedTimedKey: String = ""

    private typealias P = HomeMeetingCardPresentation
    private typealias R = HomeMeetingRailPresentation
    private typealias Layout = HomeMeetingRowLayout

    private var people: [HomeMeetingPerson] {
        HomeMeetingPerson.resolve(
            P.people(speakerNames: item.speakerNames, micVoices: item.micVoices, isImported: item.importedAt != nil),
            knownPeople: knownPeople
        )
    }

    private var timeText: String {
        P.timeText(for: item.startDate ?? item.date, clock: clock)
    }

    private var summaryText: String? {
        R.summaryParagraph(summary: item.summary, summaryLine: item.summaryLine)
    }

    private var accessibilityLabel: String {
        P.accessibilityLabel(
            title: item.displayTitle,
            dayHeader: dayHeader.isEmpty ? P.dayHeader(for: item.listDate, clock: clock) : dayHeader,
            time: timeText,
            start: item.startDate,
            end: item.endDate
        )
    }

    private var spokenSummary: String {
        summaryText ?? P.fallbackLine(start: item.startDate, end: item.endDate, people: people.map(\.name)) ?? ""
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if isExpanded {
                openedBody
                    .transition(.opacity)
            }
        }
        .background {
            if isExpanded {
                // Attached INSIDE the card's own bounds (before bottom cardSpacing)
                // so clicks in the 11 pt gap below the card collapse it too.
                HomeMeetingOutsideClickMonitor(
                    isActive: isExpanded && whoSpokeSession == nil,
                    onOutsideClick: onOutsideCollapse ?? onCollapse
                )
                Button(action: onCollapse) { EmptyView() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .disabled(!escapeClosesCard)
                    .opacity(0)
                    .accessibilityHidden(true)
            }
        }
        .modifier(HomeMeetingRowSurface(isOpen: isExpanded, isHovering: isHovering, horizontalPadding: 0))
        .onHover { isHovering = $0 }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded {
                scrubActiveLineIndex = nil
            } else {
                refreshCachedTimedLines()
            }
        }
        .onChange(of: timedCacheKey) { _, _ in
            refreshCachedTimedLines()
        }
        .onAppear {
            if isExpanded { refreshCachedTimedLines() }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isExpanded)
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copy"), onCopy)
        .modifier(HomeMeetingMenuAccessibilityActions(items: menuItems))
        .accessibilityIdentifier(isExpanded ? "transcripted.home.expansion" : "transcripted.home.meeting.card")
    }

    // MARK: Header (rows 1-3)

    /// The three rows. One button sits behind them, so the closed card and
    /// the opened header are the same keyboard stop and a click anywhere on
    /// the words opens or closes the card; the people stack, "voices to
    /// name" and the actions are their own controls in front of it.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleRow
            peopleRow
                .padding(.top, 5)
            if !isExpanded, let summaryText {
                Text(summaryText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink2)
                    .lineSpacing(4)
                    .lineLimit(R.closedSummaryLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("transcripted.home.meeting.summary")
            }
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.top, Layout.cardPadding)
        .padding(.bottom, isExpanded ? 0 : Layout.cardPadding)
        .background {
            Button(action: onToggleExpanded) {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Close" : "")
            .homeMeetingRowKeys(onToggleExpanded)
            .accessibilityLabel(Text(accessibilityLabel))
            .accessibilityValue(Text(isExpanded ? "" : spokenSummary))
            .accessibilityHint(Text(isExpanded ? "Closes the meeting" : "Opens the meeting"))
            .accessibilityIdentifier("transcripted.home.meeting.preview")
        }
        // Click and hold, then drag: the meeting's own Markdown file.
        .onDrag {
            NSItemProvider(contentsOf: item.transcriptURL) ?? NSItemProvider(object: item.transcriptURL as NSURL)
        }
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(item.displayTitle)
                .font(.system(size: 15, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(LibraryTokens.ink)
                .lineLimit(isExpanded ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .allowsHitTesting(false)
                .accessibilityIdentifier(isExpanded ? "transcripted.home.expansion.title" : "transcripted.home.meeting.title")
            Spacer(minLength: 8)
            actions
                .opacity(isHovering || isExpanded ? 1 : 0)
                .allowsHitTesting(isHovering || isExpanded)
        }
        .frame(minHeight: 27)
    }

    private var actions: some View {
        HStack(spacing: 3) {
            if !isExpanded, let audio = item.audio {
                HomeCardPlayAndOpenButton(audio: audio) {
                    onToggleExpanded()
                }
            }
            HomeCardIconButton(
                systemName: isCopied ? "checkmark" : "doc.on.doc",
                help: isCopied ? "Copied" : "Copy transcript",
                automationIdentifier: "transcripted.home.row.copy",
                action: onCopy
            )
            HomeRowMoreMenuButton(items: menuItems)
                .frame(width: 27, height: 27)
                .help("More options")
        }
    }

    private var peopleRow: some View {
        let range = R.timeRangeParts(start: item.startDate ?? item.date, end: item.endDate, clock: clock)
        return HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 6) {
                Text(range.range)
                    .fontWeight(.medium)
                    .foregroundStyle(LibraryTokens.ink2)
                if let length = range.length {
                    Text(length)
                        .foregroundStyle(LibraryTokens.ink3)
                }
            }
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .allowsHitTesting(false)
            if !people.isEmpty {
                separator
                HomeMeetingPeopleView(people: people, cardIsLifted: isHovering || isExpanded)
            }
            if voicesToName > 0 {
                HomeMeetingVoicesToNameButton(count: voicesToName, action: openWhoSpoke)
                    .popover(item: $whoSpokeSession, arrowEdge: .bottom) { session in
                        HomeMeetingWhoSpokePopoverContent(session: session)
                    }
            }
            Spacer(minLength: 0)
        }
        .font(LibraryTokens.meta)
    }

    private var separator: some View {
        Text("\u{00B7}")
            .foregroundStyle(LibraryTokens.ink3.opacity(0.6))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private func openWhoSpoke() {
        let binding = $whoSpokeSession
        if let session = makeWhoSpokeSession?({ binding.wrappedValue = nil }) {
            whoSpokeSession = session
        } else {
            onWhoSpoke()
        }
    }

    // MARK: Opened

    private var openedBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let summaryText {
                Text(summaryText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 620, alignment: .leading)
                    .padding(.top, 10)
                    .accessibilityIdentifier("transcripted.home.meeting.summary")
            }

            if hasIssues {
                issueLine
                    .padding(.top, 10)
            }

            if let audio = item.audio {
                HomeMeetingInstrumentShell(
                    audio: audio,
                    fallbackDuration: P.durationSeconds(start: item.startDate, end: item.endDate),
                    timed: activeTimedLines,
                    scrubActiveLineIndex: $scrubActiveLineIndex
                )
                .padding(.top, 13)
            }

            if let preview, let readError = preview.readError {
                Text(readError)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.attention)
                    .padding(.top, 10)
            }

            HomeMeetingTranscriptReveal(
                item: item,
                content: openedContent,
                timed: activeTimedLines,
                isLoading: preview == nil,
                isShown: isTranscriptShown,
                showsAllLines: showsAllLines,
                knownPeople: knownPeople,
                savedSpeakerIDs: savedSpeakerIDs,
                scrubActiveLineIndex: scrubActiveLineIndex,
                onToggle: onToggleTranscript,
                onShowAll: onShowAllLines,
                onAssignSpeakers: onAssignSpeakers
            )
        }
        .padding(.horizontal, Layout.cardPadding)
        .padding(.bottom, 6)
    }

    private var openedContent: HomeMeetingPreviewContent? {
        guard let preview, preview.readError == nil else { return nil }
        return preview.content
    }

    private var timedCacheKey: String {
        guard let preview, preview.readError == nil else { return "" }
        return "\(preview.id)#\(preview.content.transcriptLines.count)#\(preview.markdown.count)#\(preview.markdown.hashValue)"
    }

    private var activeTimedLines: HomeMeetingTimedLines {
        if cachedTimedKey == timedCacheKey {
            return cachedTimedLines
        }
        return openedContent.map { HomeMeetingTimedLines($0.transcriptLines) } ?? .empty
    }

    private func refreshCachedTimedLines() {
        let key = timedCacheKey
        guard key != cachedTimedKey else { return }
        cachedTimedKey = key
        cachedTimedLines = openedContent.map { HomeMeetingTimedLines($0.transcriptLines) } ?? .empty
    }

    // MARK: Amber line

    private var boostMicItem: HomeRowMenuItem? {
        menuItems.first { $0.placement == .issueLine }
    }

    private var hasIssues: Bool {
        item.systemAudioVerificationWarning != nil || (showsMicBoostHint && boostMicItem != nil)
    }

    private var issueLine: some View {
        HStack(spacing: 6) {
            if let warning = item.systemAudioVerificationWarning {
                Text(warning)
                    .help("Didn't hear anyone else on the call. They may have been quiet, or call audio wasn't recorded.")
                    .accessibilityIdentifier("transcripted.home.meeting.system-audio-unverified")
            }
            if showsMicBoostHint, let boostMicItem {
                if item.systemAudioVerificationWarning != nil {
                    Text("\u{00B7}")
                        .foregroundStyle(LibraryTokens.ink3)
                        .accessibilityHidden(true)
                }
                Button(action: boostMicItem.action) {
                    Text("Mic was muffled")
                        .underline(pattern: .dot)
                }
                .buttonStyle(.plain)
                .help("Another call app muffled your mic. Click to boost it next meeting.")
                .accessibilityLabel("Mic was muffled. Boost mic next meeting")
                .accessibilityIdentifier("transcripted.home.meeting.boost-mic")
            }
        }
        .font(LibraryTokens.meta)
        .foregroundStyle(LibraryTokens.attention)
        .lineLimit(1)
    }
}

// MARK: - Card actions

/// A card action: a 27 pt glyph with a hover fill.
struct HomeCardIconButton: View {
    let systemName: String
    let help: String
    let automationIdentifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isHovering ? LibraryTokens.ink : LibraryTokens.ink2)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 27, height: 27)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isHovering ? DesignTokens.fillStrong : Color.clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier(automationIdentifier)
    }
}

/// Play on a closed card: opens the card and starts its audio on the
/// card's player. Pause while that meeting is playing.
private struct HomeCardPlayAndOpenButton: View {
    let audio: MeetingAudioAttachment
    let onOpen: () -> Void

    @ObservedObject private var playback = MeetingAudioPlayback.shared

    private var isPlaying: Bool { playback.isActive(audio) && playback.isPlaying }

    var body: some View {
        HomeCardIconButton(
            systemName: isPlaying ? "pause.fill" : "play.fill",
            help: isPlaying ? "Pause" : "Play & open",
            automationIdentifier: "transcripted.home.meeting.play"
        ) {
            if isPlaying {
                playback.pause()
                return
            }
            onOpen()
            let choice = playback.activeChoice(for: audio) ?? playback.preferredChoice(for: audio)
            if playback.isActive(audio), playback.isPaused {
                playback.resume()
            } else {
                playback.play(audio, choice: choice)
            }
        }
    }
}
