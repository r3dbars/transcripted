import SwiftUI
import TranscriptedCore

// Meetings cards (2026-11): the Dictations card with a title.
//
// The bar on top carries play, the bold title, "9:00 AM · 32 min · You,
// Priya", and Copy / ⋯ on hover. Under it, one amber line for anything that
// needs a hand (no call audio, a muffled mic, voices to name), then the first
// four transcript lines in italics as "Name text". Show more opens the whole
// transcript in place, where speaker names can be fixed and "Who spoke?"
// opens this meeting's card on Speakers to name every voice at once. Hovering a line shows its time; clicking
// the time plays the kept audio from there. Rows never follow the playhead.

// MARK: - Card surface

/// The raised card every Meetings row uses: saved, failed and in-progress.
private struct HomeMeetingCardSurface: ViewModifier {
    let isHovering: Bool

    func body(content: Content) -> some View {
        content
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 12, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                    .fill(LibraryTokens.raisedFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                    .stroke(isHovering ? DesignTokens.hairlineStrong : LibraryTokens.raisedStroke, lineWidth: 1)
            )
            .padding(.vertical, 4)
    }
}

extension View {
    func homeMeetingCardSurface(isHovering: Bool = false) -> some View {
        modifier(HomeMeetingCardSurface(isHovering: isHovering))
    }
}

/// Each row action as a named VoiceOver action on the card, including the
/// ones the pointer reaches by hover, Option, or the issue line.
struct HomeMeetingMenuAccessibilityActions: ViewModifier {
    let items: [HomeRowMenuItem]

    func body(content: Content) -> some View {
        items.filter(\.isEnabled).reduce(AnyView(content)) { view, item in
            AnyView(view.accessibilityAction(named: Text(item.title), item.action))
        }
    }
}

// MARK: - Snippets

/// First lines per saved meeting, read off the main thread once and kept
/// while the file is unchanged. Nothing here leaves the Mac or gets logged.
@MainActor
enum HomeMeetingCardSnippetCache {
    private struct Entry {
        let stamp: Date?
        let snippet: HomeMeetingCardSnippet
    }

    private static var entries: [String: Entry] = [:]
    private static let capacity = 400

    static func cached(id: String) -> HomeMeetingCardSnippet? {
        entries[id]?.snippet
    }

    static func load(_ item: RecentMeetingItem) async -> HomeMeetingCardSnippet? {
        let url = item.transcriptURL
        let known = entries[item.id]
        let knownStamp = known?.stamp
        let hasKnown = known != nil
        let result = await Task.detached(priority: .utility) { () -> (Date?, HomeMeetingCardSnippet?) in
            // Follow transcripts renamed since scanning.
            let resolved = OwnFileResolver.resolveExistingFile(candidateURLs: [url]) ?? url
            let stamp = (try? resolved.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if hasKnown, let stamp, stamp == knownStamp { return (stamp, nil) }
            guard let markdown = try? String(contentsOf: resolved, encoding: .utf8) else { return (stamp, nil) }
            return (stamp, HomeMeetingCardPresentation.snippet(from: HomeMeetingPreviewContent.make(from: markdown)))
        }.value
        guard let snippet = result.1 else { return known?.snippet }
        if entries.count >= capacity, entries[item.id] == nil {
            entries.removeAll(keepingCapacity: true)
        }
        entries[item.id] = Entry(stamp: result.0, snippet: snippet)
        return snippet
    }
}

// MARK: - Card

struct QuietMeetingCard: View {
    let item: RecentMeetingItem
    let isExpanded: Bool
    /// The full transcript, once an opened card has read it.
    let preview: HomeMeetingPreview?
    let isCopied: Bool
    let menuItems: [HomeRowMenuItem]
    var showsMicBoostHint: Bool = false
    /// Voices this meeting still has to name: the amber "2 to name", which
    /// opens its "Who spoke?" card on Speakers.
    var voicesToName: Int = 0
    let knownPeople: [SpeakerNameChoice]
    let savedSpeakerIDs: Set<UUID>
    let onToggleExpanded: () -> Void
    let onCollapse: () -> Void
    let onCopy: () -> Void
    let onWhoSpoke: () -> Void
    let onAssignSpeakers: ([HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snippet: HomeMeetingCardSnippet?
    @State private var isHovering = false
    @State private var showsAllLines = false

    private var snippetTaskID: String {
        // A rename, a speaker fix or a rescan changes one of these, so the
        // card rereads its lines (the cache skips unchanged files).
        [item.id, item.title, item.speakerNames.joined(separator: "|"), item.transcriptionEngine ?? ""]
            .joined(separator: "\u{1F}")
    }

    private var openedContent: HomeMeetingPreviewContent? {
        guard isExpanded, let preview, preview.readError == nil else { return nil }
        return preview.content
    }

    private var participants: [String] {
        if let openedContent {
            return HomeMeetingCardPresentation.snippet(from: openedContent).participants
        }
        return snippet?.participants ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            bar

            if hasIssues {
                issueLine
                    .padding(.top, 6)
            }

            transcript
                .padding(.top, 8)

            footer
        }
        .homeMeetingCardSurface(isHovering: isHovering)
        // Swallow taps inside the card so the page's click-away collapse
        // doesn't fire for clicks on the card's own quiet areas.
        .onTapGesture {}
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
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
        .task(id: snippetTaskID) {
            if snippet == nil {
                snippet = HomeMeetingCardSnippetCache.cached(id: item.id)
            }
            if let loaded = await HomeMeetingCardSnippetCache.load(item) {
                snippet = loaded
            }
        }
        .onChange(of: isExpanded) { _, expanded in
            if !expanded { showsAllLines = false }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: Text("Copy"), onCopy)
        .modifier(HomeMeetingMenuAccessibilityActions(items: menuItems))
        .accessibilityIdentifier(isExpanded ? "transcripted.home.expansion" : "transcripted.home.meeting.card")
    }

    // MARK: Bar

    private var bar: some View {
        HStack(spacing: 10) {
            if let audio = item.audio {
                HomeMeetingPlayButton(audio: audio)
            }

            Button(action: onToggleExpanded) {
                Text(item.displayTitle)
                    .font(TextRole.body.font(weight: .semibold))
                    .foregroundStyle(LibraryTokens.ink)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Show less" : "Show more")
            .layoutPriority(2)
            .accessibilityIdentifier(isExpanded ? "transcripted.home.expansion.title" : "transcripted.home.meeting.preview")

            if item.isStarred {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(LibraryTokens.ink3)
                    .help("Keeps its audio")
                    .accessibilityLabel("Keeps its audio")
                    .accessibilityIdentifier("transcripted.home.meeting.starred")
            }

            HomeMeetingBarMeta(
                audio: item.audio,
                time: HomeActivityRowFormatting.timeFormatter.string(from: item.startDate ?? item.date),
                duration: HomeMeetingCardPresentation.durationText(start: item.startDate, end: item.endDate),
                people: HomeMeetingCardPresentation.participantsText(participants)
            )

            Spacer(minLength: 8)

            HomeRowActionButtons(
                isCopied: isCopied,
                onCopy: onCopy,
                menuItems: menuItems
            )
            .frame(height: 22)
            // Hidden from the pointer until hover, never from VoiceOver.
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
        }
        .frame(minHeight: 22)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsActions)
    }

    private var showsActions: Bool { isHovering || isExpanded }

    // MARK: Issue line

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

    // MARK: Transcript

    @ViewBuilder
    private var transcript: some View {
        if isExpanded, let preview, let readError = preview.readError {
            Text(readError)
                .font(LibraryTokens.body)
                .foregroundStyle(LibraryTokens.attention)
        } else if let openedContent {
            openedTranscript(openedContent)
        } else if let snippet {
            closedTranscript(snippet)
        } else {
            // One quiet line while the file is read, so cards don't jump.
            Text(" ")
                .font(TextRole.body.font())
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private func closedTranscript(_ snippet: HomeMeetingCardSnippet) -> some View {
        if let fallback = snippet.fallbackText {
            Text(fallback)
                .font(TextRole.body.font().italic())
                .foregroundStyle(LibraryTokens.ink2)
                .lineSpacing(4)
                .lineLimit(HomeMeetingCardPresentation.closedLineLimit)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(snippet.lines.enumerated()), id: \.offset) { index, line in
                    HomeMeetingCardLine(
                        line: line,
                        index: index,
                        audio: item.audio,
                        isOpened: false,
                        knownPeople: knownPeople,
                        isSavedPerson: false,
                        onAssign: { _, completion in completion(false) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func openedTranscript(_ content: HomeMeetingPreviewContent) -> some View {
        if content.transcriptLines.isEmpty {
            Text(content.fallbackText)
                .font(TextRole.body.font().italic())
                .foregroundStyle(LibraryTokens.ink2)
                .lineSpacing(4)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let lines = content.transcriptLines
            let shown = showsAllLines ? lines.count : min(lines.count, HomeMeetingCardPresentation.openedLineLimit)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<shown, id: \.self) { index in
                    let line = lines[index]
                    HomeMeetingCardLine(
                        line: line,
                        index: index,
                        audio: item.audio,
                        isOpened: true,
                        knownPeople: knownPeople,
                        isSavedPerson: line.identity.persistentSpeakerID.map(savedSpeakerIDs.contains) ?? false,
                        onAssign: { assignment, completion in
                            onAssignSpeakers([assignment], completion)
                        }
                    )
                }
            }
        }
    }

    // MARK: Footer

    private var canShowMore: Bool {
        guard let snippet else { return false }
        return HomeMeetingCardPresentation.hasMore(snippet)
    }

    @ViewBuilder
    private var footer: some View {
        let showAllTitle = openedContent.flatMap {
            showsAllLines ? nil : HomeMeetingCardPresentation.showAllTitle(totalLineCount: $0.transcriptLines.count)
        }
        let offersWhoSpoke = !(openedContent?.transcriptLines.isEmpty ?? true)
        if isExpanded || canShowMore {
            HStack(spacing: 14) {
                if isExpanded, preview == nil {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Loading\u{2026}")
                    }
                    .foregroundStyle(LibraryTokens.ink3)
                } else if let showAllTitle {
                    footerButton(showAllTitle, identifier: "transcripted.home.expansion.show-all") {
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { showsAllLines = true }
                    }
                }
                footerButton(
                    isExpanded ? "Show less" : "Show more",
                    chevron: isExpanded ? "chevron.up" : "chevron.down",
                    identifier: "transcripted.home.meeting.show-more",
                    action: onToggleExpanded
                )
                if offersWhoSpoke {
                    footerButton("Who spoke?", identifier: "transcripted.home.expansion.name-speakers", action: onWhoSpoke)
                    .help("Name every voice in this meeting")
                }
            }
            .font(TextRole.small.font())
            .padding(.top, 6)
        }
    }

    private func footerButton(
        _ title: String,
        chevron: String? = nil,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(title)
                if let chevron {
                    Image(systemName: chevron)
                        .font(.system(size: 8.5, weight: .semibold))
                }
            }
            .foregroundStyle(LibraryTokens.ink3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Bar meta

/// "9:00 AM · 32 min · You, Priya". While this meeting's audio is open the
/// player slides in first and the length steps aside, like Dictations.
private struct HomeMeetingBarMeta: View {
    let audio: MeetingAudioAttachment?
    let time: String
    let duration: String?
    let people: String?

    @ObservedObject private var playback = MeetingAudioPlayback.shared

    private var isOpen: Bool {
        audio.map { playback.isActive($0) } ?? false
    }

    private var items: [String] {
        [time, isOpen ? nil : duration, people].compactMap { $0 }
    }

    var body: some View {
        HStack(spacing: 7) {
            if let audio, isOpen {
                HomeMeetingInlinePlayer(audio: audio)
                metaDot
            }
            ForEach(Array(items.enumerated()), id: \.offset) { index, text in
                if index > 0 { metaDot }
                Text(text)
                    .foregroundStyle(text == duration ? LibraryTokens.ink2 : LibraryTokens.ink3)
                    .truncationMode(.tail)
                    .layoutPriority(text == people ? 0 : 1)
            }
        }
        .font(LibraryTokens.meta)
        .monospacedDigit()
        .lineLimit(1)
        .animation(.easeOut(duration: 0.15), value: isOpen)
    }

    private var metaDot: some View {
        Circle()
            .fill(LibraryTokens.ink3)
            .frame(width: 2.5, height: 2.5)
            .accessibilityHidden(true)
    }
}

// MARK: - Transcript line

/// One "Name text" line. Hovering shows the line's time at its end; clicking
/// it plays the kept audio from there. The time sits in a slot the line
/// always leaves free, so hovering never rewraps the text or moves the card.
/// An opened card makes the name a button that fixes who it is.
private struct HomeMeetingCardLine: View {
    let line: HomeMeetingTranscriptLine
    let index: Int
    let audio: MeetingAudioAttachment?
    let isOpened: Bool
    let knownPeople: [SpeakerNameChoice]
    let isSavedPerson: Bool
    let onAssign: (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void

    @State private var isHovering = false

    /// Room for "1:02:03" at the small size.
    static let timeSlotWidth: CGFloat = 46

    private var playableStart: TimeInterval? {
        guard audio != nil, !line.time.isEmpty else { return nil }
        return line.startSeconds
    }

    private var clock: String? {
        playableStart.map(MeetingAudioPlayback.clockText)
    }

    var body: some View {
        // Top, not baseline: the opened card's name is a button, which
        // doesn't report a text baseline. Name and text share one font size,
        // so their first lines still sit on the same baseline.
        HStack(alignment: .top, spacing: 6) {
            if !line.speaker.isEmpty {
                speaker
            }
            Text(line.text)
                .font(TextRole.body.font().italic())
                .foregroundStyle(LibraryTokens.ink2)
                .lineSpacing(3)
                .lineLimit(isOpened ? nil : HomeMeetingCardPresentation.closedLineWrapLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .modifier(SelectableWhen(isOn: isOpened))
            if let clock, let start = playableStart {
                HomeMeetingLineTime(clock: clock, index: index) { play(from: start) }
                    .frame(width: Self.timeSlotWidth, alignment: .trailing)
                    // Small text, nudged down to the body's first baseline.
                    .padding(.top, 2)
                    .opacity(isHovering ? 1 : 0)
                    .allowsHitTesting(isHovering)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) { isHovering = hovering }
        }
        .modifier(LinePlayAccessibilityAction(clock: clock) {
            if let start = playableStart { play(from: start) }
        })
    }

    @ViewBuilder
    private var speaker: some View {
        if isOpened {
            QuietMeetingSpeakerLabel(
                identity: line.identity,
                knownPeople: knownPeople,
                isSavedPerson: isSavedPerson,
                columnWidth: nil,
                onAssign: onAssign
            )
        } else {
            Text(line.speaker)
                .font(TextRole.body.font(weight: .semibold))
                .foregroundStyle(speakerColor)
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var speakerColor: Color {
        line.speaker == "You" ? LibraryTokens.ink : HomeMeetingSpeakerColor.color(for: line.identity)
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

/// A transcript line's time, shown on hover. Clicking it plays from there.
private struct HomeMeetingLineTime: View {
    let clock: String
    let index: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(clock)
                .font(TextRole.small.font())
                .monospacedDigit()
                .foregroundStyle(isHovering ? LibraryTokens.ink : LibraryTokens.ink3)
                .underline(isHovering)
                .fixedSize()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Play from \(clock)")
        .accessibilityLabel(Text("Play from \(clock)"))
        .accessibilityIdentifier("transcripted.home.expansion.timestamp.\(index)")
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

private struct SelectableWhen: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.textSelection(.enabled)
        } else {
            content
        }
    }
}
