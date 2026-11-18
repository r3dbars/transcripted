import AppKit
import SwiftUI
import TranscriptedCore

// Quiet-library Home components (2026-08 redesign, cards 2026-11).
//
// The Meetings page is a shelf, not a dashboard: one title, then day-grouped
// meeting cards (`HomeMeetingCard.swift`). Each card opens in place with
// Show more; there is no sheet and no separate meeting page. The header
// carries find, the Keep audio filter, and the two ways in: Transcribe a
// file… (also a drop anywhere on the page) and Record a meeting. Today owns
// the day's counts, so the header doesn't repeat them.

// MARK: - Header

/// Page title, its actions, and at most one attention clause rendered as a
/// link to the place where the work lives.
struct QuietHomeHeader: View {
    let attentionTitle: String?
    let onAttention: () -> Void
    let onToggleFind: () -> Void
    let onStartMeeting: () -> Void
    let onImportAudioFile: () -> Void
    var isKeptAudioOnly: Bool = false
    var onToggleKeptAudio: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                // Same title treatment as SettingsPageIntro so Meetings,
                // Dictations, and Speakers read as siblings.
                Text("Meetings")
                    .font(LibraryTokens.title)
                Spacer()
                QuietHeaderIconButton(
                    systemName: "magnifyingglass",
                    help: "Find meetings",
                    automationIdentifier: "transcripted.home.find.toggle",
                    action: onToggleFind
                )
                QuietHeaderIconButton(
                    systemName: isKeptAudioOnly ? "pin.fill" : "pin",
                    help: isKeptAudioOnly ? "Show all meetings" : "Show meetings that keep their audio",
                    isOn: isKeptAudioOnly,
                    automationIdentifier: "transcripted.home.starred.toggle",
                    action: onToggleKeptAudio
                )
                Button(HomeCaptureListCopy.TranscribeFileAction.title, action: onImportAudioFile)
                    .buttonStyle(.transcriptedSecondary)
                    .controlSize(.small)
                    .help(HomeCaptureListCopy.TranscribeFileAction.help)
                    .accessibilityIdentifier(HomeCaptureListCopy.TranscribeFileAction.automationIdentifier)
                    .padding(.leading, 4)
                Button("Record a meeting", action: onStartMeeting)
                    .buttonStyle(.transcriptedSecondary)
                    .controlSize(.small)
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

/// In-flight transcription, shown in the same card as a saved meeting:
/// title, then one status line with a spinner and percent. Appears above the
/// day list while work is running. Ink buttons only; the recording dot is
/// live green.
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
                        .font(TextRole.body.font(weight: .semibold))
                        .foregroundStyle(LibraryTokens.ink)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        if case .statusIcon(let isSuccess) = HomeActivityIndicator.make(isWorking: tone == .working, isSuccess: tone == .success) {
                            Image(systemName: symbolName)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isSuccess ? LibraryTokens.ink2 : LibraryTokens.attention)
                        } else {
                            ProgressView()
                                .controlSize(.mini)
                        }
                        Text(status)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(tone == .caution ? LibraryTokens.attention : LibraryTokens.ink2)
                        if let percent = HomeActivityPercent.displayed(progress) {
                            Text("\(percent)%")
                                .font(LibraryTokens.meta)
                                .monospacedDigit()
                                .foregroundStyle(LibraryTokens.ink3)
                        }
                    }
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
            Spacer()
            if recordingElapsed == nil, let onOpen {
                Button("Open", action: onOpen)
                    .buttonStyle(.transcriptedSecondary)
                    .controlSize(.small)
                    .help("Show this meeting's transcript")
                    .accessibilityIdentifier("transcripted.home.activity.open")
            }
            if recordingElapsed == nil, let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.transcriptedQuiet)
                    .controlSize(.small)
                    .accessibilityIdentifier("transcripted.home.activity.cancel")
            }
        }
        .homeMeetingCardSurface()
        .accessibilityIdentifier("transcripted.home.activity.row")
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        HomeRecordingElapsed.text(seconds)
    }
}
