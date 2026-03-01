// OverlayContentView.swift
// SwiftUI views for all 6 overlay states: idle, loading, listening, drafting, streaming, review

import SwiftUI

struct OverlayContentView: View {
    @ObservedObject var sttRouter: STTRouter
    @ObservedObject var controller: FloatingOverlayController
    @FocusState private var isReviewFocused: Bool
    /// Content area and dividers are hidden when listening + collapsed (compact header-only bar)
    private var showContentArea: Bool {
        if controller.state == .idle { return false }
        if controller.state == .listening && !controller.transcriptExpanded { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            if showContentArea {
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
                contentArea
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            }
            bottomToolbar
        }
        .background(OverlayTokens.panelBg)
    }

    // MARK: - Header Bar

    @ViewBuilder
    private var headerBar: some View {
        HStack {
            // Mode label
            Group {
                switch (controller.state, controller.activeMode) {
                case (.listening, .draft):
                    Text("Draft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OverlayTokens.textSecondary)
                case (.listening, .dictation):
                    Text("Dictate")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OverlayTokens.textSecondary)
                case (.drafting, .dictation):
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(OverlayTokens.accentGreen)
                        Text("Polishing...")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(OverlayTokens.textSecondary)
                    }
                case (.drafting, _), (.streaming, _):
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(OverlayTokens.accentGreen)
                        Text("Drafting...")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(OverlayTokens.textSecondary)
                    }
                case (.loading, _):
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(OverlayTokens.accentGreen)
                        Text("Loading voice model...")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(OverlayTokens.textSecondary)
                    }
                case (.review, _):
                    Text("Draft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OverlayTokens.textSecondary)
                default:
                    Text("Draft")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(OverlayTokens.textMuted)
                }
            }

            // Scrolling waveform during listening; spacer otherwise
            if controller.state == .listening {
                ScrollingWaveformView(
                    level: sttRouter.audioLevel,
                    isActive: true
                )
                .frame(maxWidth: .infinity, maxHeight: 20)
                .padding(.horizontal, 8)

                // Chevron to expand/collapse transcript
                Button(action: { controller.toggleTranscript() }) {
                    Image(systemName: controller.transcriptExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(OverlayTokens.textMuted)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)
            } else {
                Spacer()
            }

            // Shortcut hint
            Group {
                switch (controller.state, controller.activeMode) {
                case (.listening, .draft):
                    Text("\u{2325}D to stop")
                        .font(.system(size: 10))
                        .foregroundColor(OverlayTokens.textMuted)
                case (.listening, .dictation):
                    Text("\u{2325}Space to stop")
                        .font(.system(size: 10))
                        .foregroundColor(OverlayTokens.textMuted)
                case (.loading, _):
                    Text("Esc to cancel")
                        .font(.system(size: 10))
                        .foregroundColor(OverlayTokens.textMuted)
                case (.review, _):
                    EmptyView()
                default:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, OverlayTokens.contentPadding)
        .padding(.vertical, 10)
    }

    // MARK: - Central Content Area

    @ViewBuilder
    private var contentArea: some View {
        switch controller.state {
        case .loading:
            loadingContent
        case .listening:
            listeningContent
        case .drafting:
            draftingContent
        case .streaming:
            streamingContent
        case .review:
            reviewContent
        case .idle:
            idleContent
        }
    }

    @ViewBuilder
    private var loadingContent: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
                .tint(OverlayTokens.accentGreen)
            Text("Preparing voice model...")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(OverlayTokens.textSecondary)
            if controller.loadingElapsedSeconds > 0 {
                Text("This may take a moment on first launch (\(controller.loadingElapsedSeconds)s)")
                    .font(.system(size: 11))
                    .foregroundColor(OverlayTokens.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OverlayTokens.contentPadding)
    }

    @ViewBuilder
    private var listeningContent: some View {
        Group {
            if !sttRouter.liveTranscript.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        AnimatedTranscriptView(text: sttRouter.liveTranscript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id("transcript")
                    }
                    .onChange(of: sttRouter.liveTranscript) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            proxy.scrollTo("transcript", anchor: .bottom)
                        }
                    }
                }
            } else {
                Text(controller.activeMode == .dictation
                     ? "Recording... press \u{2325}Space to stop"
                     : "Recording... press \u{2325}D to stop")
                    .font(.system(size: 12))
                    .foregroundColor(OverlayTokens.textMuted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(.horizontal, OverlayTokens.contentPadding)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var draftingContent: some View {
        VStack(spacing: 8) {
            if !controller.errorMessage.isEmpty {
                // Error message — shown briefly before overlay auto-hides
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 18))
                    .foregroundColor(.yellow)
                Text(controller.errorMessage)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(OverlayTokens.textSecondary)
            } else if sttRouter.isTranscribing, !sttRouter.liveTranscript.isEmpty {
                // Show live transcript at reduced opacity with blur (provisional feel)
                ScrollView(.vertical, showsIndicators: false) {
                    AnimatedTranscriptView(text: sttRouter.liveTranscript)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .opacity(0.45)
                .blur(radius: 0.5)

                HStack(spacing: 6) {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(OverlayTokens.accentGreen)
                    Text("Refining...")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(OverlayTokens.textSecondary)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
                    .tint(OverlayTokens.accentGreen)
                Text(sttRouter.isTranscribing ? "Transcribing..." : "Processing...")
                    .font(.system(size: 12))
                    .foregroundColor(OverlayTokens.textMuted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(OverlayTokens.contentPadding)
    }

    @ViewBuilder
    private var streamingContent: some View {
        ScrollView(.vertical, showsIndicators: false) {
            Text(controller.streamingText)
                .font(.system(size: 13))
                .foregroundColor(OverlayTokens.textPrimary)
                .lineLimit(nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, OverlayTokens.contentPadding)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var reviewContent: some View {
        TextEditor(text: $controller.reviewText)
            .focused($isReviewFocused)
            .font(.system(size: 13))
            .foregroundColor(OverlayTokens.textPrimary)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, OverlayTokens.contentPadding - 4)
            .padding(.vertical, 8)
            .onKeyPress(keys: [.return], phases: .down) { keyPress in
                if keyPress.modifiers.contains(.shift) {
                    return .ignored  // Shift+Enter inserts newline
                }
                controller.onConfirm?()
                return .handled
            }
            .onKeyPress(keys: [.escape], phases: .down) { _ in
                controller.onCancel?()
                return .handled
            }
            .onAppear {
                // Small delay lets the panel finish becoming key before we claim focus
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    isReviewFocused = true
                }
            }
    }

    @ViewBuilder
    private var idleContent: some View {
        Text("Press \u{2325}Space or \u{2325}D to start")
            .font(.system(size: 12))
            .foregroundColor(OverlayTokens.textMuted)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Bottom Toolbar

    @ViewBuilder
    private var bottomToolbar: some View {
        // Only show bottom toolbar in review mode — listening/drafting/streaming
        // status is already communicated by the header bar (waveform, spinner, etc.)
        if controller.state == .review {
            Text("\u{21A9} send \u{00B7} Esc cancel")
                .font(.system(size: 10))
                .foregroundColor(OverlayTokens.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
        }
    }
}
