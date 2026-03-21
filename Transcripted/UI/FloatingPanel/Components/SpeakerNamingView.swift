// SpeakerNamingView.swift
// Post-meeting speaker naming tray — lets users teach the app who's who.
// Follows TranscriptTrayView patterns: frosted glass, triangle connector, 280pt wide.
//
// v2: Merge-aware naming + sticky tray.
// - Typing a name that matches an existing profile shows a merge confirmation.
// - Tray stays until explicit Done/Skip — no escape dismiss, no X button.

import SwiftUI

// MARK: - SpeakerNamingView

@available(macOS 26.0, *)
struct SpeakerNamingView: View {

    let request: SpeakerNamingRequest

    @State private var isAppearing = false
    @State private var updates: [UUID: SpeakerNameUpdate] = [:]
    @State private var canDismiss = false
    @State private var dismissGuardTask: Task<Void, Never>?
    @StateObject private var clipPlayer = ClipAudioPlayer()

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
                    header
                    Divider().background(Color.panelCharcoalElevated)
                    speakerList
                    Divider().background(Color.panelCharcoalElevated)
                    footer
                }
            }
            .frame(width: PillDimensions.trayWidth)
            .clipped()

            // Triangle connector
            Triangle()
                .fill(Color.white.opacity(0.15))
                .frame(width: 12, height: 6)
                .rotationEffect(.degrees(180))
        }
        .scaleEffect(isAppearing ? 1.0 : 0.92, anchor: .bottom)
        .opacity(isAppearing ? 1.0 : 0.0)
        .onAppear {
            withAnimation(.trayExpand) { isAppearing = true }
            // Prevent accidental dismissal — button enables after 3s
            canDismiss = false
            dismissGuardTask = Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) { canDismiss = true }
                }
            }
        }
        .onDisappear {
            dismissGuardTask?.cancel()
            isAppearing = false
            clipPlayer.stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "person.wave.2")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.panelTextMuted)

            Text("Familiar Voices")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.panelTextMuted)
                .textCase(.uppercase)
                .tracking(0.8)

            Spacer()

            if canDismiss {
                Button(action: submitNaming) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.panelTextMuted)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Dismiss")
                .transition(.opacity)
            }
        }
        .padding(.horizontal, Spacing.ms)
        .padding(.vertical, Spacing.xs + 2)
    }

    // MARK: - Speaker List

    private var speakerList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(request.speakers) { entry in
                    SpeakerNamingCard(
                        entry: entry,
                        clipPlayer: clipPlayer,
                        onUpdate: { update in
                            updates[entry.id] = update
                        }
                    )

                    if entry.id != request.speakers.last?.id {
                        Divider()
                            .background(Color.panelCharcoalElevated.opacity(0.5))
                            .padding(.horizontal, Spacing.md)
                    }
                }
            }
        }
        .frame(maxHeight: 240)
    }

    // MARK: - Footer

    private var footer: some View {
        Button(action: submitNaming) {
            HStack(spacing: 4) {
                let namedCount = updates.count
                let totalCount = request.speakers.count

                Image(systemName: namedCount > 0 ? "checkmark.circle.fill" : "checkmark.circle")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(namedCount > 0 ? .statusSuccessMuted : .panelTextSecondary)
                Text(namedCount > 0 ? "Done" : "Skip")
                    .font(.system(size: 11, weight: .medium))
                Spacer()

                if namedCount > 0 {
                    Text("\(namedCount)/\(totalCount)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.panelTextMuted)
                }
            }
            .foregroundColor(.panelTextPrimary)
            .padding(.horizontal, Spacing.ms)
            .padding(.vertical, Spacing.sm)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(!canDismiss)
        .opacity(canDismiss ? 1.0 : 0.5)
        .background(Color.panelCharcoal.opacity(0.3))
    }

    // MARK: - Actions

    private func submitNaming() {
        clipPlayer.stop()
        let allUpdates = Array(updates.values)
        AppLogger.pipeline.info("Speaker naming submitted by user", ["updates": "\(allUpdates.count)"])
        request.onComplete(allUpdates)
    }
}
