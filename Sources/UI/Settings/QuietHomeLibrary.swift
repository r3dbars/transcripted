import AppKit
import SwiftUI
import TranscriptedCore

// Quiet-library Home components (2026-08 redesign, matte cards 2026-11-27).
//
// The Meetings page is for finding a meeting: one title, then day-grouped
// cards (`HomeMeetingCard.swift`). Each card opens in place; there is no
// sheet and no separate meeting page. The header carries only three quiet
// controls: a search that sits folded as a magnifier until clicked or ⌘F,
// Import (a drop anywhere on the page also transcribes), and one ink Record
// button. Today owns the day's counts, so the header doesn't repeat them.

// MARK: - Header

/// Page title, the folded search, Import, Record, and at most one attention
/// clause rendered as a link to the place where the work lives.
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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
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
                Button("Import", action: onImportAudioFile)
                    .buttonStyle(.transcriptedSecondary)
                    .controlSize(.small)
                    .help(HomeCaptureListCopy.TranscribeFileAction.help)
                    .accessibilityLabel(Text(HomeCaptureListCopy.TranscribeFileAction.title))
                    .accessibilityIdentifier(HomeCaptureListCopy.TranscribeFileAction.automationIdentifier)
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

/// Search, folded: a magnifier at rest. Clicking it or ⌘F opens the field
/// in place; an empty field folds back on Esc or when it loses focus. It
/// matches title, the on-device line and summary, date words and named
/// speakers (`HomeMeetingListFilter`), never transcript bodies.
struct QuietHeaderSearchField: View {
    @Binding var query: String
    /// Focus moves here when this changes while the page is showing (⌘F),
    /// never just because the page appears again with an old request.
    var focusRequestToken: Int = 0
    var onFocusChange: (Bool) -> Void = { _ in }

    @FocusState private var isFocused: Bool
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { isExpanded || isFocused || !query.isEmpty }

    var body: some View {
        Group {
            if isOpen {
                field
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            } else {
                QuietHeaderIconButton(
                    systemName: "magnifyingglass",
                    help: "Search meetings (\u{2318}F)",
                    automationIdentifier: "transcripted.home.find.toggle"
                ) {
                    open()
                }
                .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isOpen)
        .onChange(of: focusRequestToken) { _, _ in
            open()
        }
    }

    private var field: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(LibraryTokens.ink3)
                .accessibilityHidden(true)
            TextField("Search meetings", text: $query, prompt: Text("Search meetings").foregroundStyle(LibraryTokens.ink3))
                .textFieldStyle(.plain)
                .font(LibraryTokens.meta)
                .focused($isFocused)
                .onExitCommand {
                    query = ""
                    close()
                }
                .onChange(of: isFocused) { _, focused in
                    onFocusChange(focused)
                    // An empty field folds back once the reader moves on.
                    if !focused, query.isEmpty { isExpanded = false }
                }
                .accessibilityLabel(Text("Search meetings"))
                .accessibilityIdentifier("transcripted.home.meeting-search.field")
            Button {
                query = ""
                close()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(LibraryTokens.ink3)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close search")
            .accessibilityLabel(Text("Clear meeting filter"))
        }
        .padding(.horizontal, 8)
        .frame(width: 205, height: HomeHitTarget.compactVisibleSize + 4)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 1, style: .continuous)
                .fill(DesignTokens.fill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 1, style: .continuous)
                .strokeBorder(DesignTokens.hairlineStrong, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        // The find affordance the QA smoke looks for, open or folded.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.find.toggle")
    }

    private func open() {
        isExpanded = true
        // Focus once the field exists.
        Task { @MainActor in
            isFocused = true
        }
    }

    private func close() {
        isFocused = false
        isExpanded = false
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
