import SwiftUI
import AppKit

// MARK: - TranscriptTrayView

/// Tray that slides up above the idle pill showing the 10 most recent transcripts.
///
/// Each row has a "Copy" button that puts clean, AI-ready dialogue on the clipboard —
/// no YAML frontmatter, no analytics sections, just the conversation formatted for
/// pasting into Claude, ChatGPT, or any AI tool.
///
/// Visual style mirrors ReviewTrayView (frosted glass, triangle connector).
@available(macOS 14.0, *)
struct TranscriptTrayView: View {

    @ObservedObject var store: TranscriptStore
    var onOpenFolder: () -> Void

    @State private var isAppearing = false
    @State private var copiedId: UUID?

    var body: some View {
        VStack(spacing: 4) {
            // Main tray container
            ZStack {
                // Frosted glass background
                RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.accentBlue.opacity(0.25),
                                        Color.white.opacity(0.08)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
                    .shadow(color: Color.black.opacity(0.25), radius: 16, y: 6)

                VStack(spacing: 0) {
                    trayHeader
                    Divider().background(Color.panelCharcoalElevated)
                    trayBody
                    Divider().background(Color.panelCharcoalElevated)
                    trayFooter
                }
            }
            .frame(width: PillDimensions.trayWidth)

            // Triangle connector pointing down toward the pill
            Triangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 12, height: 6)
                .rotationEffect(.degrees(180))
        }
        .scaleEffect(isAppearing ? 1.0 : 0.92, anchor: .bottom)
        .opacity(isAppearing ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.trayExpand) { isAppearing = true }
        }
        .onDisappear {
            isAppearing = false
        }
    }

    // MARK: - Header

    private var trayHeader: some View {
        HStack {
            Text("Recent Meetings")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.panelTextSecondary)
                .tracking(0.5)

            Spacer()

            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.panelTextMuted)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Refresh")
        }
        .padding(.horizontal, Spacing.md)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.sm)
    }

    // MARK: - Body

    @ViewBuilder
    private var trayBody: some View {
        if store.transcripts.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(store.transcripts) { transcript in
                        TranscriptRowView(
                            transcript: transcript,
                            isCopied: copiedId == transcript.id,
                            onCopy: { copyToClipboard(transcript) }
                        )

                        if transcript.id != store.transcripts.last?.id {
                            Divider()
                                .background(Color.panelCharcoalElevated.opacity(0.5))
                                .padding(.horizontal, Spacing.md)
                        }
                    }
                }
            }
            .frame(maxHeight: 240)
        }
    }

    // MARK: - Footer

    private var trayFooter: some View {
        Button(action: onOpenFolder) {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                Text("Open transcripts folder")
                    .font(.system(size: 11))
            }
            .foregroundColor(.panelTextMuted)
        }
        .buttonStyle(PlainButtonStyle())
        .padding(.vertical, Spacing.sm)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "waveform.slash")
                .font(.system(size: 24, weight: .light))
                .foregroundColor(.panelTextMuted)

            Text("No transcripts yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.panelTextSecondary)

            Text("Record your first meeting to get started.")
                .font(.system(size: 11))
                .foregroundColor(.panelTextMuted)
                .multilineTextAlignment(.center)
        }
        .padding(.vertical, Spacing.xl)
        .padding(.horizontal, Spacing.md)
    }

    // MARK: - Copy Logic

    private func copyToClipboard(_ transcript: TranscriptSummary) {
        let text = store.copyableText(for: transcript)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)

        withAnimation(.snappy(duration: 0.15)) {
            copiedId = transcript.id
        }

        // Reset copy confirmation after 1.5 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.snappy(duration: 0.15)) {
                if copiedId == transcript.id { copiedId = nil }
            }
        }
    }
}

// MARK: - TranscriptRowView

/// A single row in the transcript tray.
/// Shows title, relative date, duration on the left; Copy button on the right.
@available(macOS 14.0, *)
struct TranscriptRowView: View {
    let transcript: TranscriptSummary
    let isCopied: Bool
    let onCopy: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Left: title + metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                HStack(spacing: 5) {
                    Text(relativeDate)
                        .font(.system(size: 10))
                        .foregroundColor(.panelTextMuted)

                    if !transcript.duration.isEmpty {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundColor(.panelTextMuted)

                        Text(transcript.duration)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.panelTextMuted)
                    }

                    if transcript.speakerCount > 0 {
                        Text("·")
                            .font(.system(size: 10))
                            .foregroundColor(.panelTextMuted)

                        HStack(spacing: 2) {
                            Image(systemName: "person.2")
                                .font(.system(size: 8))
                            Text("\(transcript.speakerCount)")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.panelTextMuted)
                    }
                }
            }

            Spacer(minLength: Spacing.sm)

            // Right: Copy button
            copyButton
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, 10)
        .background(isHovered ? Color.panelCharcoal.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.1)) { isHovered = hovering }
        }
        .animation(.snappy(duration: 0.1), value: isHovered)
    }

    // MARK: - Copy Button

    private var copyButton: some View {
        Button(action: onCopy) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(
                        isCopied
                            ? Color.statusSuccessMuted.opacity(0.18)
                            : (isHovered ? Color.panelCharcoalElevated : Color.panelCharcoalSurface)
                    )
                    .frame(width: 56, height: 24)
                    .animation(.snappy(duration: 0.15), value: isCopied)

                if isCopied {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                        Text("Copied")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.statusSuccessMuted)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: 9))
                        Text("Copy")
                            .font(.system(size: 9, weight: .medium))
                    }
                    .foregroundColor(.panelTextSecondary)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.snappy(duration: 0.15), value: isCopied)
        }
        .buttonStyle(PlainButtonStyle())
        .help(isCopied ? "Copied to clipboard" : "Copy transcript for AI")
    }

    // MARK: - Relative Date

    private var relativeDate: String {
        let cal = Calendar.current
        if cal.isDateInToday(transcript.date)     { return "Today" }
        if cal.isDateInYesterday(transcript.date) { return "Yesterday" }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        return df.string(from: transcript.date)
    }
}

// Spacing.xl (32pt) and other tokens are defined in DesignTokens.swift
