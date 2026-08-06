import AppKit
import SwiftUI
import TranscriptedCore

// Quiet-library Home components (2026-08 redesign).
//
// Home is a shelf, not a dashboard: one greeting, one sentence, then
// day-grouped captures. Rows lead with the title; duration is the only
// always-on metadata; time-of-day and actions reveal on hover. Opening a
// capture expands it in place — no sheet, no "Done" button.

// MARK: - Header

/// Greeting plus the single status sentence. The sentence carries the
/// capture count and at most one attention clause, rendered as a link to
/// the place where the work lives.
struct QuietHomeHeader: View {
    let greeting: String
    let capturesToday: Int
    let attentionTitle: String?
    let onAttention: () -> Void
    let onToggleFind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(greeting)
                    .font(LibraryTokens.title)
                Spacer()
                Button(action: onToggleFind) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LibraryTokens.ink3)
                        .frame(width: 26, height: 26)
                        .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl))
                }
                .buttonStyle(.plain)
                .help("Find captures")
                .accessibilityIdentifier("transcripted.home.find.toggle")
            }

            HStack(spacing: 0) {
                Text(capturesSummary)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                if let attentionTitle {
                    Text("  ·  ")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink3)
                    Button(action: onAttention) {
                        Text(attentionTitle)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transcripted.home.attention.link")
                }
            }
        }
    }

    private var capturesSummary: String {
        switch capturesToday {
        case 0: return "No captures yet today"
        case 1: return "1 capture today"
        default: return "\(capturesToday) captures today"
        }
    }
}

// MARK: - Rows

/// Title-first meeting row. Duration always visible; start time and actions
/// fade in on hover.
struct QuietMeetingRow: View {
    let item: RecentMeetingItem
    let isCopied: Bool
    let isExpanded: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let menuItems: [HomeRowMenuItem]
    var showsMicBoostHint: Bool = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if showsMicBoostHint {
                Circle()
                    .fill(LibraryTokens.attention)
                    .frame(width: 6, height: 6)
                    .help("Your mic was muffled by another call app")
            }

            Text(item.title)
                .font(LibraryTokens.rowTitle)
                .lineLimit(1)
                .accessibilityIdentifier("transcripted.home.meeting.preview")

            Spacer(minLength: 12)

            if isHovering {
                HStack(spacing: 10) {
                    Text(startTimeString)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                    HomeRowActionButtons(
                        isCopied: isCopied,
                        onCopy: onCopy,
                        onFlag: {},
                        menuItems: menuItems
                    )
                }
                .transition(.opacity)
            }

            if let durationString {
                Text(durationString)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 1, style: .continuous)
                .fill((isHovering || isExpanded) ? LibraryTokens.rowHover : Color.clear)
        )
        .padding(.horizontal, -10)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .onTapGesture(perform: onOpen)
        .help("Open capture")
    }

    private var startTimeString: String {
        HomeActivityRowFormatting.timeFormatter.string(from: item.startDate ?? item.date)
    }

    private var durationString: String? {
        guard let start = item.startDate, let end = item.endDate, end > start else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}

/// In-flight transcription rendered as a row-shaped status line instead of a
/// dashboard card. Appears above the day list while work is running.
struct QuietWorkingRow: View {
    let title: String
    let status: String
    let progress: Double?
    let onCancel: (() -> Void)?
    /// When non-nil, the session is actively recording: render a red dot and
    /// the live timer instead of a spinner. Stop stays in the menu bar and
    /// the recording overlay — Home only reflects the state.
    var recordingElapsed: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let recordingElapsed {
                HStack(spacing: 8) {
                    Circle()
                        .fill(LibraryTokens.recording)
                        .frame(width: 7, height: 7)
                    Text("Recording")
                        .font(LibraryTokens.rowTitle)
                    Text("·  \(recordingElapsed)")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording, \(recordingElapsed) elapsed")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(LibraryTokens.rowTitle)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LibraryTokens.ink2)
                        if let progress, progress > 0 {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11.5))
                                .foregroundStyle(LibraryTokens.ink3)
                        }
                    }
                }
            }
            Spacer()
            if recordingElapsed == nil, let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .accessibilityIdentifier("transcripted.home.activity.cancel")
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("transcripted.home.activity.row")
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Inline expansion

/// The opened capture: player, transcript, quiet text actions — revealed in
/// place within the list. Esc or the row click collapses it.
struct QuietMeetingExpansion: View {
    let item: RecentMeetingItem
    let preview: HomeMeetingPreview?
    let isCopied: Bool
    let onCopy: () -> Void
    let onRevealInFinder: () -> Void
    let onCollapse: () -> Void
    /// Commits an edited title. Called with the trimmed field text on Enter;
    /// the caller should treat an empty or unchanged value as a no-op (this
    /// view already skips the call in both of those cases).
    let onRename: (String) -> Void
    let menuItems: [HomeRowMenuItem]

    @State private var showsFullTranscript = false
    @State private var isEditingTitle = false
    @State private var editedTitle = ""
    @FocusState private var titleFieldIsFocused: Bool

    private static let visibleLineLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    titleView
                    Text(metaLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LibraryTokens.ink3)
                }
                Spacer()
                // Hidden control so Esc collapses the expansion. Suppressed
                // while the title is being edited so Esc there only cancels
                // the edit (see `titleView`'s `onExitCommand`).
                if !isEditingTitle {
                    Button(action: onCollapse) { EmptyView() }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .frame(width: 0, height: 0)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }

            if let audio = item.audio {
                HomeMeetingPodcastPlayer(audio: audio)
                    .padding(.top, 12)
            }

            content
                .padding(.top, 12)

            HStack(spacing: 16) {
                quietAction(
                    title: isCopied ? "Copied" : "Copy",
                    symbol: isCopied ? "checkmark" : "square.on.square",
                    tint: isCopied ? LibraryTokens.accent : LibraryTokens.ink2,
                    action: onCopy
                )
                .accessibilityIdentifier("transcripted.home.expansion.copy")

                quietAction(
                    title: "Show in Finder",
                    symbol: "folder",
                    tint: LibraryTokens.ink2,
                    action: onRevealInFinder
                )
                .accessibilityIdentifier("transcripted.home.expansion.reveal")

                Spacer()

                if !menuItems.isEmpty {
                    HomeRowMoreMenuButton(
                        items: menuItems,
                        automationIdentifier: "transcripted.home.expansion.more"
                    )
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
                    .padding(.top, 6)
            }
        }
        .padding(18)
        .contentShape(Rectangle())
        // Swallow taps inside the card so the page-level background tap
        // catcher (click-away collapse) doesn't fire for clicks on the
        // expansion's own non-interactive areas.
        .onTapGesture {}
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .padding(.vertical, 6)
        .accessibilityIdentifier("transcripted.home.expansion")
    }

    @ViewBuilder
    private var content: some View {
        if let preview {
            if let readError = preview.readError {
                Text(readError)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.attention)
            } else {
                transcript(for: HomeMeetingPreviewContent.make(from: preview.markdown))
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Loading…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func transcript(for content: HomeMeetingPreviewContent) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("TRANSCRIPT")
                .font(LibraryTokens.label)
                .tracking(LibraryTokens.labelTracking)
                .foregroundStyle(LibraryTokens.ink3)
                .help("Transcribed on this Mac")

            if content.transcriptLines.isEmpty {
                Text(content.fallbackText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(.primary)
                    .lineLimit(showsFullTranscript ? nil : 12)
                    .textSelection(.enabled)
            } else {
                let lines = showsFullTranscript
                    ? content.transcriptLines
                    : Array(content.transcriptLines.prefix(Self.visibleLineLimit))
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    transcriptLine(line)
                }
                if content.transcriptLines.count > Self.visibleLineLimit {
                    Button(showsFullTranscript
                        ? "Show less"
                        : "Show all \(content.transcriptLines.count) lines"
                    ) {
                        withAnimation(.snappy(duration: 0.2)) { showsFullTranscript.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
                .padding(.top, -6)
        }
    }

    private func transcriptLine(_ line: HomeMeetingTranscriptLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !line.time.isEmpty {
                Text(line.time)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LibraryTokens.ink3)
                    .frame(width: 52, alignment: .leading)
            }
            if !line.speaker.isEmpty {
                Text(line.speaker)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(line.speaker == "You" ? LibraryTokens.accent : LibraryTokens.ink2)
                    .frame(width: 72, alignment: .leading)
                    .lineLimit(1)
            }
            Text(line.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
        }
    }

    private func quietAction(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(LibraryTokens.meta)
            }
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Click-to-edit title: a plain title that swaps for a focused text field
    /// on click, commits on Enter, and cancels on Esc without collapsing the
    /// expansion.
    @ViewBuilder
    private var titleView: some View {
        if isEditingTitle {
            TextField("Title", text: $editedTitle)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .semibold))
                .focused($titleFieldIsFocused)
                .onSubmit { commitTitleEdit() }
                .onExitCommand { cancelTitleEdit() }
                .onAppear { titleFieldIsFocused = true }
                .onChange(of: titleFieldIsFocused) { _, focused in
                    if !focused && isEditingTitle { commitTitleEdit() }
                }
                .accessibilityIdentifier("transcripted.home.expansion.title.field")
        } else {
            Text(item.title)
                .font(.system(size: 15, weight: .semibold))
                .contentShape(Rectangle())
                .onTapGesture { beginTitleEdit() }
                .accessibilityIdentifier("transcripted.home.expansion.title")
        }
    }

    private func beginTitleEdit() {
        editedTitle = item.title
        isEditingTitle = true
    }

    private func commitTitleEdit() {
        isEditingTitle = false
        let trimmed = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.title else { return }
        onRename(trimmed)
    }

    private func cancelTitleEdit() {
        isEditingTitle = false
        editedTitle = item.title
    }

    private var metaLine: String {
        var parts: [String] = []
        parts.append(Self.timeFormatter.string(from: item.startDate ?? item.date))
        if let start = item.startDate, let end = item.endDate, end > start {
            let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
            parts.append("\(minutes) min")
        }
        return parts.joined(separator: "  ·  ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

// MARK: - Background tap catcher

/// Makes a container's full bounds hit-testable so a tap on otherwise-empty
/// space (the gaps around rows, day-group padding, the space below the last
/// row) can be caught by the shell — typically to collapse an open
/// `QuietMeetingExpansion`. Apply to the list container, not individual
/// rows: SwiftUI resolves gestures on the innermost view that recognizes
/// them first, so a row's own `onTapGesture` (open/toggle) or a button
/// inside the expansion still wins over this background catcher.
private struct HomeBackgroundTapCatcherModifier: ViewModifier {
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

extension View {
    /// See `HomeBackgroundTapCatcherModifier`. Wire `onTap` to collapse the
    /// currently-open Home meeting expansion.
    func homeBackgroundTapCatcher(onTap: @escaping () -> Void) -> some View {
        modifier(HomeBackgroundTapCatcherModifier(onTap: onTap))
    }
}
