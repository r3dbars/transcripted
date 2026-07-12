import AppKit
import SwiftUI
import TranscriptedCore

// Meeting preview sheet extracted from HomeView.swift (audit 2026-07-08 wave 2).
// Pure code motion: the sheet and its exclusively-owned private helper views.

struct HomeMeetingPreviewSheet: View {
    let preview: HomeMeetingPreview
    let onOpenMarkdown: () -> Void
    let onCopyForAgent: () -> Void
    let onReportIssue: () -> Void
    let onRenameTitle: (String) -> Void
    let onDone: () -> Void
    private let readableContent: HomeMeetingPreviewContent

    @State private var isEditingTitle = false
    @State private var draftTitle = ""
    @FocusState private var isTitleFieldFocused: Bool
    @State private var findQuery = ""
    @State private var currentMatchIndex = 0
    @FocusState private var isFindFieldFocused: Bool

    /// Lines the in-transcript find searches: the parsed transcript lines, or
    /// the raw fallback text when no structured lines were parsed.
    private var searchableLines: [String] {
        readableContent.transcriptLines.isEmpty
            ? [readableContent.fallbackText]
            : readableContent.transcriptLines.map(\.text)
    }

    private var findMatches: [TranscriptFindMatch] {
        TranscriptFinder.matches(in: searchableLines, query: findQuery)
    }

    /// The match the user is currently parked on, clamped into range.
    private var activeMatch: TranscriptFindMatch? {
        let matches = findMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(currentMatchIndex, matches.count - 1)]
    }

    init(
        preview: HomeMeetingPreview,
        onOpenMarkdown: @escaping () -> Void,
        onCopyForAgent: @escaping () -> Void,
        onReportIssue: @escaping () -> Void,
        onRenameTitle: @escaping (String) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.preview = preview
        self.onOpenMarkdown = onOpenMarkdown
        self.onCopyForAgent = onCopyForAgent
        self.onReportIssue = onReportIssue
        self.onRenameTitle = onRenameTitle
        self.onDone = onDone
        self.readableContent = HomeMeetingPreviewContent.make(from: preview.markdown)
    }

    var body: some View {
        // Compute matches once per render and thread them down so per-line
        // highlighting stays O(lines) instead of re-scanning for every line.
        let matches = findMatches
        let active: TranscriptFindMatch? = matches.isEmpty
            ? nil
            : matches[min(currentMatchIndex, matches.count - 1)]

        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    titleView
                    Text(HomeMeetingPreviewSheet.dateFormatter.string(from: preview.date))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                SettingsInlineActionButton(title: "Done", tone: .accent, action: onDone)
                    .keyboardShortcut(.defaultAction)
            }

            if let audio = preview.audio {
                HomeMeetingPodcastPlayer(audio: audio)
            } else {
                Label("No retained audio", systemImage: "speaker.slash")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.secondary.opacity(0.08))
                    )
            }

            if preview.readError == nil {
                HomeTranscriptFindBar(
                    query: $findQuery,
                    isFocused: $isFindFieldFocused,
                    matchCount: matches.count,
                    currentIndex: currentMatchIndex,
                    onNext: { advanceMatch(by: 1) },
                    onPrevious: { advanceMatch(by: -1) }
                )
            }

            Group {
                if let readError = preview.readError {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Could not preview this meeting", systemImage: "exclamationmark.triangle")
                            .font(.headline)
                        Text(readError)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 280, alignment: .topLeading)
                } else {
                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 14) {
                            if let summary = preview.summary {
                                VStack(alignment: .leading, spacing: 12) {
                                    Label("AI summary", systemImage: "sparkles")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                        .textCase(.uppercase)
                                        .tracking(0.6)

                                    if summary.sections.isEmpty {
                                        Text(summary.summary)
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.primary)
                                            .lineSpacing(2)
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        ForEach(Array(summary.sections.enumerated()), id: \.offset) { _, section in
                                            VStack(alignment: .leading, spacing: 3) {
                                                Text(section.title)
                                                    .font(.system(size: 11, weight: .semibold))
                                                    .foregroundStyle(.secondary)
                                                Text(section.text)
                                                    .font(.system(size: 13))
                                                    .foregroundStyle(Color.primary)
                                                    .lineSpacing(2)
                                                    .textSelection(.enabled)
                                            }
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        }
                                    }

                                    Divider()
                                        .padding(.top, 4)
                                }
                                .accessibilityIdentifier("transcripted.home.meeting-preview.summary")
                            }

                            Text("Transcript")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.secondary)
                                .textCase(.uppercase)
                                .tracking(0.6)

                            if readableContent.transcriptLines.isEmpty {
                                Text(TranscriptFindHighlight.attributedText(
                                    for: readableContent.fallbackText,
                                    query: findQuery,
                                    activeRange: Self.activeRange(forLine: 0, active: active)
                                ))
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.primary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(Self.transcriptLineID(0))
                            } else {
                                LazyVStack(alignment: .leading, spacing: 10) {
                                    ForEach(Array(readableContent.transcriptLines.enumerated()), id: \.offset) { offset, line in
                                        HomeMeetingTranscriptLineView(
                                            line: line,
                                            highlightQuery: findQuery,
                                            activeRange: Self.activeRange(forLine: offset, active: active)
                                        )
                                        .id(Self.transcriptLineID(offset))
                                    }
                                }
                                .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                    }
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.primary.opacity(0.025))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                    )
                    .onChange(of: currentMatchIndex) { _, _ in
                        scrollToActiveMatch(using: proxy)
                    }
                    .onChange(of: findQuery) { _, _ in
                        currentMatchIndex = 0
                        scrollToActiveMatch(using: proxy)
                    }
                    }
                }
            }

            HStack {
                SettingsInlineActionButton(
                    title: "Open Markdown",
                    symbolName: "doc.text",
                    automationIdentifier: "transcripted.home.meeting-preview.open-markdown"
                ) {
                    onOpenMarkdown()
                }

                SettingsInlineActionButton(
                    title: "Copy for agent",
                    symbolName: "square.on.square",
                    automationIdentifier: "transcripted.home.meeting-preview.copy-for-agent"
                ) {
                    onCopyForAgent()
                }

                SettingsInlineActionButton(
                    title: "Report issue",
                    symbolName: "flag",
                    tone: .warning,
                    automationIdentifier: "transcripted.home.meeting-preview.report-issue"
                ) {
                    onReportIssue()
                }

                Spacer()
            }
        }
        .padding(24)
        .frame(width: 680, height: 620)
    }

    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("Meeting title", text: $draftTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 22, weight: .semibold))
                .focused($isTitleFieldFocused)
                .onSubmit { commitTitleEdit() }
                .onExitCommand { cancelTitleEdit() }
                .accessibilityIdentifier("transcripted.home.meeting-preview.title-field")
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(preview.title)
                    .font(.system(size: 22, weight: .semibold))
                    .lineLimit(2)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { beginTitleEdit() }
                    .help(HomeMeetingRenameAffordance.help)
                    .accessibilityIdentifier("transcripted.home.meeting-preview.title")

                Button(action: beginTitleEdit) {
                    Image(systemName: HomeMeetingRenameAffordance.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(SettingsHoverButtonStyle(
                    tone: .neutral,
                    cornerRadius: 7,
                    normalFill: Color.primary.opacity(0.035),
                    normalStroke: Color.primary.opacity(0.08)
                ))
                .help(HomeMeetingRenameAffordance.help)
                .accessibilityLabel(HomeMeetingRenameAffordance.title)
                .accessibilityIdentifier(HomeMeetingRenameAffordance.automationIdentifier)
            }
        }
    }

    // MARK: - In-transcript find

    static func transcriptLineID(_ offset: Int) -> String {
        "transcript-line-\(offset)"
    }

    /// The active match's range when it falls inside the given line; nil otherwise.
    private static func activeRange(forLine offset: Int, active: TranscriptFindMatch?) -> Range<Int>? {
        guard let active, active.lineIndex == offset else { return nil }
        return active.range
    }

    private func advanceMatch(by delta: Int) {
        let count = findMatches.count
        guard count > 0 else { return }
        currentMatchIndex = ((currentMatchIndex + delta) % count + count) % count
    }

    private func scrollToActiveMatch(using proxy: ScrollViewProxy) {
        guard let match = activeMatch else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(Self.transcriptLineID(match.lineIndex), anchor: .center)
        }
    }

    private func beginTitleEdit() {
        draftTitle = preview.title
        isEditingTitle = true
        isTitleFieldFocused = true
    }

    private func commitTitleEdit() {
        isEditingTitle = false
        isTitleFieldFocused = false
        let trimmed = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != preview.title else { return }
        onRenameTitle(trimmed)
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
        isTitleFieldFocused = false
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()
}

private struct HomeMeetingPodcastPlayer: View {
    let audio: MeetingAudioAttachment

    @ObservedObject private var playback = MeetingAudioPlayback.shared
    @State private var selectedPlaybackChoiceID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            ZStack {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Meeting audio")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .tracking(0.5)

                        Text(playback.compactTimeLabel(for: audio))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    MeetingAudioSourceMenu(
                        attachment: audio,
                        selectedChoiceID: selectedPlaybackChoiceBinding
                    ) { choice in
                        if playback.isActive(audio) {
                            playback.switchSource(audio, choice: choice)
                        }
                    }
                }

                HStack(spacing: 14) {
                    HomePodcastPlayerButton(
                        symbolName: "gobackward.15",
                        size: 34,
                        isPrimary: false,
                        isDisabled: !canSeek,
                        help: "Skip back 15 seconds",
                        automationIdentifier: "transcripted.home.meeting-preview.audio.skip-back"
                    ) {
                        playback.skip(audio, by: -15)
                    }

                    HomePodcastPlayerButton(
                        symbolName: playback.symbolName(for: audio, choice: selectedPlaybackChoice),
                        size: 46,
                        isPrimary: playback.isActive(audio, choice: selectedPlaybackChoice),
                        isDisabled: false,
                        help: "\(playback.buttonTitle(for: audio, choice: selectedPlaybackChoice)) meeting audio",
                        automationIdentifier: "transcripted.home.meeting-preview.audio.toggle"
                    ) {
                        playback.toggle(audio, choice: selectedPlaybackChoice)
                    }

                    HomePodcastPlayerButton(
                        symbolName: "goforward.15",
                        size: 34,
                        isPrimary: false,
                        isDisabled: !canSeek,
                        help: "Skip forward 15 seconds",
                        automationIdentifier: "transcripted.home.meeting-preview.audio.skip-forward"
                    ) {
                        playback.skip(audio, by: 15)
                    }
                }
            }

            MeetingAudioScrubber(
                attachment: audio,
                width: nil,
                showsTime: false
            )
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.035))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.09), lineWidth: 1)
        )
    }

    private var canSeek: Bool {
        playback.isActive(audio) && playback.duration > 0
    }

    private var selectedPlaybackChoice: MeetingAudioPlaybackChoice? {
        playback.activeChoice(for: audio) ?? audio.playbackChoice(id: selectedPlaybackChoiceID)
    }

    private var selectedPlaybackChoiceBinding: Binding<String?> {
        Binding(
            get: { selectedPlaybackChoice?.id },
            set: { selectedPlaybackChoiceID = $0 }
        )
    }
}

private struct HomePodcastPlayerButton: View {
    let symbolName: String
    let size: CGFloat
    let isPrimary: Bool
    let isDisabled: Bool
    let help: String
    let automationIdentifier: String
    let action: () -> Void

    private var hitTargetSize: CGFloat {
        max(size, HomeHitTarget.minimum)
    }

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(background)
                    .frame(width: size, height: size)
                    .overlay(
                        Circle()
                            .stroke(Color.primary.opacity(isPrimary ? 0.0 : 0.08), lineWidth: 1)
                    )

                Image(systemName: symbolName)
                    .font(.system(size: size >= 40 ? 15 : 12, weight: .bold))
                    .foregroundStyle(foreground)
                    .frame(width: size, height: size)
            }
            .frame(width: hitTargetSize, height: hitTargetSize)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.42 : 1)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityIdentifier(automationIdentifier)
    }

    private var foreground: Color {
        if isPrimary { return .white }
        return .secondary
    }

    private var background: Color {
        if isPrimary { return Color.accentColor }
        return Color.primary.opacity(0.08)
    }
}

/// Find-within-transcript bar shown above the meeting preview transcript.
/// Drives `TranscriptFinder` matching in the parent sheet: a query field, a
/// match counter, and previous/next steppers that move the active highlight.
private struct HomeTranscriptFindBar: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding
    let matchCount: Int
    let currentIndex: Int
    let onNext: () -> Void
    let onPrevious: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Find in transcript", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused(isFocused)
                .onSubmit(onNext)
                .accessibilityIdentifier("transcripted.home.meeting-preview.find-field")

            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(matchCountLabel)
                    .font(.system(size: 11, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("transcripted.home.meeting-preview.find-count")

                HStack(spacing: 2) {
                    stepButton(symbol: "chevron.up", help: "Previous match", action: onPrevious)
                    stepButton(symbol: "chevron.down", help: "Next match", action: onNext)
                }
                .disabled(matchCount == 0)
                .opacity(matchCount == 0 ? 0.4 : 1)

                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear find")
                .accessibilityLabel("Clear find")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var matchCountLabel: String {
        guard matchCount > 0 else { return "No matches" }
        return "\(min(currentIndex, matchCount - 1) + 1) of \(matchCount)"
    }

    private func stepButton(symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .frame(width: 22, height: 20)
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Builds the highlighted `AttributedString` for one transcript line: every
/// occurrence of the find query is tinted, and the active match (the one the
/// next/prev steppers are parked on) gets a stronger tint.
enum TranscriptFindHighlight {
    static func attributedText(
        for text: String,
        query: String,
        activeRange: Range<Int>?
    ) -> AttributedString {
        var attributed = AttributedString(text)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return attributed }

        for match in TranscriptFinder.matches(in: [text], query: trimmed) {
            guard let range = attributedRange(match.range, in: text, attributed: attributed) else { continue }
            let isActive = (match.range == activeRange)
            attributed[range].backgroundColor = isActive
                ? Color.orange.opacity(0.85)
                : Color.yellow.opacity(0.45)
            // Force dark text so the tint stays legible in light and dark mode.
            attributed[range].foregroundColor = Color.black
        }
        return attributed
    }

    private static func attributedRange(
        _ utf16Range: Range<Int>,
        in text: String,
        attributed: AttributedString
    ) -> Range<AttributedString.Index>? {
        let nsRange = NSRange(location: utf16Range.lowerBound, length: utf16Range.count)
        guard let stringRange = Range(nsRange, in: text) else { return nil }
        let lower = text.distance(from: text.startIndex, to: stringRange.lowerBound)
        let length = text.distance(from: stringRange.lowerBound, to: stringRange.upperBound)
        let start = attributed.index(attributed.startIndex, offsetByCharacters: lower)
        let end = attributed.index(start, offsetByCharacters: length)
        return start..<end
    }
}

private struct HomeMeetingTranscriptLineView: View {
    let line: HomeMeetingTranscriptLine
    var highlightQuery: String = ""
    var activeRange: Range<Int>? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(line.time)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
                .padding(.top, 4)

            HomeMeetingSpeakerPill(speaker: line.speaker)

            Text(TranscriptFindHighlight.attributedText(
                for: line.text,
                query: highlightQuery,
                activeRange: activeRange
            ))
                .font(.system(size: 13))
                .foregroundStyle(Color.primary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }
}

private struct HomeMeetingSpeakerPill: View {
    let speaker: String

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(speakerColor)
                .frame(width: 6, height: 6)

            Text(speaker)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(speakerColor)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: 116, alignment: .leading)
        .background(
            Capsule(style: .continuous)
                .fill(speakerColor.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(speakerColor.opacity(0.24), lineWidth: 1)
        )
    }

    private var speakerColor: Color {
        HomeMeetingSpeakerColor.color(for: speaker)
    }
}

enum HomeMeetingSpeakerColor {
    static func color(for speaker: String) -> Color {
        let palette: [NSColor] = [
            .systemBlue,
            .systemGreen,
            .systemPurple,
            .systemOrange,
            .systemPink,
            .systemTeal,
            .systemRed,
            .systemIndigo,
        ]

        let index = HomeMeetingSpeakerPalette.slotIndex(for: speaker, slotCount: palette.count)
        return Color(nsColor: palette[index])
    }
}

