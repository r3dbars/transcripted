// DictationPlaybackBar.swift
// The footer row and recessed milled playback rail for each Dictations card,
// matching the Meetings card's neutral paper-ink palette and matte controls.

import SwiftUI

/// Metadata footer: length · time · words · [app chip] [· problem], with hover
/// Copy / ⋯ and the neutral play disc on the right.
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

    private var isPlaying: Bool { playback.isPlaying(entryID) }

    var body: some View {
        HStack(spacing: 10) {
            // One VoiceOver sentence for the metadata.
            HStack(spacing: 0) {
                ForEach(Array(metadata.enumerated()), id: \.element.id) { index, item in
                    metadataItem(item, leadingDot: index > 0)
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
            .font(LibraryTokens.meta)
            .monospacedDigit()
            .foregroundStyle(LibraryTokens.ink3)
            .lineLimit(1)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(accessibilitySummary))

            Spacer(minLength: 8)

            HomeRowActionButtons(
                isCopied: isCopied,
                onCopy: onCopy,
                menuItems: menuItems,
                copyAutomationIdentifier: "transcripted.dictations.row.copy"
            )
            .frame(height: 22)
            // Hidden from the pointer until hover, never from VoiceOver.
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)

            if hasAudio || isCheckingAudio {
                DictationPlayButton(isPlaying: isPlaying, action: onTogglePlayback)
                    .opacity(hasAudio ? 1 : 0)
                    .disabled(!hasAudio)
                    .accessibilityHidden(!hasAudio)
                    // Its 40 pt hit square overhangs the row; keep it on top.
                    .zIndex(1)
            }
        }
        .frame(minHeight: 22)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: showsActions)
    }

    private var accessibilitySummary: String {
        let summary = DictationCardFormatting.accessibilitySummary(metadata)
        return isTranscribingAgain ? summary + ", transcribing again" : summary
    }

    private func metadataItem(_ item: DictationCardFormatting.MetadataItem, leadingDot: Bool) -> some View {
        HStack(spacing: 7) {
            if leadingDot {
                DictationMetaDot()
            }
            if item.kind == .app {
                Text(item.text)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(LibraryTokens.ink2)
                    .truncationMode(.tail)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(HomeMeetingCardSurface.playIdleFill)
                    )
            } else {
                Text(item.text)
                    .foregroundStyle(color(for: item.kind))
                    .truncationMode(.tail)
                    .fixedSize(horizontal: true, vertical: false)
            }
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

/// 22 pt round neutral play/pause disc with a 40 pt hit area, matching the
/// Meetings card's paper-ink language.
struct DictationPlayButton: View {
    let isPlaying: Bool
    let action: () -> Void

    static let visibleSize: CGFloat = 22
    static let hitSize = HomeHitTarget.hitSize(forVisibleSize: visibleSize)

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isPlaying
                        ? LibraryTokens.ink
                        : (isHovering ? HomeMeetingCardSurface.playIdleHover : HomeMeetingCardSurface.playIdleFill))
                if !isPlaying {
                    Circle()
                        .strokeBorder(HomeMeetingCardSurface.playIdleBorder, lineWidth: 1)
                }
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 8.5, weight: .bold))
                    .offset(x: isPlaying ? 0 : 0.5)
                    .foregroundStyle(isPlaying ? HomeMeetingCardSurface.onAccent : LibraryTokens.ink2)
            }
            .frame(width: Self.visibleSize, height: Self.visibleSize)
            // Drawn at 22 pt, clicked like every other control on the page:
            // a 40 pt hit square that doesn't push the bar's layout.
            .frame(width: Self.hitSize, height: Self.hitSize)
            .contentShape(Rectangle())
        }
        .buttonStyle(DictationPressScaleButtonStyle())
        .padding(-(Self.hitSize - Self.visibleSize) / 2)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: isPlaying)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isHovering)
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
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.90 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Recessed 30 pt milled playback well shown beneath the card's footer while a
/// dictation take is active. Matches `HomeMeetingInstrumentShell`'s neutral
/// rail, thumb, and two-tone clock.
struct DictationInlinePlayer: View {
    let entryID: String
    @ObservedObject var playback: DictationPlaybackController

    @GestureState private var dragFraction: Double?
    @State private var isHoveringTrack = false

    private var duration: TimeInterval { playback.session?.duration ?? 0 }
    private var isPlaying: Bool { playback.isPlaying(entryID) }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !isPlaying || dragFraction != nil)) { _ in
            let fraction = dragFraction ?? playback.progress(for: entryID)
            HStack(spacing: 10) {
                track(fraction: fraction)

                HStack(spacing: 2) {
                    Text(DictationCardFormatting.clockText(seconds: fraction * duration))
                        .foregroundStyle(LibraryTokens.ink)
                    Text("/")
                        .foregroundStyle(LibraryTokens.ink3)
                    Text(DictationCardFormatting.clockText(seconds: duration))
                        .foregroundStyle(LibraryTokens.ink3)
                }
                .font(LibraryTokens.meta)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(HomeMeetingCardSurface.wellFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(HomeMeetingCardSurface.wellBorder, lineWidth: 1)
                    )
            )
        }
    }

    private func track(fraction: Double) -> some View {
        let clamped = min(max(fraction, 0), 1)
        let knobSize: CGFloat = dragFraction != nil ? 11 : (isHoveringTrack ? 10 : 8.5)
        return GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let x = width * CGFloat(clamped)
            let halfKnob = knobSize / 2
            let thumbX = min(max(x, halfKnob), max(halfKnob, width - halfKnob))
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HomeMeetingCardSurface.railTrack)
                    .frame(height: 3)
                Capsule()
                    .fill(LibraryTokens.ink)
                    .frame(width: max(0, x), height: 3)
                Circle()
                    .fill(HomeMeetingCardSurface.thumb)
                    .frame(width: knobSize, height: knobSize)
                    .shadow(color: Color.black.opacity(0.28), radius: 1.5, y: 0.5)
                    .position(x: thumbX, y: proxy.size.height / 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { isHoveringTrack = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($dragFraction) { value, state, _ in
                        state = Double(min(max(value.location.x / width, 0), 1))
                    }
                    .onEnded { value in
                        let target = Double(min(max(value.location.x / width, 0), 1))
                        playback.seek(entryID: entryID, toFraction: target)
                    }
            )
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(
            "\(DictationCardFormatting.clockText(seconds: clamped * duration)) of \(DictationCardFormatting.clockText(seconds: duration))"
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
}
