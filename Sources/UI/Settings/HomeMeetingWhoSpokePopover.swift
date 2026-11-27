import AppKit
import SwiftUI

// "1 voice to name" on a Meetings card, and the "Who spoke?" it opens right
// there: the island's own review (`NotchIslandSpeakerReviewView`, the same
// one the Speakers page hosts), black like the island, with the 42 pt prints
// that play each voice, "Who's this?", the quote, invitee chips, saved-people
// autocomplete, Not a person, Undo, the footer's dots, then Later and Done.
// Done saves through the Speakers page's own path, so a name given here lands
// in Speakers and the transcript. The shell builds the review
// (`homeInlineWhoSpokeSession` in `+HomeSpeakerVoiceprints.swift`); with
// nothing to build it from, the trigger falls back to Speakers.

/// One open inline review: the view, its invitees, and a save that failed.
@MainActor
final class HomeMeetingWhoSpokeSession: ObservableObject, Identifiable {
    let id = UUID()
    let review: NotchIslandSpeakerReviewView
    let invitees: [String]
    @Published var saveError: String?
    @Published var isSaving = false

    init(review: NotchIslandSpeakerReviewView, invitees: [String]) {
        self.review = review
        self.invitees = invitees
    }

    /// The popover's content width.
    static let contentWidth: CGFloat = 420
}

// MARK: - Trigger

/// "1 voice to name": a quiet tonal pill with an unlit, dotted print and a
/// small ink dot. It lifts on hover; never amber.
struct HomeMeetingVoicesToNameButton: View {
    let count: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        if let title = HomeMeetingRailPresentation.voicesToNameTitle(count) {
            Button(action: action) {
                HStack(spacing: 5) {
                    ZStack(alignment: .topTrailing) {
                        HomeMiniVoicePrint(
                            style: VoicePrintStyle(seedString: "unnamed"),
                            color: isHovering ? LibraryTokens.ink2 : LibraryTokens.ink3,
                            size: 13,
                            isDashed: true
                        )
                        Circle()
                            .fill(LibraryTokens.ink)
                            .frame(width: 4, height: 4)
                            .offset(x: 1, y: -1)
                    }
                    Text(title)
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(isHovering ? LibraryTokens.ink : LibraryTokens.ink2)
                        .lineLimit(1)
                }
                .padding(.leading, 5)
                .padding(.trailing, 8)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(isHovering ? DesignTokens.fillStrong : DesignTokens.fill)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(DesignTokens.hairline, lineWidth: 1)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .animation(.easeOut(duration: 0.14), value: isHovering)
            .help("Name who spoke in this meeting")
            .accessibilityLabel(Text("Who spoke? \(title)"))
            .accessibilityIdentifier("transcripted.home.meeting.who-spoke")
        }
    }
}

// MARK: - Popover

/// The popover's content: the review on the island's black.
struct HomeMeetingWhoSpokePopoverContent: View {
    @ObservedObject var session: HomeMeetingWhoSpokeSession

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let error = session.saveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(DesignTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("transcripted.home.meeting.who-spoke.save-error")
            }
            HomeMeetingWhoSpokeReviewFrame(review: session.review, invitees: session.invitees)
                .disabled(session.isSaving)
                .opacity(session.isSaving ? 0.6 : 1)
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 14)
        .background(SpeakerWhoSpokeLayout.cardFill)
        .environment(\.colorScheme, .dark)
        .onAppear { session.review.setOnScreen(true) }
        // Closing the popover stops a voice that is still playing.
        .onDisappear { session.review.setOnScreen(false) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.meeting.who-spoke.popover")
    }
}

/// The review at its own height, following it as rows grow and shrink.
private struct HomeMeetingWhoSpokeReviewFrame: View {
    let review: NotchIslandSpeakerReviewView
    let invitees: [String]
    @State private var height: CGFloat = 0

    var body: some View {
        HomeMeetingWhoSpokeReviewHost(review: review, invitees: invitees) { measured in
            if abs(measured - height) > 0.5 { height = measured }
        }
        .frame(width: review.width, height: max(height, 10), alignment: .topLeading)
    }
}

/// Hosts the review in the same container the Speakers page uses.
private struct HomeMeetingWhoSpokeReviewHost: NSViewRepresentable {
    let review: NotchIslandSpeakerReviewView
    let invitees: [String]
    let onHeight: (CGFloat) -> Void

    func makeNSView(context: Context) -> SpeakerWhoSpokeContainer {
        let container = SpeakerWhoSpokeContainer()
        update(container)
        return container
    }

    func updateNSView(_ container: SpeakerWhoSpokeContainer, context: Context) {
        update(container)
    }

    private func update(_ container: SpeakerWhoSpokeContainer) {
        container.onHeight = onHeight
        container.show(review)
        container.setInvitees(invitees)
    }
}
