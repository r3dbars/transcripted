// SpeakerWhoSpokeCards.swift
// The top of Settings › Speakers: "12 voices from your meetings need a name",
// "Meeting 1 of 8" with a segmented bar, then one meeting's "Who spoke?" card
// at a time, with the edges of the next ones peeking out underneath. The card
// is the island's own review (NotchIslandSpeakerReviewView in its page
// chrome), so a voice reads, plays and gets named exactly as it does after a
// meeting, minus the countdown. Done shows "Weekly sync is done · 3 voices
// named" with Undo while its answers wait to save, and the next card comes up.
// Copy and progress: SpeakerMeetingReviewPolicy. What the card asks and what
// it saves: SpeakerPeopleSettingsViewModel+MeetingReview.

import AppKit
import SwiftUI

struct SpeakerWhoSpokeSection: View {
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @StateObject private var store = SpeakerWhoSpokeViewStore()

    private typealias Policy = SpeakerMeetingReviewPolicy

    var body: some View {
        let calls = model.reviewStack.calls
        let review = model.meetingReview
        let position = Policy.position(meetingsDone: review.meetingsDone, meetingsLeft: calls.count)

        VStack(alignment: .leading, spacing: 14) {
            if let headline = Policy.headline(voiceCount: model.reviewStack.voiceCount) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(headline)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 8)
                        if let position {
                            Text(Policy.positionLine(position))
                                .font(LibraryTokens.meta)
                                .monospacedDigit()
                                .foregroundStyle(LibraryTokens.ink2)
                        }
                    }
                    if let position {
                        SpeakerWhoSpokeProgressBar(progress: Policy.progress(position), position: position)
                    }
                }
            }

            if let error = model.meetingSaveError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("transcripted.speakers.who-spoke.save-error")
            }

            if let finished = review.finished {
                SpeakerWhoSpokeDoneBanner(finished: finished) {
                    withAnimation(.snappy(duration: 0.28)) { model.undoFinishedMeeting() }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let call = calls.first {
                VStack(spacing: 0) {
                    SpeakerWhoSpokeCardFrame(
                        review: store.review(for: call, meetingsAfterThis: calls.count - 1, model: model),
                        invitees: model.inviteesByCallKey[call.id] ?? []
                    )
                    .padding(.horizontal, SpeakerWhoSpokeLayout.cardPadding)
                    .padding(.vertical, 18)
                    .background(
                        RoundedRectangle(cornerRadius: SpeakerWhoSpokeLayout.cornerRadius, style: .continuous)
                            .fill(SpeakerWhoSpokeLayout.cardFill)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SpeakerWhoSpokeLayout.cornerRadius, style: .continuous)
                            .stroke(SpeakerWhoSpokeLayout.cardStroke, lineWidth: 1)
                    )
                    .environment(\.colorScheme, .dark)
                    .onAppear { model.loadInvitees(for: call) }
                    .zIndex(2)

                    if calls.count > 1 {
                        stackEdge(inset: 12).zIndex(1)
                    }
                    if calls.count > 2 {
                        stackEdge(inset: 24).opacity(0.7)
                    }
                }
                .id(call.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .move(edge: .top).combined(with: .opacity)
                ))
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Policy.cardTitle(meetingTitle: call.meetingTitle))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: calls.first?.id)
        .animation(.snappy(duration: 0.28), value: review.finished?.token)
        .onChange(of: calls.map(\.id)) { _, keys in
            store.keep(
                callKeys: Set(keys.prefix(1)).union(model.meetingReview.finished.map { [$0.callKey] } ?? []),
                queuedWithDrafts: Set(keys)
            )
            model.meetingReview.resetProgressIfIdle(meetingsLeft: keys.count)
        }
    }

    /// The lower edge of a card waiting under the top one.
    private func stackEdge(inset: CGFloat) -> some View {
        let shape = UnevenRoundedRectangle(
            bottomLeadingRadius: SpeakerWhoSpokeLayout.cornerRadius,
            bottomTrailingRadius: SpeakerWhoSpokeLayout.cornerRadius,
            style: .continuous
        )
        return shape
            .fill(SpeakerWhoSpokeLayout.edgeFill)
            .overlay(shape.stroke(SpeakerWhoSpokeLayout.cardStroke, lineWidth: 1))
            .frame(height: 8)
            .padding(.horizontal, inset)
            .accessibilityHidden(true)
    }
}

enum SpeakerWhoSpokeLayout {
    /// The island's review rows at the page card's width.
    static let contentWidth: CGFloat = 600
    static let cardPadding: CGFloat = 20
    static let cornerRadius: CGFloat = 16
    static let cardFill = Color(red: 0.043, green: 0.043, blue: 0.047)
    static let edgeFill = Color(red: 0.07, green: 0.07, blue: 0.075)
    static let cardStroke = Color.white.opacity(0.16)
}

/// The meetings in this visit, one segment each (several each past twelve);
/// the lit ones are done or on the card now.
private struct SpeakerWhoSpokeProgressBar: View {
    let progress: SpeakerMeetingReviewPolicy.Progress
    let position: SpeakerMeetingReviewPolicy.Position

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<progress.segments, id: \.self) { index in
                Capsule()
                    .fill(index < progress.lit ? Color.primary.opacity(0.85) : LibraryTokens.hairline)
                    .frame(height: 4)
            }
        }
        .animation(.easeOut(duration: 0.25), value: progress)
        .accessibilityElement()
        .accessibilityLabel("Meetings to name")
        .accessibilityValue(SpeakerMeetingReviewPolicy.positionLine(position))
    }
}

/// "Weekly sync is done · 3 voices named", who they were, and Undo.
private struct SpeakerWhoSpokeDoneBanner: View {
    let finished: SpeakerMeetingReviewState.Finished
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: -8) {
                ForEach(Array(finished.personIDs.prefix(3).enumerated()), id: \.offset) { _, id in
                    let style = VoicePrintStyle(id: id)
                    VoicePrintRepresentable(
                        model: VoicePrintView.Model(style: style, colorIndex: style.preferredColorIndex, litRings: 1, surface: .island),
                        diameter: 26
                    )
                    .frame(width: 26, height: 26)
                    .allowsHitTesting(false)
                }
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(SpeakerReviewCardProgress.doneLine(callTitle: finished.title, namedCount: finished.names.count))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(SpeakerMeetingReviewPolicy.doneDetail(names: finished.names))
                    .font(LibraryTokens.meta)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Undo", action: onUndo)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Bring this meeting back. Nothing has been saved yet.")
                .accessibilityIdentifier("transcripted.speakers.who-spoke.undo")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: SpeakerWhoSpokeLayout.cornerRadius, style: .continuous)
                .fill(SpeakerWhoSpokeLayout.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: SpeakerWhoSpokeLayout.cornerRadius, style: .continuous)
                .stroke(SpeakerWhoSpokeLayout.cardStroke, lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Hosting the island's review

/// Keeps each card's review view while the page is open, so Undo brings a
/// finished card back with its answers in place.
@MainActor
final class SpeakerWhoSpokeViewStore: ObservableObject {
    private var reviews: [String: (view: NotchIslandSpeakerReviewView, people: Int)] = [:]

    func review(
        for call: SpeakerPendingMeetingGroup,
        meetingsAfterThis: Int,
        model: SpeakerPeopleSettingsViewModel
    ) -> NotchIslandSpeakerReviewView {
        let card = NotchIslandSpeakerReviewView.PageCard(
            title: SpeakerMeetingReviewPolicy.cardTitle(meetingTitle: call.meetingTitle),
            detail: Self.dateLine(for: call),
            doneTitle: SpeakerMeetingReviewPolicy.doneTitle(meetingsAfterThis: meetingsAfterThis),
            skipTitle: SpeakerMeetingReviewPolicy.skipTitle,
            skipHelp: SpeakerMeetingReviewPolicy.skipHelp
        )
        let key = Self.key(for: call)
        let people = model.whoSpokeInputSignature
        // A card keeps its answers. One nobody has touched yet is rebuilt when
        // saved people, their progress or the voice matches change, so its
        // suggestions and guesses stay current.
        if let cached = reviews[key], cached.people == people || cached.view.hasDraft {
            cached.view.updatePageCard(card)
            return cached.view
        }
        let review = NotchIslandSpeakerReviewView(
            input: model.meetingReviewInput(for: call),
            chrome: .page(card),
            width: SpeakerWhoSpokeLayout.contentWidth
        )
        review.setMeetingTitle(call.meetingTitle)
        review.onDone = { [weak model] updates, _ in
            withAnimation(.snappy(duration: 0.3)) { model?.finishMeeting(call, updates: updates) }
        }
        review.onSkip = { [weak model] updates in
            withAnimation(.snappy(duration: 0.3)) { model?.skipMeeting(call, updates: updates) }
        }
        reviews = reviews.filter { $0.key.hasPrefix(call.id + "|") == false }
        reviews[key] = (review, people)
        return review
    }

    /// Drops the views of cards no longer on top or waiting on Undo, except
    /// a card still in the stack with answers on it (Undo on the meeting
    /// before it puts it second again; its answers must still be there).
    func keep(callKeys: Set<String>, queuedWithDrafts: Set<String>) {
        reviews = reviews.filter { entry in
            if callKeys.contains(where: { entry.key.hasPrefix($0 + "|") }) { return true }
            return entry.value.view.hasDraft && queuedWithDrafts.contains { entry.key.hasPrefix($0 + "|") }
        }
    }

    /// A card is rebuilt only when its voices change.
    private static func key(for call: SpeakerPendingMeetingGroup) -> String {
        ([call.id] + call.voices.map(\.id.uuidString)).joined(separator: "|")
    }

    private static func dateLine(for call: SpeakerPendingMeetingGroup) -> String? {
        let date = call.recordedAt ?? call.fallbackDate
        guard date != .distantPast else { return nil }
        return dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// The review view at its own height: the rows grow and shrink as names
/// are typed (suggestions, chips), and SwiftUI follows each change.
private struct SpeakerWhoSpokeCardFrame: View {
    let review: NotchIslandSpeakerReviewView
    let invitees: [String]
    @State private var height: CGFloat = 0

    var body: some View {
        SpeakerWhoSpokeCardHost(review: review, invitees: invitees) { measured in
            if abs(measured - height) > 0.5 { height = measured }
        }
        .frame(width: SpeakerWhoSpokeLayout.contentWidth, height: max(height, 10), alignment: .topLeading)
    }
}

/// Hosts one review view in the island's dark look.
private struct SpeakerWhoSpokeCardHost: NSViewRepresentable {
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

final class SpeakerWhoSpokeContainer: NSView {
    private var review: NotchIslandSpeakerReviewView?
    private var invitees: [String]?
    /// The review's height changed; reported after the current layout pass.
    var onHeight: ((CGFloat) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        // The island's rows draw white on black; their name field too.
        appearance = NSAppearance(named: .darkAqua)
        setContentHuggingPriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func show(_ next: NotchIslandSpeakerReviewView) {
        guard next !== review else { return }
        review?.removeFromSuperview()
        review = next
        invitees = nil
        next.removeFromSuperview()
        addSubview(next)
        NSLayoutConstraint.activate([
            next.topAnchor.constraint(equalTo: topAnchor),
            next.leadingAnchor.constraint(equalTo: leadingAnchor),
        ])
        next.onLayoutChange = { [weak self] in self?.reportHeight() }
        reportHeight()
    }

    private func reportHeight() {
        invalidateIntrinsicContentSize()
        // Out of the current layout pass, so SwiftUI isn't changed mid-update.
        DispatchQueue.main.async { [weak self] in
            guard let self, let review = self.review else { return }
            review.layoutSubtreeIfNeeded()
            self.onHeight?(review.fittingHeight)
        }
    }

    func setInvitees(_ names: [String]) {
        guard let review, names != invitees else { return }
        invitees = names
        // No 1:1 prefill here: a saved meeting's other voices may be named.
        review.setInvitees(names, remoteVoicesInMeeting: nil)
    }

    override var intrinsicContentSize: NSSize {
        guard let review else { return NSSize(width: SpeakerWhoSpokeLayout.contentWidth, height: 10) }
        review.layoutSubtreeIfNeeded()
        return NSSize(width: review.width, height: review.fittingHeight)
    }
}
