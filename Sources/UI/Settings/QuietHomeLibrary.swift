import AppKit
import SwiftUI
import TranscriptedCore

// Quiet-library Home components (2026-08 redesign).
//
// The Meetings page is a shelf, not a dashboard: one title, one sentence,
// then day-grouped captures. Rows lead with the title; duration is the only
// always-on metadata; time-of-day and actions reveal on hover. Opening a
// capture expands it in place — no sheet, no "Done" button.

// MARK: - Header

/// Page title plus the single status sentence. The sentence carries the
/// capture count and at most one attention clause, rendered as a link to
/// the place where the work lives.
struct QuietHomeHeader: View {
    @State private var isNewHovered = false
    let capturesToday: Int
    let attentionTitle: String?
    let onAttention: () -> Void
    let onToggleFind: () -> Void
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                // Same title treatment as SettingsPageIntro so Meetings,
                // Dictations, and Speakers read as siblings.
                Text("Meetings")
                    .font(LibraryTokens.title)
                Spacer()
                Menu {
                    Button(action: onStartMeeting) {
                        Label("Record a meeting", systemImage: "mic")
                    }
                    .accessibilityIdentifier("transcripted.home.new.record-meeting")
                    Button(action: onImportAudioFile) {
                        Label("Transcribe a file…", systemImage: "doc.badge.plus")
                    }
                    .accessibilityIdentifier("transcripted.home.new.transcribe-file")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isNewHovered ? Color.primary : LibraryTokens.ink3)
                        .frame(width: 26, height: 26)
                        .background {
                            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl)
                                .fill(isNewHovered ? LibraryTokens.rowHover : Color.clear)
                        }
                        .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .onHover { isNewHovered = $0 }
                .help("New recording or transcription")
                .accessibilityLabel("New recording or transcription")
                .accessibilityIdentifier("transcripted.home.new.menu")
                Button(action: onToggleFind) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LibraryTokens.ink3)
                        .frame(width: 26, height: 26)
                        .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl))
                }
                .buttonStyle(.plain)
                .help("Find meetings")
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
                            .foregroundStyle(LibraryTokens.attention)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transcripted.home.attention.link")
                }
            }
        }
    }

    private var capturesSummary: String {
        switch capturesToday {
        case 0: return "Nothing saved yet today"
        case 1: return "1 saved today"
        default: return "\(capturesToday) saved today"
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

            if let warning = item.systemAudioVerificationWarning {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .help("Didn't hear anyone else on the call. They may have been quiet, or call audio wasn't recorded.")
                    .accessibilityIdentifier("transcripted.home.meeting.system-audio-unverified")
            }

            Spacer(minLength: 12)

            // Always present so the row keeps one constant height; hover only
            // fades the actions in and tints the background — no size change.
            HStack(spacing: 10) {
                Text(startTimeString)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                HomeRowActionButtons(
                    isCopied: isCopied,
                    onCopy: onCopy,
                    menuItems: menuItems
                )
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)

            if let durationString {
                Text(durationString)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
        }
        .padding(.vertical, 2)
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
    let symbolName: String
    let tone: HomeTranscriptionActivityPresentation.Tone
    let onCancel: (() -> Void)?
    /// When non-nil, the session is actively recording: render a red dot and
    /// the live timer instead of a spinner. Stop stays in the menu bar and
    /// the recording overlay — Home only reflects the state.
    var recordingElapsed: String? = nil
    /// Plain-language reason under a failed row.
    var detail: String? = nil
    /// Shows Open on a saved row: expands that meeting in the list.
    var onOpen: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let recordingElapsed {
                // The live time comes from the shell's clock, so the
                // once-a-second tick redraws only this label.
                QuietRecordingElapsedLabel(fallback: recordingElapsed)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(LibraryTokens.rowTitle)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if tone == .working {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(tone == .success ? Color.green : Color.orange)
                        }
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LibraryTokens.ink2)
                        if let percent = HomeActivityPercent.displayed(progress) {
                            Text("\(percent)%")
                                .font(.system(size: 11.5))
                                .foregroundStyle(LibraryTokens.ink3)
                        }
                    }
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LibraryTokens.ink2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("transcripted.home.activity.detail")
                    }
                }
            }
            Spacer()
            if recordingElapsed == nil, let onOpen {
                Button("Open", action: onOpen)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Show this meeting's transcript")
                    .accessibilityIdentifier("transcripted.home.activity.open")
            }
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
        HomeRecordingElapsed.text(seconds)
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
    let knownPeople: [SpeakerIdentityOption]
    let savedSpeakerIDs: Set<UUID>
    let onAssignSpeakers: (
        [HomeMeetingSpeakerAssignment],
        @escaping (Bool) -> Void
    ) -> Void
    let menuItems: [HomeRowMenuItem]

    @State private var showsFullTranscript = false
    @State private var showsSpeakerNamingSheet = false

    private static let visibleLineLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityIdentifier("transcripted.home.expansion.title")
                    Text(metaLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LibraryTokens.ink3)
                    if let warning = item.systemAudioVerificationWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.attention)
                        Text("Didn't hear anyone else on the call. They may have been quiet, or call audio wasn't recorded.")
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                    }
                }
                Spacer()
                // Hidden control so Esc collapses the expansion.
                Button(action: onCollapse) { EmptyView() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
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
        .sheet(isPresented: $showsSpeakerNamingSheet) {
            if let content = preview?.content {
                HomeMeetingSpeakerNamingSheet(
                    content: content,
                    knownPeople: knownPeople,
                    savedSpeakerIDs: savedSpeakerIDs,
                    onCancel: { showsSpeakerNamingSheet = false },
                    onSave: { assignments, completion in
                        onAssignSpeakers(assignments) { didSave in
                            if didSave { showsSpeakerNamingSheet = false }
                            completion(didSave)
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let preview {
            if let readError = preview.readError {
                Text(readError)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.attention)
            } else {
                transcript(for: preview.content)
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
            HStack(alignment: .firstTextBaseline) {
                Text("TRANSCRIPT")
                    .font(LibraryTokens.label)
                    .tracking(LibraryTokens.labelTracking)
                    .foregroundStyle(LibraryTokens.ink3)
                    .help("Transcribed on this Mac")
                Spacer()
                if !content.transcriptLines.isEmpty {
                    Button {
                        showsSpeakerNamingSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "person.2")
                                .font(.system(size: 10.5, weight: .medium))
                            Text("Name speakers")
                                .font(LibraryTokens.meta)
                        }
                        .foregroundStyle(LibraryTokens.ink2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Assign or correct every speaker in this meeting")
                    .accessibilityIdentifier("transcripted.home.expansion.name-speakers")
                }
            }

            if content.transcriptLines.isEmpty {
                Text(content.fallbackText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(.primary)
                    .lineLimit(showsFullTranscript ? nil : 12)
                    .textSelection(.enabled)
            } else {
                let visibleIndices = showsFullTranscript
                    ? Array(content.transcriptLines.indices)
                    : Array(content.transcriptLines.indices.prefix(Self.visibleLineLimit))
                ForEach(visibleIndices, id: \.self) { index in
                    transcriptLine(content.transcriptLines[index], index: index)
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

    private func transcriptLine(_ line: HomeMeetingTranscriptLine, index: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !line.time.isEmpty {
                if let audio = item.audio, let startSeconds = line.startSeconds {
                    QuietTranscriptTimestamp(time: line.time, index: index) {
                        MeetingAudioPlayback.shared.play(
                            audio,
                            from: startSeconds,
                            rowSourceStem: line.identity.channel.map(Self.retainedAudioStem(for:))
                        )
                    }
                } else {
                    Text(line.time)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LibraryTokens.ink3)
                        .frame(width: 52, alignment: .leading)
                }
            }
            if !line.speaker.isEmpty {
                QuietMeetingSpeakerLabel(
                    identity: line.identity,
                    knownPeople: knownPeople,
                    isSavedPerson: identityIsSaved(line.identity),
                    onAssign: { assignment, completion in
                        onAssignSpeakers([assignment], completion)
                    }
                )
            }
            Text(line.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    /// Retained-audio file stem that holds a channel's speech.
    private static func retainedAudioStem(for channel: HomeMeetingSpeakerChannel) -> String {
        switch channel {
        case .mic: return "microphone"
        case .system: return "system_audio"
        }
    }

    private func identityIsSaved(_ identity: HomeMeetingSpeakerIdentity) -> Bool {
        identity.persistentSpeakerID.map(savedSpeakerIDs.contains) ?? false
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

    private var metaLine: String {
        var parts: [String] = []
        parts.append(Self.timeFormatter.string(from: item.startDate ?? item.date))
        if let start = item.startDate, let end = item.endDate, end > start {
            let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
            parts.append("\(minutes) min")
        }
        if let modelName = item.transcriptionModelName {
            parts.append(modelName)
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

extension RecentMeetingItem {
    /// The speech model that made this transcript, e.g. "Parakeet V3".
    var transcriptionModelName: String? {
        transcriptionEngine.flatMap(TranscriptionModelChoice.shortTitle(forTranscriptionEngineIdentifier:))
    }
}
