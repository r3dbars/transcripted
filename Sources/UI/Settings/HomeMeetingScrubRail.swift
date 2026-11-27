import SwiftUI

/// The rail's precision scrubber: a 3 pt track that thickens to 5 pt under
/// the pointer, a faint ghost from the playhead to the pointer, the played
/// part in the speaker's color (muted while paused), and a thumb that only
/// shows on hover or drag. Hovering or dragging floats "14:25 · Priya" over
/// the pointer: the time there and who is speaking then (just the time at
/// silence or before the lines load). Clicking or dragging plays from there.
struct HomeMeetingScrubRail: View {
    let time: TimeInterval
    let total: TimeInterval
    let accent: Color
    let isPlaying: Bool
    let timed: HomeMeetingTimedLines
    let onDrag: (Double) -> Void
    let onCommit: (Double) -> Void
    let onSkip: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hoverX: CGFloat?
    @State private var isDragging = false

    private var isEngaged: Bool { hoverX != nil || isDragging }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = total > 0 ? CGFloat(min(max(time / total, 0), 1)) : 0
            let trackHeight: CGFloat = isEngaged ? 5 : 3
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(HomeMeetingCardSurface.railTrack)
                    .frame(height: trackHeight)
                if let hoverX, !isDragging {
                    Capsule()
                        .fill(HomeMeetingCardSurface.railGhost)
                        .frame(width: min(max(hoverX, 0), width), height: trackHeight)
                }
                Capsule()
                    .fill(isPlaying || isEngaged ? accent : accent.opacity(0.58))
                    .frame(width: max(width * fraction, trackHeight), height: trackHeight)
                    .opacity(fraction > 0 || isEngaged ? 1 : 0)
                Circle()
                    .fill(HomeMeetingCardSurface.thumb)
                    .frame(width: 11, height: 11)
                    .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                    .overlay {
                        if isDragging {
                            Circle()
                                .strokeBorder(accent.opacity(0.26), lineWidth: 4)
                                .padding(-4)
                        }
                    }
                    .scaleEffect(isDragging ? 1.12 : (isEngaged ? 1 : 0.35))
                    .opacity(isEngaged ? 1 : 0)
                    .offset(x: width * fraction - 5.5)
            }
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topLeading) {
                if let pointer = isDragging ? width * fraction : hoverX, total > 0 {
                    hoverPill(at: pointer, width: width)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location): hoverX = location.x
                case .ended: hoverX = nil
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        isDragging = true
                        onDrag(Double(min(max(value.location.x / width, 0), 1)))
                    }
                    .onEnded { value in
                        isDragging = false
                        onCommit(Double(min(max(value.location.x / width, 0), 1)))
                    }
            )
            .animation(reduceMotion ? nil : .easeOut(duration: 0.13), value: isEngaged)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: isDragging)
        }
        .frame(minWidth: 90)
        .frame(height: 26)
        .accessibilityElement()
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text(
            "\(MeetingAudioPlayback.clockText(time)) of \(MeetingAudioPlayback.clockText(total))"
        ))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onSkip(15)
            case .decrement: onSkip(-15)
            @unknown default: break
            }
        }
        .accessibilityIdentifier("transcripted.home.meeting.scrubber")
    }

    private func hoverPill(at x: CGFloat, width: CGFloat) -> some View {
        let fraction = Double(min(max(x / width, 0), 1))
        let pointerTime = fraction * total
        let line = timed.speakingLine(at: pointerTime)
        let clock = MeetingAudioPlayback.clockText(pointerTime)
        return HStack(spacing: 5) {
            Text(clock)
                .foregroundStyle(Color.white.opacity(0.92))
            if let line, !line.speaker.isEmpty {
                Text("\u{00B7}")
                    .foregroundStyle(Color.white.opacity(0.4))
                Text(line.speaker)
                    .fontWeight(.semibold)
                    .foregroundStyle(HomeMeetingRailInk.accent(for: line))
                    .environment(\.colorScheme, .dark)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .monospacedDigit()
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(HomeMeetingCardSurface.tooltipFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.45), radius: 9, y: 4)
        .fixedSize()
        .alignmentGuide(.leading) { dimensions in dimensions.width / 2 - x }
        .alignmentGuide(.top) { dimensions in dimensions.height + 6 }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The synced mini transcript under the rail: the line being spoken, crisp,
/// with a bar in the speaker's color, the lines around it dimmed, and a soft
/// fade at the top and bottom. It scrolls with playback and with a drag on
/// the rail; clicking a line plays from it.
struct HomeMeetingMiniTranscript: View {
    let timed: HomeMeetingTimedLines
    let time: TimeInterval
    let onJump: (TimeInterval) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let viewportHeight: CGFloat = 96
    static let lineHeight: CGFloat = 32

    var body: some View {
        let active = timed.activeIndex(at: time)
        let window = HomeMeetingRailPresentation.miniTranscriptWindow(active: active, count: timed.lines.count)
        let center = active ?? -1
        ZStack(alignment: .top) {
            ForEach(Array(window), id: \.self) { index in
                HomeMeetingMiniTranscriptLine(
                    line: timed.lines[index],
                    isActive: index == active,
                    onJump: timed.starts[index].map { start in { onJump(start) } }
                )
                .offset(y: Self.viewportHeight / 2 + (CGFloat(index - center) - 0.5) * Self.lineHeight)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Self.viewportHeight, maxHeight: Self.viewportHeight, alignment: .top)
        .clipped()
        .mask(
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.45), location: 0.18),
                    .init(color: .black, location: 0.36),
                    .init(color: .black, location: 0.66),
                    .init(color: .black.opacity(0.4), location: 0.86),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .animation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.9), value: active)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(LibraryTokens.hairline)
                .frame(height: 1)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Now playing"))
        .accessibilityIdentifier("transcripted.home.meeting.mini-transcript")
    }
}

private struct HomeMeetingMiniTranscriptLine: View {
    let line: HomeMeetingTranscriptLine
    let isActive: Bool
    let onJump: (() -> Void)?

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 1, style: .continuous)
                .fill(HomeMeetingRailInk.accent(for: line))
                .frame(width: 2, height: 14)
                .opacity(isActive ? 1 : 0)
            if !line.speaker.isEmpty {
                Text(line.speaker)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(HomeMeetingRailInk.text(for: line))
                    .lineLimit(1)
                    .frame(minWidth: 48, alignment: .leading)
                    .fixedSize()
            }
            Text(line.text)
                .font(.system(size: 12))
                .foregroundStyle(LibraryTokens.ink)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let start = line.startSeconds {
                Text(MeetingAudioPlayback.clockText(start))
                    .font(.system(size: 10.5))
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink3)
            }
        }
        .padding(.horizontal, 6)
        .frame(height: HomeMeetingMiniTranscript.lineHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovering && onJump != nil ? DesignTokens.fill : Color.clear)
        )
        .opacity(isActive ? 1 : (isHovering ? 0.72 : 0.34))
        .scaleEffect(isActive ? 1 : 0.99, anchor: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .onTapGesture { onJump?() }
        .animation(.easeOut(duration: 0.24), value: isActive)
        .help(onJump == nil ? "" : "Play from here")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(onJump == nil ? [] : .isButton)
        .accessibilityAction { onJump?() }
    }
}
