import SwiftUI
import AppKit
import Combine
import TranscriptedCore

// SpeakerPeopleSettingsPolishContract and SpeakerPeopleEmptyState live in
// SpeakerPeopleSettingsConstants.swift so fast tests can check them by value.

struct SpeakerCompactIconLabel: View {
    let systemName: String
    let foregroundColor: Color
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    var tone: SettingsInteractionTone = .neutral
    var normalFill: Color = Color.primary.opacity(0.025)
    var normalStroke: Color = Color.primary.opacity(0.06)
    var cornerRadius: CGFloat = 8

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundColor)
            .frame(
                width: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter,
                height: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
            .frame(
                width: SpeakerPeopleSettingsPolishContract.minimumHitTarget,
                height: SpeakerPeopleSettingsPolishContract.minimumHitTarget
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.55)
            .onHover { isHovering = $0 }
            .animation(SettingsInteractionPalette.animation, value: isHovering)
    }

    private var fillColor: Color {
        guard isEnabled else { return normalFill.opacity(0.65) }
        if isHovering { return SettingsInteractionPalette.hoverFill(for: tone) }
        return normalFill
    }

    private var strokeColor: Color {
        guard isEnabled else { return normalStroke.opacity(0.5) }
        if isHovering { return SettingsInteractionPalette.hoverStroke(for: tone) }
        return normalStroke
    }
}

struct SpeakerPeopleSettingsSection: View {
    enum ScrollTarget: Hashable {
        case reviewQueue
    }

    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    /// Optional hook so the first-run empty state can offer a real next step.
    /// Defaults to nil to keep the initializer additive for existing call sites.
    var onStartMeeting: (() -> Void)? = nil
    /// Which person row is expanded in place, if any. Lives here (not on the
    /// row) so opening one person always closes any other — one person open
    /// at a time, per spec.
    @State private var expandedPersonID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Evaluated once per render: the directory properties sort and
            // filter every profile on each access.
            let directoryCount = model.directoryCount
            let directoryProfiles = model.directoryProfiles

            // Read-only: saved people moving to a new voice model, or how many
            // of them still need one confirmation there.
            if let migrationLine = model.voiceprintMigrationStatusLine {
                Text(migrationLine)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // "Who spoke?", one meeting at a time, like the island after a
            // meeting: the headline, "Meeting 1 of 8", and the top card.
            SpeakerWhoSpokeSection(model: model)
                .id(ScrollTarget.reviewQueue)
                .accessibilityIdentifier("transcripted.speakers.inbox")

            // Voices on the open card above are left out of Everyone; voices
            // on cards further down stay listed, badged, so they can be
            // renamed, merged, or deleted without cycling the stack. When the
            // open card holds every voice the directory stays hidden.
            if model.profiles.isEmpty {
                // While people are still moving in, "No speakers yet" would be wrong.
                if !model.isMovingPeopleToNewVoiceModel {
                    VStack(alignment: .leading, spacing: 12) {
                        LibrarySectionLabel(text: "Everyone")
                        SpeakersEmptyStateView(onStartMeeting: onStartMeeting)
                    }
                }
            } else if directoryCount > 0 {
                // Everyone else, by voice print: "Named automatically",
                // "Still learning", then unnamed voices outside the open card.
                VStack(alignment: .leading, spacing: 16) {
                    LibrarySectionLabel(
                        text: SpeakerMeetingReviewPolicy.directoryTitle,
                        trailing: "\(model.knownPeopleCount)"
                    )
                    SpeakerSearchRow(model: model)

                    if directoryProfiles.isEmpty {
                        Text(SpeakerPeopleEmptyState.noSearchMatches)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                    } else {
                        SpeakerPrintSectionsView(
                            profiles: directoryProfiles,
                            model: model,
                            expandedPersonID: $expandedPersonID
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        // Clicking anywhere outside an open person card collapses it, same
        // click-away grammar as Meetings and Dictations. The card swallows
        // its own inside taps.
        .homeBackgroundTapCatcher {
            if expandedPersonID != nil {
                expandedPersonID = nil
            }
        }
        .onDisappear {
            expandedPersonID = nil
            SpeakerClipPlayback.stop()
            // A card finished just before leaving saves now, not in a moment.
            model.saveFinishedMeetingNow()
        }
    }

    /// The lower edge of a card waiting under the top one.
    private func stackEdge(inset: CGFloat, opacity: Double) -> some View {
        UnevenRoundedRectangle(
            bottomLeadingRadius: LibraryTokens.radiusRaised,
            bottomTrailingRadius: LibraryTokens.radiusRaised,
            style: .continuous
        )
        .fill(LibraryTokens.raisedFill)
        .overlay(
            UnevenRoundedRectangle(
                bottomLeadingRadius: LibraryTokens.radiusRaised,
                bottomTrailingRadius: LibraryTokens.radiusRaised,
                style: .continuous
            )
            .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .frame(height: 8)
        .padding(.horizontal, inset)
        .opacity(opacity)
        .accessibilityHidden(true)
    }
}

// MARK: - Empty state teaching view

/// First-run teaching empty state for the all-speakers list: it explains what
/// the screen will fill with and offers the one action that fills it.
private struct SpeakersEmptyStateView: View {
    var onStartMeeting: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: SpeakerPeopleEmptyState.symbolName)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 5) {
                Text(SpeakerPeopleEmptyState.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.primary)

                Text(SpeakerPeopleEmptyState.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }

            if let onStartMeeting {
                Button(action: onStartMeeting) {
                    Text(SpeakerPeopleEmptyState.actionTitle)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier(SpeakerPeopleEmptyState.actionAutomationIdentifier)
                .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 16)
    }
}

/// Quiet inline play/pause control — a bare glyph, no filled circle. Ink at
/// rest, accent while its clip is the one playing; the caller renders an
/// accent sweep under the sample the sound belongs to, so "what is playing"
/// reads from the content, not from button chrome. Keeps the full 40pt hit
/// target behind a 28pt visible hover fill.
struct SpeakerQuietPlayButton: View {
    let hasClip: Bool
    let isPlaying: Bool
    let action: () -> Void
    var accessibilityIdentifier: String = "transcripted.speakers.voice-to-name.play"

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: SpeakerClipPlaybackPresentation.symbolName(isPlaying: isPlaying))
                .font(.system(size: SpeakerPeopleSettingsPolishContract.quietPlayGlyphPointSize, weight: .medium))
                .foregroundStyle(glyphColor)
                .frame(
                    width: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter,
                    height: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter
                )
                .background(
                    RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                        .fill(backgroundFill)
                )
                .frame(
                    width: SpeakerPeopleSettingsPolishContract.minimumHitTarget,
                    height: SpeakerPeopleSettingsPolishContract.minimumHitTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasClip)
        .onHover { isHovering = $0 }
        .help(SpeakerClipPlaybackPresentation.helpText(hasClip: hasClip, isPlaying: isPlaying))
        .accessibilityLabel(SpeakerClipPlaybackPresentation.accessibilityLabel(isPlaying: isPlaying))
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    private var glyphColor: Color {
        guard hasClip else { return LibraryTokens.ink3 }
        return SpeakerClipPlaybackPresentation.isActiveHighlight(hasClip: hasClip, isPlaying: isPlaying)
            ? LibraryTokens.accent
            : LibraryTokens.ink2
    }

    /// While a clip plays the control reads as engaged — a soft accent fill
    /// behind the pause glyph — so "something is playing here, click to
    /// pause" is legible at a glance, not just a 14pt glyph swap.
    private var backgroundFill: Color {
        guard hasClip else { return .clear }
        if isPlaying { return LibraryTokens.accent.opacity(0.12) }
        if isHovering { return LibraryTokens.rowHover }
        return .clear
    }
}

/// Quiet text-link action ("This is me", "Skip", "Merge into…") — ink3 at
/// rest, ink2 on hover, no fill or border. Matches the mockup's `<a>`
/// affordances and the surface's "color only for action/attention" rule.
struct SpeakerQuietLinkButton: View {
    let title: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(LibraryTokens.meta)
        }
        .buttonStyle(.plain)
        .foregroundStyle(isEnabled && isHovering ? LibraryTokens.ink2 : LibraryTokens.ink3)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Playback progress

/// Thin capsule fill that sweeps across a clip's estimated duration while it
/// plays, then eases back to empty once playback stops. Purely declarative —
/// no timer and no polling of `SpeakerClipPlayback`: `isPlaying` already comes
/// from the section's existing `SpeakerClipPlayback.stateDidChangeNotification`
/// subscription (`playbackStateVersion`), and SwiftUI's own animation engine
/// advances the fill from that single start/stop transition.
struct SpeakerClipProgressBar: View {
    let isPlaying: Bool
    let duration: TimeInterval

    /// Used when a clip's real duration could not be read (see
    /// `probeClipDuration(_:)` below) so the sweep still looks intentional
    /// instead of snapping instantly to full.
    nonisolated static let fallbackDuration: TimeInterval = 6

    @State private var isFilled = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(LibraryTokens.hairline)
                Capsule()
                    .fill(LibraryTokens.accent)
                    .frame(width: geometry.size.width * (isFilled ? 1 : 0))
            }
        }
        .frame(height: 3)
        .accessibilityHidden(true)
        .onChange(of: isPlaying) { _, playing in
            if playing {
                isFilled = false
                withAnimation(.linear(duration: max(duration, 0.5))) {
                    isFilled = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.18)) {
                    isFilled = false
                }
            }
        }
    }
}

/// Best-effort clip length for `SpeakerClipProgressBar`'s fill timing.
/// `SpeakerClipPlayback` does not expose the active `NSSound`'s duration (by
/// design — it stays a thin play/stop seam), so this reads the duration
/// directly off the file instead. Cheap: `SpeakerClipExtractor` caps these
/// samples at 8 seconds, and this never touches playback state or starts
/// audio of its own.
func probeClipDuration(_ url: URL) -> TimeInterval {
    let duration = NSSound(contentsOf: url, byReference: true)?.duration ?? 0
    return duration > 0.1 ? duration : SpeakerClipProgressBar.fallbackDuration
}

// MARK: - Everyone directory

/// Quiet find field over the directory — same treatment as the Meetings
/// page's `HomeMeetingSearchField`. The old manual refresh button is gone:
/// navigation and every mutation already refresh the model, so the library
/// never needs hand-cranking.
private struct SpeakerSearchRow: View {
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("Search speakers", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isSearchFocused)
                // Fires on first appearance and whenever ⌘F bumps the token,
                // so "Find Speaker" focuses the field whether or not the
                // Speakers page was already open.
                .task(id: model.searchFocusRequestToken) {
                    guard model.searchFocusRequestToken > 0 else { return }
                    isSearchFocused = true
                }
                .accessibilityIdentifier("transcripted.speakers.search.field")

            if !model.searchText.isEmpty {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Clear search")
                .accessibilityLabel("Clear speaker search")
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
}
