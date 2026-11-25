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
    var normalFill: Color = LibraryTokens.raisedFill
    var normalStroke: Color = LibraryTokens.raisedStroke
    var cornerRadius: CGFloat = LibraryTokens.radiusControl

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
            // meeting: the top card, and nothing stacked in front of it.
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
                        LibrarySectionLabel(text: SpeakerMeetingReviewPolicy.directoryTitle)
                        SpeakersEmptyStateView(onStartMeeting: onStartMeeting)
                    }
                }
            } else if directoryCount > 0 {
                // Everyone else, by voice print: "Named automatically",
                // "Still learning", then unnamed voices outside the open card.
                VStack(alignment: .leading, spacing: 16) {
                    LibrarySectionLabel(text: SpeakerMeetingReviewPolicy.directoryTitle)
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
                    .font(TextRole.body.font(weight: .semibold))
                    .foregroundStyle(LibraryTokens.ink)

                Text(SpeakerPeopleEmptyState.message)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 360)
            }

            if let onStartMeeting {
                Button(action: onStartMeeting) {
                    Text(SpeakerPeopleEmptyState.actionTitle)
                }
                .buttonStyle(.transcriptedPrimary)
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

            TextField("Search", text: $model.searchText)
                .textFieldStyle(.plain)
                .font(LibraryTokens.body)
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
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
    }
}
