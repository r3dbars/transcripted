// DictationPlaybackBar.swift
// The bar on top of each Dictations card: play button, metadata, and the
// inline player that grows out of the play button while a take is open.

import SwiftUI

/// Play · time • length • words • app [• problem] · (hover) Copy ⋯.
///
/// While the take is open the player slides in after the play button
/// (current time, scrubber, total) and the length and app step aside.
/// Reduce Motion turns every movement here into a plain state change.
struct DictationCardBar: View {
    let entryID: String
    let metadata: [DictationCardFormatting.MetadataItem]
    /// Kept audio is known to exist: show the play button.
    let hasAudio: Bool
    /// Kept audio may exist but hasn't been checked yet: hold the slot.
    let isCheckingAudio: Bool
    let isTranscribingAgain: Bool
    let showsActions: Bool
    let isCopied: Bool
    let menuItems: [HomeRowMenuItem]
    @ObservedObject var playback: DictationPlaybackController
    let onTogglePlayback: () -> Void
    let onCopy: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { playback.isActive(entryID) }
    private var isPlaying: Bool { playback.isPlaying(entryID) }

    private var visibleMetadata: [DictationCardFormatting.MetadataItem] {
        metadata.filter { !(isOpen && $0.collapsesWhilePlaying) }
    }

    var body: some View {
        HStack(spacing: 10) {
            if hasAudio || isCheckingAudio {
                DictationPlayButton(isPlaying: isPlaying, action: onTogglePlayback)
                    .opacity(hasAudio ? 1 : 0)
                    .disabled(!hasAudio)
                    .accessibilityHidden(!hasAudio)
            }

            HStack(spacing: 0) {
                if isOpen {
                    DictationInlinePlayer(entryID: entryID, playback: playback)
                        .transition(playerTransition)
                }
                // One VoiceOver sentence for the metadata; the scrubber
                // above stays its own adjustable element.
                HStack(spacing: 0) {
                    ForEach(Array(visibleMetadata.enumerated()), id: \.element.id) { index, item in
                        metadataItem(item, leadingDot: index > 0)
                            .transition(itemTransition)
                    }
                    if isTranscribingAgain {
                        HStack(spacing: 7) {
                            DictationMetaDot()
                            ProgressView()
                                .controlSize(.mini)
                            Text("transcribing again")
                        }
                        .padding(.leading, 7)
                        .transition(.opacity)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(accessibilitySummary))
            }
            .font(LibraryTokens.meta)
            .monospacedDigit()
            .foregroundStyle(LibraryTokens.ink3)
            .lineLimit(1)
            .accessibilityElement(children: .contain)

            Spacer(minLength: 8)

            HomeRowActionButtons(
                isCopied: isCopied,
                onCopy: onCopy,
                menuItems: menuItems,
                copyAutomationIdentifier: "transcripted.dictations.row.copy"
            )
            .frame(height: 22)
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
            .accessibilityHidden(!showsActions)
        }
        .frame(minHeight: 22)
        .animation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.85), value: isOpen)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: showsActions)
    }

    private var accessibilitySummary: String {
        let summary = DictationCardFormatting.accessibilitySummary(visibleMetadata)
        return isTranscribingAgain ? summary + ", transcribing again" : summary
    }

    private func metadataItem(_ item: DictationCardFormatting.MetadataItem, leadingDot: Bool) -> some View {
        HStack(spacing: 7) {
            if leadingDot {
                DictationMetaDot()
            }
            Text(item.text)
                .foregroundStyle(color(for: item.kind))
                .truncationMode(.tail)
                // Only a long app name gives way in a narrow window.
                .fixedSize(horizontal: item.kind != .app, vertical: false)
        }
        .padding(.leading, leadingDot ? 7 : 0)
        .layoutPriority(item.kind == .app ? 0 : 1)
    }

    private func color(for kind: DictationCardFormatting.MetadataKind) -> Color {
        switch kind {
        case .length: return LibraryTokens.ink2
        case .problem: return LibraryTokens.attention
        case .time, .words, .app: return LibraryTokens.ink3
        }
    }

    private var playerTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .opacity.combined(with: .scale(scale: 0.2, anchor: .leading)),
                removal: .opacity.combined(with: .scale(scale: 0.6, anchor: .leading))
            )
    }

    private var itemTransition: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.85, anchor: .leading))
    }
}

/// The tiny faint separator dot between metadata items.
struct DictationMetaDot: View {
    var body: some View {
        Circle()
            .frame(width: 2.5, height: 2.5)
            .opacity(0.55)
            .accessibilityHidden(true)
    }
}

/// 22 pt round play/pause button. The icon morphs (rotate + scale
/// cross-fade), the fill turns green, and a soft ring pulses while playing.
struct DictationPlayButton: View {
    let isPlaying: Bool
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if isPlaying && !reduceMotion {
                    DictationPlayPulse()
                }
                Circle()
                    .fill(isPlaying ? LibraryTokens.accent : Color.primary.opacity(isHovering ? 0.16 : 0.09))
                Image(systemName: "play.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .offset(x: 0.5)
                    .opacity(isPlaying ? 0 : 1)
                    .rotationEffect(.degrees(isPlaying ? 90 : 0))
                    .scaleEffect(isPlaying ? 0.4 : 1)
                Image(systemName: "pause.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .opacity(isPlaying ? 1 : 0)
                    .rotationEffect(.degrees(isPlaying ? 0 : -90))
                    .scaleEffect(isPlaying ? 1 : 0.4)
            }
            .foregroundStyle(isPlaying ? Color.white : Color.primary.opacity(0.85))
            .frame(width: 22, height: 22)
            .contentShape(Circle())
        }
        .buttonStyle(DictationPressScaleButtonStyle())
        .animation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.55), value: isPlaying)
        .onHover { isHovering = $0 }
        .help(isPlaying ? "Pause" : "Play dictation")
        .accessibilityLabel(Text(isPlaying ? "Pause" : "Play dictation"))
        .accessibilityIdentifier("transcripted.dictations.row.play")
    }
}

private struct DictationPressScaleButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

/// A soft green ring that grows out of the play button and fades, on repeat.
private struct DictationPlayPulse: View {
    @State private var expanded = false

    var body: some View {
        Circle()
            .fill(LibraryTokens.accent.opacity(0.45))
            .scaleEffect(expanded ? 1.8 : 1)
            .opacity(expanded ? 0 : 1)
            .allowsHitTesting(false)
            .onAppear {
                withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                    expanded = true
                }
            }
    }
}

/// Current time · scrubber · total, shown while a take is open. The playhead
/// is read every display frame while playing (not once a second).
struct DictationInlinePlayer: View {
    let entryID: String
    @ObservedObject var playback: DictationPlaybackController

    static let trackWidth: CGFloat = 110

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var railDrawn = false
    @State private var fillDrawn = false
    @State private var knobShown = false
    @State private var currentShown = false
    @State private var totalShown = false
    @State private var dragFraction: Double?

    private var duration: TimeInterval { playback.session?.duration ?? 0 }
    private var isPlaying: Bool { playback.isPlaying(entryID) }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isPlaying || dragFraction != nil)) { _ in
            let fraction = dragFraction ?? playback.progress(for: entryID)
            HStack(spacing: 7) {
                Text(DictationCardFormatting.clockText(seconds: fraction * duration))
                    .foregroundStyle(LibraryTokens.accent)
                    .frame(minWidth: 28, alignment: .trailing)
                    .offset(y: currentShown ? 0 : 5)
                    .opacity(currentShown ? 1 : 0)
                track(fraction: fraction)
                Text(DictationCardFormatting.clockText(seconds: duration))
                    .offset(y: totalShown ? 0 : 5)
                    .opacity(totalShown ? 1 : 0)
                DictationMetaDot()
            }
            .padding(.trailing, 7)
        }
        .onAppear(perform: appear)
    }

    private func track(fraction: Double) -> some View {
        let width = Self.trackWidth
        let x = width * CGFloat(min(max(fraction, 0), 1))
        return ZStack(alignment: .leading) {
            Capsule()
                .fill(Color.primary.opacity(0.16))
                .frame(width: width, height: 3)
                .scaleEffect(x: railDrawn ? 1 : 0.001, y: 1, anchor: .leading)
            Capsule()
                .fill(LibraryTokens.accent)
                .frame(width: max(0, x), height: 3)
                .scaleEffect(x: fillDrawn ? 1 : 0.001, y: 1, anchor: .leading)
            Circle()
                .fill(Color.white)
                .frame(width: 10, height: 10)
                .shadow(color: Color.black.opacity(0.28), radius: 1, y: 0.5)
                .background(
                    Circle()
                        .fill(LibraryTokens.accent.opacity(isPlaying ? 0.22 : 0))
                        .frame(width: 16, height: 16)
                )
                .scaleEffect(knobShown ? (dragFraction != nil ? 1.25 : 1) : 0.001)
                .offset(x: x - 5)
        }
        .frame(width: width, height: 14)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    dragFraction = Double(min(max(value.location.x / width, 0), 1))
                }
                .onEnded { value in
                    let target = Double(min(max(value.location.x / width, 0), 1))
                    playback.seek(entryID: entryID, toFraction: target)
                    dragFraction = nil
                }
        )
        .padding(.horizontal, 2)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(
            "\(DictationCardFormatting.clockText(seconds: fraction * duration)) of \(DictationCardFormatting.clockText(seconds: duration))"
        ))
        .accessibilityAdjustableAction { direction in
            let step = max(1, duration / 10)
            switch direction {
            case .increment: playback.seek(entryID: entryID, by: step)
            case .decrement: playback.seek(entryID: entryID, by: -step)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("transcripted.dictations.row.scrubber")
    }

    private func appear() {
        guard !reduceMotion else {
            railDrawn = true
            fillDrawn = true
            knobShown = true
            currentShown = true
            totalShown = true
            return
        }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.55).delay(0.08)) { railDrawn = true }
        withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5).delay(0.15)) { fillDrawn = true }
        withAnimation(.spring(response: 0.42, dampingFraction: 0.5).delay(0.3)) { knobShown = true }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.12)) { currentShown = true }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.6).delay(0.3)) { totalShown = true }
    }
}
