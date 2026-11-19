import AppKit
import SwiftUI
import TranscriptedCore

// Quiet-library Home components (2026-08 redesign, minimal rows 2026-11-18).
//
// The Meetings page is for finding a meeting: one title, then day-grouped
// rows (`HomeMeetingCard.swift`): play, title, one summary, start time.
// Each row opens in place; there is no sheet and no separate meeting page.
// The header carries a quiet search, one ⋯ menu (Transcribe a file… and the
// Only kept audio filter; a drop anywhere on the page also transcribes), and
// one ink Record button. Today owns the day's counts, so the header doesn't
// repeat them.

// MARK: - Header

/// Page title, quiet search, ⋯, Record, and at most one attention clause
/// rendered as a link to the place where the work lives.
struct QuietHomeHeader: View {
    let attentionTitle: String?
    let onAttention: () -> Void
    @Binding var searchQuery: String
    /// Bump to move keyboard focus into search (⌘F, the Find menu command).
    var searchFocusToken: Int = 0
    /// Search gained or lost keyboard focus (Esc goes to search while it has it).
    var onSearchFocusChange: (Bool) -> Void = { _ in }
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void
    var isKeptAudioOnly: Bool = false
    var onToggleKeptAudio: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                // Same title treatment as SettingsPageIntro so Meetings,
                // Dictations, and Speakers read as siblings.
                Text("Meetings")
                    .font(LibraryTokens.title)
                Spacer()
                QuietHeaderSearchField(
                    query: $searchQuery,
                    focusRequestToken: searchFocusToken,
                    onFocusChange: onSearchFocusChange
                )
                QuietMeetingsMoreMenu(
                    isKeptAudioOnly: isKeptAudioOnly,
                    onImportAudioFile: onImportAudioFile,
                    onToggleKeptAudio: onToggleKeptAudio
                )
                Button("Record", action: onStartMeeting)
                    .buttonStyle(.transcriptedPrimary)
                    .controlSize(.small)
                    .help("Record a meeting")
                    .accessibilityLabel(Text("Record a meeting"))
                    .accessibilityIdentifier("transcripted.home.new.record-meeting")
            }

            if let attentionTitle {
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

/// "Search", quiet: no border at rest, wider with a hairline once focused or
/// filled. It matches title, the on-device line and summary, date words and
/// named speakers (`HomeMeetingListFilter`), never transcript bodies.
struct QuietHeaderSearchField: View {
    @Binding var query: String
    /// Focus moves here when this changes while the page is showing (⌘F),
    /// never just because the page appears again with an old request.
    var focusRequestToken: Int = 0
    var onFocusChange: (Bool) -> Void = { _ in }

    @FocusState private var isFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { isFocused || !query.isEmpty }

    var body: some View {
        HStack(spacing: 4) {
            TextField("Search", text: $query, prompt: Text("Search").foregroundStyle(LibraryTokens.ink3))
                .textFieldStyle(.plain)
                .font(LibraryTokens.meta)
                .focused($isFocused)
                .onExitCommand {
                    query = ""
                    isFocused = false
                }
                .onChange(of: focusRequestToken) { _, _ in
                    isFocused = true
                }
                .onChange(of: isFocused) { _, focused in
                    onFocusChange(focused)
                }
                .accessibilityLabel(Text("Search meetings"))
                .accessibilityIdentifier("transcripted.home.meeting-search.field")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.ink3)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel(Text("Clear meeting filter"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .frame(width: isOpen ? 170 : 70)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .strokeBorder(isOpen ? LibraryTokens.hairline : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
        // The find affordance the QA smoke looks for (it was the magnifier).
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.find.toggle")
    }
}

/// The header's one ⋯: Transcribe a file… and Only kept audio (checked while
/// on). Both used to be header buttons; they stay one click away.
struct QuietMeetingsMoreMenu: View {
    let isKeptAudioOnly: Bool
    let onImportAudioFile: () -> Void
    let onToggleKeptAudio: () -> Void

    @State private var isHovering = false

    var body: some View {
        Menu {
            Button(HomeCaptureListCopy.TranscribeFileAction.title, action: onImportAudioFile)
                .help(HomeCaptureListCopy.TranscribeFileAction.help)
                .accessibilityIdentifier(HomeCaptureListCopy.TranscribeFileAction.automationIdentifier)
            Toggle("Only kept audio", isOn: Binding(
                get: { isKeptAudioOnly },
                set: { _ in onToggleKeptAudio() }
            ))
            .accessibilityIdentifier("transcripted.home.starred.toggle")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isKeptAudioOnly || isHovering ? LibraryTokens.ink : LibraryTokens.ink3)
                .frame(width: HomeHitTarget.compactVisibleSize, height: HomeHitTarget.compactVisibleSize)
                .background {
                    RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                        .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help(isKeptAudioOnly ? "More (showing only meetings that keep their audio)" : "More")
        .accessibilityLabel(Text("More"))
        .accessibilityValue(Text(isKeptAudioOnly ? "Only kept audio" : ""))
        .accessibilityIdentifier("transcripted.home.more")
    }
}

/// A 12 pt header glyph with a 40 pt hit shape and the row hover fill.
/// Dictations' header uses it too, so the two Find buttons match.
struct QuietHeaderIconButton: View {
    let systemName: String
    let help: String
    var isOn: Bool? = nil
    let automationIdentifier: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isOn == true || isHovering ? LibraryTokens.ink : LibraryTokens.ink3)
                .frame(width: HomeHitTarget.compactVisibleSize, height: HomeHitTarget.compactVisibleSize)
                .background {
                    RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                        .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
                }
                .frame(width: HomeHitTarget.minimum, height: HomeHitTarget.minimum)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(-(HomeHitTarget.minimum - HomeHitTarget.compactVisibleSize) / 2)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(Text(help))
        .modifier(OptionalToggleValue(isOn: isOn))
        .accessibilityIdentifier(automationIdentifier)
    }
}

private struct OptionalToggleValue: ViewModifier {
    let isOn: Bool?

    func body(content: Content) -> some View {
        if let isOn {
            content.accessibilityValue(isOn ? "On" : "Off")
        } else {
            content
        }
    }
}

// MARK: - Working row

/// In-flight transcription, drawn like a closed meeting row above the day
/// list: a spinner (or the status mark) in the play column, the title, and
/// the status in the summary slot with its percent. A failure shows its amber
/// wording and why. Quiet Open and Cancel on the right. While recording it is
/// the live dot and timer instead; Stop stays in the menu bar and the
/// recording overlay.
struct QuietWorkingRow: View {
    let title: String
    let status: String
    let progress: Double?
    let symbolName: String
    let tone: HomeTranscriptionActivityPresentation.Tone
    let onCancel: (() -> Void)?
    /// When non-nil, the session is actively recording: render the live dot
    /// and timer instead of a spinner.
    var recordingElapsed: String? = nil
    /// Plain-language reason under a failed row.
    var detail: String? = nil
    /// Shows Open on a saved row: opens that meeting in the list.
    var onOpen: (() -> Void)? = nil

    private typealias Layout = HomeMeetingRowLayout

    var body: some View {
        HStack(alignment: .center, spacing: Layout.columnGap) {
            leadingMark
                .frame(width: Layout.playColumn, height: Layout.playColumn)
            if let recordingElapsed {
                // The live time comes from the shell's clock, so the
                // once-a-second tick redraws only this label.
                QuietRecordingElapsedLabel(fallback: recordingElapsed)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(TextRole.body.font(weight: .semibold))
                        .foregroundStyle(LibraryTokens.ink)
                        .lineLimit(1)
                    statusLine
                    if let detail, !detail.isEmpty {
                        Text(detail)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("transcripted.home.activity.detail")
                    }
                }
            }
            Spacer(minLength: 8)
            if recordingElapsed == nil, let onOpen {
                Button("Open", action: onOpen)
                    .buttonStyle(.transcriptedQuiet)
                    .controlSize(.small)
                    .help("Show this meeting")
                    .accessibilityIdentifier("transcripted.home.activity.open")
            }
            if recordingElapsed == nil, let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.transcriptedQuiet)
                    .controlSize(.small)
                    .accessibilityIdentifier("transcripted.home.activity.cancel")
            }
        }
        .padding(.vertical, Layout.rowPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.activity.row")
    }

    @ViewBuilder
    private var leadingMark: some View {
        if recordingElapsed != nil {
            EmptyView()
        } else if case .statusIcon(let isSuccess) = HomeActivityIndicator.make(isWorking: tone == .working, isSuccess: tone == .success) {
            Image(systemName: symbolName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isSuccess ? LibraryTokens.ink2 : LibraryTokens.attention)
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var statusLine: some View {
        // The play column already spins; the slot keeps just the words.
        HomeMeetingSlotText(
            slot: HomeMeetingCardPresentation.workingSlot(
                status: status,
                percent: HomeActivityPercent.displayed(progress),
                isCaution: tone == .caution
            ),
            showsSpinner: false
        )
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        HomeRecordingElapsed.text(seconds)
    }
}
