import SwiftUI
import AppKit

// MARK: - TranscriptTrayView

/// Tray that slides up above the idle pill showing the 10 most recent transcripts.
///
/// Each row has a "Copy" button that puts clean, AI-ready dialogue on the clipboard —
/// no YAML frontmatter, no analytics sections, just the conversation formatted for
/// pasting into Claude, ChatGPT, or any AI tool.
///
/// Frosted glass tray with triangle connector to pill below.
@available(macOS 14.0, *)
struct TranscriptTrayView: View {

    @ObservedObject var store: TranscriptStore
    var onOpenFolder: () -> Void
    var onDismiss: (() -> Void)? = nil

    @State private var isAppearing = false
    @State private var copiedId: UUID?
    @State private var copyFailedId: UUID?
    @State private var agentPromptCopied = false
    @State private var exportedId: UUID?

    // Navigation: nil = list mode, non-nil = detail mode
    @State private var selectedTranscript: TranscriptSummary?
    @State private var detailLines: [TranscriptLine]?
    @State private var navigatingForward = true

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

                // Switch between list and detail modes
                if let selected = selectedTranscript {
                    detailContent(for: selected)
                        .transition(.asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .move(edge: .trailing).combined(with: .opacity)
                        ))
                } else {
                    listContent
                        .transition(.asymmetric(
                            insertion: .move(edge: .leading).combined(with: .opacity),
                            removal: .move(edge: .leading).combined(with: .opacity)
                        ))
                }
            }
            .frame(width: PillDimensions.trayWidth)
            .clipped()

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
            selectedTranscript = nil
            detailLines = nil
        }
    }

    // MARK: - List Content

    private var listContent: some View {
        VStack(spacing: 0) {
            trayHeader
            Divider().background(Color.panelCharcoalElevated)
            trayBody
            Divider().background(Color.panelCharcoalElevated)
            trayFooter
        }
    }

    // MARK: - Detail Content

    private func detailContent(for transcript: TranscriptSummary) -> some View {
        VStack(spacing: 0) {
            detailHeader(for: transcript)
            Divider().background(Color.panelCharcoalElevated)
            detailBody
            Divider().background(Color.panelCharcoalElevated)
            detailFooter(for: transcript)
        }
    }

    // MARK: - Header

    private var trayHeader: some View {
        HStack(spacing: Spacing.xs) {
            Text("Recent")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.panelTextMuted)
                .textCase(.uppercase)
                .tracking(0.8)

            Spacer()

            Button(action: { store.refresh() }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.panelTextMuted)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Refresh")

            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.panelTextMuted)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Close")
            }
        }
        .padding(.horizontal, Spacing.ms)
        .padding(.vertical, Spacing.xs + 2)
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
                            copyFailed: copyFailedId == transcript.id,
                            onCopy: { copyToClipboard(transcript) },
                            onSelect: { selectTranscript(transcript) }
                        )

                        if transcript.id != store.transcripts.last?.id {
                            Divider()
                                .background(Color.panelCharcoalElevated.opacity(0.5))
                                .padding(.horizontal, Spacing.md)
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
        }
    }

    // MARK: - Footer

    private var trayFooter: some View {
        HStack(spacing: 0) {
            Button(action: onOpenFolder) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                    Text("Open folder")
                        .font(.system(size: 10))
                }
                .foregroundColor(.panelTextMuted)
                .padding(.horizontal, Spacing.ms)
                .padding(.vertical, Spacing.xs + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            Button { copyAgentPrompt() } label: {
                HStack(spacing: 4) {
                    if agentPromptCopied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.statusSuccessMuted)
                        Text("Copied!")
                            .font(.system(size: 10))
                            .foregroundColor(.statusSuccessMuted)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 9))
                        Text("Connect Agent")
                            .font(.system(size: 10))
                    }
                }
                .foregroundColor(.panelTextMuted)
                .padding(.horizontal, Spacing.ms)
                .padding(.vertical, Spacing.xs + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .animation(.snappy(duration: 0.15), value: agentPromptCopied)
        }
    }

    private func copyAgentPrompt(filename: String? = nil) {
        let folder = TranscriptSaver.defaultSaveDirectory
        let prompt = AgentOutput.clipboardPrompt(folder: folder, filename: filename)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(prompt, forType: .string)

        withAnimation(.snappy(duration: 0.15)) {
            agentPromptCopied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(.snappy(duration: 0.15)) {
                agentPromptCopied = false
            }
        }
    }

    // MARK: - Detail Header

    private func detailHeader(for transcript: TranscriptSummary) -> some View {
        HStack(spacing: Spacing.xs) {
            Button(action: navigateBack) {
                HStack(spacing: 2) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Back")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundColor(.accentBlue)
            }
            .buttonStyle(PlainButtonStyle())

            Spacer()

            Text(transcript.title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.panelTextMuted)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, Spacing.ms)
        .padding(.vertical, Spacing.xs + 2)
        .background(Color.panelCharcoal.opacity(0.3))
    }

    // MARK: - Detail Body

    @ViewBuilder
    private var detailBody: some View {
        if let lines = detailLines, !lines.isEmpty {
            TranscriptDetailView(lines: lines)
        } else {
            VStack(spacing: Spacing.sm) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 20, weight: .light))
                    .foregroundColor(.panelTextMuted)

                Text("Could not load transcript")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.panelTextSecondary)
            }
            .padding(.vertical, Spacing.xl)
            .padding(.horizontal, Spacing.md)
        }
    }

    // MARK: - Detail Footer

    private func detailFooter(for transcript: TranscriptSummary) -> some View {
        HStack(spacing: 0) {
            // Copy transcript
            Button(action: { copyToClipboard(transcript) }) {
                HStack(spacing: 4) {
                    if copyFailedId == transcript.id {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.recordingCoral)
                        Text("Copy failed")
                            .font(.system(size: 10))
                            .foregroundColor(.recordingCoral)
                    } else if copiedId == transcript.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.statusSuccessMuted)
                        Text("Copied!")
                            .font(.system(size: 10))
                            .foregroundColor(.statusSuccessMuted)
                    } else {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9))
                        Text("Copy")
                            .font(.system(size: 10))
                    }
                }
                .foregroundColor(.panelTextMuted)
                .padding(.horizontal, Spacing.ms)
                .padding(.vertical, Spacing.xs + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())

            Divider()
                .frame(height: 12)
                .background(Color.panelCharcoalElevated)

            // Export menu
            Menu {
                Button(action: { exportTranscript(transcript, format: .markdown) }) {
                    Label("Save as Markdown (.md)", systemImage: "doc.text")
                }
                Button(action: { exportTranscript(transcript, format: .plainText) }) {
                    Label("Save as Plain Text (.txt)", systemImage: "doc.plaintext")
                }
            } label: {
                HStack(spacing: 4) {
                    if exportedId == transcript.id {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.statusSuccessMuted)
                        Text("Saved!")
                            .font(.system(size: 10))
                            .foregroundColor(.statusSuccessMuted)
                    } else {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 9))
                        Text("Export")
                            .font(.system(size: 10))
                    }
                }
                .foregroundColor(.panelTextMuted)
                .padding(.horizontal, Spacing.ms)
                .padding(.vertical, Spacing.xs + 2)
                .contentShape(Rectangle())
            }
            .menuStyle(BorderlessButtonMenuStyle())

            Spacer()

            Button(action: {
                let stem = transcript.title
                copyAgentPrompt(filename: stem)
            }) {
                HStack(spacing: 4) {
                    if agentPromptCopied {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(.statusSuccessMuted)
                        Text("Copied!")
                            .font(.system(size: 10))
                            .foregroundColor(.statusSuccessMuted)
                    } else {
                        Image(systemName: "terminal")
                            .font(.system(size: 9))
                        Text("Agent")
                            .font(.system(size: 10))
                    }
                }
                .foregroundColor(.panelTextMuted)
                .padding(.horizontal, Spacing.ms)
                .padding(.vertical, Spacing.xs + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
        }
        .background(Color.panelCharcoal.opacity(0.3))
        .animation(.snappy(duration: 0.15), value: copiedId)
        .animation(.snappy(duration: 0.15), value: copyFailedId)
        .animation(.snappy(duration: 0.15), value: agentPromptCopied)
        .animation(.snappy(duration: 0.15), value: exportedId)
    }

    // MARK: - Export Logic

    private func exportTranscript(_ transcript: TranscriptSummary, format: TranscriptExporter.Format) {
        let lines = detailLines ?? store.displayLines(for: transcript) ?? []
        TranscriptExporter.export(summary: transcript, lines: lines, format: format)
        withAnimation(.snappy(duration: 0.15)) { exportedId = transcript.id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            withAnimation(.snappy(duration: 0.15)) {
                if exportedId == transcript.id { exportedId = nil }
            }
        }
    }

    // MARK: - Navigation

    private func selectTranscript(_ transcript: TranscriptSummary) {
        let lines = store.displayLines(for: transcript)
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            detailLines = lines
            selectedTranscript = transcript
        }
    }

    private func navigateBack() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            selectedTranscript = nil
            detailLines = nil
        }
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
        guard let text = store.copyableText(for: transcript), !text.isEmpty else {
            // Show error state — don't touch the clipboard
            withAnimation(.snappy(duration: 0.15)) {
                copyFailedId = transcript.id
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                withAnimation(.snappy(duration: 0.15)) {
                    if copyFailedId == transcript.id { copyFailedId = nil }
                }
            }
            return
        }

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
    var copyFailed: Bool = false
    let onCopy: () -> Void
    var onSelect: (() -> Void)?

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Left: title + metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(transcript.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(2)
                    .truncationMode(.tail)

                HStack(spacing: 4) {
                    Text(relativeDate)
                        .font(.system(size: 10))
                        .foregroundColor(.panelTextMuted)

                    if !transcript.duration.isEmpty {
                        Text("·")
                            .font(.system(size: 8))
                            .foregroundColor(.panelTextMuted.opacity(0.6))

                        Text(transcript.duration)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.panelTextMuted)
                    }

                    if transcript.speakerCount > 0 {
                        Text("·")
                            .font(.system(size: 8))
                            .foregroundColor(.panelTextMuted.opacity(0.6))

                        HStack(spacing: 2) {
                            Image(systemName: "person.2")
                                .font(.system(size: 7))
                            Text("\(transcript.speakerCount)")
                                .font(.system(size: 10))
                        }
                        .foregroundColor(.panelTextMuted)
                    }
                }

                if !transcript.speakerNames.isEmpty {
                    Text(transcript.speakerNames.joined(separator: ", "))
                        .font(.system(size: 10))
                        .foregroundColor(.panelTextMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: Spacing.xs)

            // Right: Copy button (icon-only, minimal)
            copyButton
        }
        .padding(.horizontal, Spacing.ms)
        .padding(.vertical, Spacing.sm)
        .background(isHovered ? Color.panelCharcoal.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.1)) { isHovered = hovering }
        }
        .animation(.snappy(duration: 0.1), value: isHovered)
    }

    // MARK: - Copy Button

    @State private var isCopyHovered = false

    private var copyButton: some View {
        Button(action: onCopy) {
            ZStack {
                Circle()
                    .fill(
                        copyFailed
                            ? Color.recordingCoral.opacity(0.15)
                            : isCopied
                                ? Color.statusSuccessMuted.opacity(0.15)
                                : (isCopyHovered ? Color.panelCharcoalSurface : Color.clear)
                    )
                    .frame(width: 28, height: 28)

                if copyFailed {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.recordingCoral)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else if isCopied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.statusSuccessMuted)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(isCopyHovered ? .panelTextPrimary : .panelTextMuted)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.snappy(duration: 0.15), value: isCopied)
            .animation(.snappy(duration: 0.15), value: copyFailed)
            .animation(.snappy(duration: 0.1), value: isCopyHovered)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in isCopyHovered = hovering }
        .help(copyFailed ? "Could not read transcript" : isCopied ? "Copied to clipboard" : "Copy transcript for AI")
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
