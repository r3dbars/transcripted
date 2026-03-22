import SwiftUI
import AppKit

// MARK: - Saved Pill View
/// Notification card shown when a transcript is saved.
/// Displays the transcript title, duration, speaker count, and quick actions (Copy/Open).
/// Morphs from the processing pill into a wider card (260x56px) with a green accent.
/// Tapping the card body dismisses it; auto-dismisses after 6 seconds.

@available(macOS 26.0, *)
struct SavedPillView: View {
    let title: String?
    let duration: String?
    let speakerCount: Int?
    var transcriptURL: URL? = nil
    var onCopyTranscript: (() -> Void)? = nil
    var onOpenTranscript: (() -> Void)? = nil
    var onDismiss: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var checkScale: CGFloat = 0.3
    @State private var checkOpacity: CGFloat = 0
    @State private var contentOpacity: CGFloat = 0
    @State private var isHovered = false
    @State private var isCopyHovered = false
    @State private var isOpenHovered = false
    @State private var showCopiedCheck = false

    private let width: CGFloat = PillDimensions.savedWidth
    private let height: CGFloat = PillDimensions.savedHeight

    var body: some View {
        ZStack {
            // Background with green accent border
            savedBackground
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg, style: .continuous))

            // Content layout
            HStack(spacing: 8) {
                // Animated checkmark
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.statusSuccessMuted)
                    .scaleEffect(checkScale)
                    .opacity(checkOpacity)

                // Title + metadata
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayTitle)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.panelTextPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let subtitle = subtitleText {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.panelTextSecondary)
                            .lineLimit(1)
                    }
                }
                .opacity(contentOpacity)

                Spacer(minLength: 4)

                // Action buttons
                HStack(spacing: 4) {
                    // Copy button
                    if let onCopy = onCopyTranscript {
                        Button(action: {
                            onCopy()
                            withAnimation(.snappy(duration: 0.15)) { showCopiedCheck = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                withAnimation(.snappy(duration: 0.15)) { showCopiedCheck = false }
                            }
                        }) {
                            ZStack {
                                Circle()
                                    .fill(isCopyHovered ? Color.panelCharcoalSurface : Color.clear)
                                    .frame(width: 28, height: 28)

                                Image(systemName: showCopiedCheck ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(showCopiedCheck ? .statusSuccessMuted : .panelTextSecondary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover { hovering in isCopyHovered = hovering }
                        .help("Copy transcript")
                    }

                    // Open in tray button
                    if transcriptURL != nil {
                        Button(action: {
                            onOpenTranscript?()
                        }) {
                            ZStack {
                                Circle()
                                    .fill(isOpenHovered ? Color.panelCharcoalSurface : Color.clear)
                                    .frame(width: 28, height: 28)

                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.panelTextSecondary)
                            }
                        }
                        .buttonStyle(PlainButtonStyle())
                        .onHover { hovering in isOpenHovered = hovering }
                        .help("Open transcript")
                    }
                }
                .opacity(contentOpacity)
            }
            .padding(.horizontal, 14)
        }
        .frame(width: width, height: height)
        .onTapGesture {
            onDismiss?()
        }
        .onHover { hovering in isHovered = hovering }
        .onAppear { animateEntrance() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    // MARK: - Display Content

    private var displayTitle: String {
        if let title, !title.isEmpty, title != "Meeting" {
            return title
        }
        return "Transcript Saved"
    }

    private var subtitleText: String? {
        var parts: [String] = []
        if let duration, !duration.isEmpty {
            parts.append(duration)
        }
        if let count = speakerCount, count > 0 {
            parts.append("\(count) speaker\(count == 1 ? "" : "s")")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Background

    private var savedBackground: some View {
        ZStack {
            Color.panelCharcoal

            // Subtle green radial glow from left
            RadialGradient(
                colors: [
                    Color.statusSuccessMuted.opacity(0.15),
                    Color.statusSuccessMuted.opacity(0.06),
                    Color.clear
                ],
                center: .leading,
                startRadius: 0,
                endRadius: 140
            )
        }
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                .strokeBorder(Color.statusSuccessMuted.opacity(0.45), lineWidth: 1.5)
        )
        .shadow(color: Color.statusSuccessMuted.opacity(0.2), radius: 10, y: 0)
    }

    // MARK: - Animation

    private func animateEntrance() {
        if reduceMotion {
            checkScale = 1.0
            checkOpacity = 1.0
            contentOpacity = 1.0
            return
        }

        // Phase 1: Scale in checkmark
        withAnimation(.spring(response: 0.4, dampingFraction: 0.6)) {
            checkScale = 1.0
            checkOpacity = 1.0
        }

        // Phase 2: Slight bounce
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.5)) {
                checkScale = 1.1
            }
        }

        // Phase 3: Settle
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.spring(response: 0.15, dampingFraction: 0.8)) {
                checkScale = 1.0
            }
        }

        // Phase 4: Fade in content
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) {
                contentOpacity = 1.0
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityText: String {
        var label = "Transcript saved"
        if let title, !title.isEmpty {
            label += ": \(title)"
        }
        if let duration, !duration.isEmpty {
            label += ", \(duration)"
        }
        if let count = speakerCount, count > 0 {
            label += ", \(count) speaker\(count == 1 ? "" : "s")"
        }
        return label
    }

    // MARK: - Hover State

    var isPillHovered: Bool { isHovered }
}
