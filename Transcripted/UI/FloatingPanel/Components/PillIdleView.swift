import SwiftUI

// MARK: - Pill Idle View (Horizontal slide-out design)

/// Minimal capsule that slides out horizontally on hover to reveal buttons
/// Collapsed: 40x24px with minimal waveform icon (centered)
/// Expanded: Buttons slide out from center - Record left, Files right
@available(macOS 14.0, *)
struct PillIdleView: View {
    let onRecord: () -> Void
    let onTranscripts: () -> Void
    let failedCount: Int

    @Environment(\.accessibilityReduceMotion) var reduceMotion
    @State private var isExpanded = false
    @State private var hoveredButton: HoveredButton? = nil

    enum HoveredButton {
        case record
        case files
    }

    init(onRecord: @escaping () -> Void, onTranscripts: @escaping () -> Void, failedCount: Int = 0) {
        self.onRecord = onRecord
        self.onTranscripts = onTranscripts
        self.failedCount = failedCount
    }

    // Button dimensions
    private let buttonWidth: CGFloat = 56
    private let buttonHeight: CGFloat = 28
    private let coreWidth: CGFloat = 40
    private let coreHeight: CGFloat = 24

    var body: some View {
        ZStack {
            // Slide-out buttons (appear from behind core pill)
            HStack(spacing: 4) {
                // Record button - slides out left
                SlideOutButton(
                    icon: "mic.fill",
                    isHovered: hoveredButton == .record,
                    action: onRecord
                )
                .frame(width: buttonWidth, height: buttonHeight)
                .offset(x: isExpanded ? 0 : buttonWidth / 2)
                .opacity(isExpanded ? 1 : 0)
                .onHover { hovering in
                    hoveredButton = hovering ? .record : (hoveredButton == .record ? nil : hoveredButton)
                }

                // Spacer for core pill area
                Spacer()
                    .frame(width: coreWidth - 8)

                // Files button - slides out right
                SlideOutButton(
                    icon: "folder.fill",
                    isHovered: hoveredButton == .files,
                    action: onTranscripts
                )
                .frame(width: buttonWidth, height: buttonHeight)
                .offset(x: isExpanded ? 0 : -buttonWidth / 2)
                .opacity(isExpanded ? 1 : 0)
                .onHover { hovering in
                    hoveredButton = hovering ? .files : (hoveredButton == .files ? nil : hoveredButton)
                }
            }

            // Core pill (always visible, stays centered)
            ZStack {
                Capsule()
                    .fill(Color.panelCharcoal)
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isExpanded ? Color.panelCharcoalElevated : Color.panelCharcoalSurface,
                                lineWidth: 1
                            )
                    )

                MinimalWaveformIcon()
                    .scaleEffect(isExpanded ? 0.9 : 1.0)

                // Failed transcription badge (top-right)
                if failedCount > 0 {
                    FailedBadgeOverlay(count: failedCount)
                        .offset(x: coreWidth / 2 - 4, y: -coreHeight / 2 + 2)
                        .opacity(isExpanded ? 0.5 : 1.0)
                }
            }
            .frame(width: coreWidth, height: coreHeight)
            .shadow(color: Color.black.opacity(0.2), radius: 4, y: 2)
            .zIndex(1)  // Core pill stays on top
        }
        .frame(
            width: isExpanded ? (buttonWidth * 2 + coreWidth) : coreWidth,
            height: buttonHeight
        )
        .animation(reduceMotion ? .none : .snappy(duration: 0.2), value: isExpanded)
        .onHover { hovering in
            withAnimation(reduceMotion ? .none : .snappy(duration: 0.2)) {
                isExpanded = hovering
                if !hovering {
                    hoveredButton = nil
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(isExpanded ? "Recording options" : "Transcripted - hover to expand")
    }
}

// MARK: - Slide-Out Button

/// Compact circular button that slides out from the core pill
@available(macOS 14.0, *)
struct SlideOutButton: View {
    let icon: String
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Capsule()
                    .fill(isHovered ? Color.panelCharcoalElevated : Color.panelCharcoal.opacity(0.9))
                    .overlay(
                        Capsule()
                            .strokeBorder(
                                isHovered ? Color.recordingCoral.opacity(0.5) : Color.panelCharcoalSurface,
                                lineWidth: 1
                            )
                    )

                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isHovered ? .recordingCoral : .panelTextSecondary)
            }
            .scaleEffect(isHovered ? 1.05 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        .shadow(color: Color.black.opacity(0.15), radius: 3, y: 1)
        .animation(.snappy(duration: 0.15), value: isHovered)
    }
}
