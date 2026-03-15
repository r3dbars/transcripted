// SpeakerNamingView.swift
// Post-meeting speaker naming tray — lets users teach the app who's who.
// Follows TranscriptTrayView patterns: frosted glass, triangle connector, 280pt wide.
//
// v2: Merge-aware naming + sticky tray.
// - Typing a name that matches an existing profile shows a merge confirmation.
// - Tray stays until explicit Done/Skip — no escape dismiss, no X button.

import SwiftUI
import AVFoundation

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

// MARK: - SpeakerNamingCard

@available(macOS 26.0, *)
struct SpeakerNamingCard: View {

    let entry: SpeakerNamingEntry
    @ObservedObject var clipPlayer: ClipAudioPlayer
    let onUpdate: (SpeakerNameUpdate) -> Void

    @State private var nameText: String = ""
    @State private var isConfirmed = false
    @State private var isRejected = false   // red X tapped — expand to text field
    @State private var isMerged = false     // merge confirmed — show linked state
    @State private var mergeCandidate: SpeakerProfile? = nil  // profile to merge into
    @State private var isHovered = false
    @State private var cachedMatchingProfiles: [SpeakerProfile] = []
    @State private var profileSearchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            // Top row: play button + sample text
            HStack(alignment: .top, spacing: Spacing.sm) {
                playButton
                sampleQuote
            }

            // Bottom row: naming/confirmation/merge controls
            if isMerged {
                mergedConfirmationRow
            } else if mergeCandidate != nil {
                mergeConfirmationRow
            } else if entry.needsNaming || isRejected {
                namingField
            } else if entry.needsConfirmation {
                confirmationRow
            }
        }
        .padding(.horizontal, Spacing.ms)
        .padding(.vertical, Spacing.sm)
        .background(isHovered ? Color.panelCharcoal.opacity(0.3) : Color.clear)
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.1)) { isHovered = hovering }
        }
        .onAppear {
            if let name = entry.currentName, entry.needsConfirmation {
                nameText = name
            } else if let suggested = qwenSuggestedName {
                // Pre-fill from Qwen inference
                nameText = suggested
            }
        }
    }

    // MARK: - Play Button

    private var playButton: some View {
        Button(action: togglePlayback) {
            ZStack {
                Circle()
                    .fill(isPlayingThisClip
                        ? Color.accentBlue.opacity(0.2)
                        : Color.panelCharcoalSurface.opacity(0.8))
                    .frame(width: 32, height: 32)

                Image(systemName: isPlayingThisClip ? "stop.fill" : "play.fill")
                    .font(.system(size: 11))
                    .foregroundColor(isPlayingThisClip ? .accentBlue : .panelTextSecondary)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .help(isPlayingThisClip ? "Stop" : "Play clip")
    }

    private var isPlayingThisClip: Bool {
        clipPlayer.isPlaying && clipPlayer.currentClipURL == entry.clipURL
    }

    private func togglePlayback() {
        if isPlayingThisClip {
            clipPlayer.stop()
        } else {
            clipPlayer.play(url: entry.clipURL)
        }
    }

    // MARK: - Sample Quote

    private var sampleQuote: some View {
        Text("\"\(entry.sampleText)\"")
            .font(.system(size: 11))
            .italic()
            .foregroundColor(.panelTextSecondary)
            .lineLimit(2)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Source Label

    /// Hint text showing how the name was detected (or that detection was attempted)
    private var sourceLabel: some View {
        Group {
            if entry.currentName != nil, let sim = entry.matchSimilarity {
                // Voice match from DB takes priority — biometric > LLM inference
                Label("Voice match · \(Int(sim * 100))%", systemImage: "waveform")
                    .font(.system(size: 10))
                    .foregroundColor(.panelTextMuted)
            } else if isQwenSuggestion {
                Label("Detected from conversation", systemImage: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.orange.opacity(0.7))
            }
        }
    }

    /// Hint for unknown speakers when Qwen tried but found no name
    private var noNameDetectedHint: some View {
        Group {
            if case .noNameFound = entry.qwenResult, entry.currentName == nil {
                Label("No name detected in conversation", systemImage: "sparkles")
                    .font(.system(size: 10))
                    .foregroundColor(.panelTextMuted.opacity(0.7))
            }
        }
    }

    // MARK: - Naming Field (unknown speaker or rejected suggestion)

    private var namingField: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundColor(.panelTextMuted)

                ZStack(alignment: .leading) {
                    if nameText.isEmpty {
                        Text("Who is this?")
                            .font(.system(size: 12))
                            .foregroundColor(.panelTextMuted.opacity(0.6))
                    }
                    TextField("", text: $nameText)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(.system(size: 12))
                        .foregroundColor(.panelTextPrimary)
                        .onSubmit {
                            commitName()
                        }
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, 4)
                .background(Color.panelCharcoalSurface.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: Radius.sm, style: .continuous))
            }

            noNameDetectedHint
                .padding(.leading, 24)

            // Autocomplete suggestions from speaker database
            if !nameText.isEmpty {
                let profiles = matchingProfiles
                if !profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(profiles.prefix(4), id: \.id) { profile in
                            Button(action: {
                                withAnimation(.snappy(duration: 0.15)) {
                                    mergeCandidate = profile
                                    nameText = profile.displayName ?? nameText
                                }
                            }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "person.circle")
                                        .font(.system(size: 9))
                                    Text(profile.displayName ?? "")
                                        .font(.system(size: 10, weight: .medium))
                                    Text("(\(profile.callCount) calls)")
                                        .font(.system(size: 9))
                                        .foregroundColor(.accentBlue.opacity(0.7))
                                }
                                .foregroundColor(.accentBlue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.accentBlue.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            }
                            .buttonStyle(PlainButtonStyle())
                        }
                    }
                    .padding(.leading, 24)  // align with text field
                }
            }
        }
        .onChange(of: nameText) { _, newValue in
            refreshMatchingProfiles()
            if !newValue.isEmpty && mergeCandidate == nil {
                let action: SpeakerNameUpdate.NamingAction = isRejected ? .corrected : .named
                onUpdate(SpeakerNameUpdate(
                    persistentSpeakerId: entry.id,
                    sortformerSpeakerId: entry.sortformerSpeakerId,
                    newName: newValue.trimmingCharacters(in: .whitespacesAndNewlines),
                    action: action
                ))
            }
        }
    }

    /// Profiles whose display name matches the current text input (debounced, async)
    private var matchingProfiles: [SpeakerProfile] { cachedMatchingProfiles }

    private func refreshMatchingProfiles() {
        profileSearchTask?.cancel()
        let query = nameText
        guard query.count >= 2 else {
            cachedMatchingProfiles = []
            return
        }
        let entryId = entry.id
        profileSearchTask = Task {
            // Debounce: wait 150ms to avoid blocking on every keystroke
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            if #available(macOS 14.0, *) {
                let results = SpeakerDatabase.shared.findProfilesByName(query)
                    .filter { $0.id != entryId }
                guard !Task.isCancelled else { return }
                cachedMatchingProfiles = results
            }
        }
    }

    private func commitName() {
        // If there's a matching profile, go to merge confirmation instead of committing directly
        if let topMatch = matchingProfiles.first {
            withAnimation(.snappy(duration: 0.15)) {
                mergeCandidate = topMatch
            }
            return
        }

        let trimmed = nameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let action: SpeakerNameUpdate.NamingAction = isRejected ? .corrected : .named
        onUpdate(SpeakerNameUpdate(
            persistentSpeakerId: entry.id,
            sortformerSpeakerId: entry.sortformerSpeakerId,
            newName: trimmed,
            action: action
        ))
    }

    // MARK: - Merge Confirmation Row

    private var mergeConfirmationRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "link.circle")
                .font(.system(size: 12))
                .foregroundColor(.accentBlue)

            if let candidate = mergeCandidate {
                Text("Link to \(candidate.displayName ?? "Unknown") (\(candidate.callCount) calls)?")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)
            }

            Spacer()

            // Confirm merge
            Button(action: confirmMerge) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.statusSuccessMuted)
            }
            .buttonStyle(PlainButtonStyle())
            .help("Yes, same person")

            // Cancel merge — go back to text field
            Button(action: cancelMerge) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(.panelTextMuted.opacity(0.6))
            }
            .buttonStyle(PlainButtonStyle())
            .help("Cancel")
        }
        .animation(.snappy(duration: 0.15), value: mergeCandidate?.id)
    }

    private func confirmMerge() {
        clipPlayer.stop()
        guard let candidate = mergeCandidate else { return }
        let name = candidate.displayName ?? nameText.trimmingCharacters(in: .whitespacesAndNewlines)

        withAnimation(.snappy(duration: 0.15)) {
            isMerged = true
        }

        onUpdate(SpeakerNameUpdate(
            persistentSpeakerId: entry.id,
            sortformerSpeakerId: entry.sortformerSpeakerId,
            newName: name,
            action: .merged(targetProfileId: candidate.id)
        ))
    }

    private func cancelMerge() {
        withAnimation(.snappy(duration: 0.15)) {
            mergeCandidate = nil
        }
    }

    // MARK: - Merged Confirmation Row (after merge confirmed)

    private var mergedConfirmationRow: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(.statusSuccessMuted)
            Text("Linked to \(mergeCandidate?.displayName ?? nameText)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.panelTextPrimary)
            Spacer()
        }
    }

    // MARK: - Confirmation Row (known speaker or Qwen suggestion)

    /// Whether this entry has a Qwen-inferred name suggestion
    private var isQwenSuggestion: Bool {
        if case .suggested = entry.qwenResult { return true }
        return false
    }

    /// Extract Qwen suggested name, if any
    private var qwenSuggestedName: String? {
        if case .suggested(let name) = entry.qwenResult { return name }
        return nil
    }

    /// Display name for this entry — DB match or Qwen suggestion
    private var displayName: String {
        if let name = entry.currentName { return name }
        if let suggested = qwenSuggestedName { return suggested }
        return ""
    }

    private var confirmationRow: some View {
        HStack(spacing: Spacing.sm) {
            if isConfirmed {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.statusSuccessMuted)
                Text(displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.panelTextPrimary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.panelTextPrimary)

                    sourceLabel
                }

                Spacer()

                Button(action: confirmSpeaker) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.statusSuccessMuted)
                }
                .buttonStyle(PlainButtonStyle())
                .help("Yes, that's \(displayName)")

                Button(action: rejectSpeaker) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundColor(.recordingCoral.opacity(0.8))
                }
                .buttonStyle(PlainButtonStyle())
                .help("Wrong person")
            }
        }
        .animation(.snappy(duration: 0.15), value: isConfirmed)
    }

    private func confirmSpeaker() {
        clipPlayer.stop()
        isConfirmed = true
        let name = displayName
        guard !name.isEmpty else { return }
        onUpdate(SpeakerNameUpdate(
            persistentSpeakerId: entry.id,
            sortformerSpeakerId: entry.sortformerSpeakerId,
            newName: name,
            action: .confirmed
        ))
    }

    private func rejectSpeaker() {
        withAnimation(.snappy(duration: 0.15)) {
            isRejected = true
        }
        nameText = ""
    }
}

// MARK: - ClipAudioPlayer

/// Lightweight wrapper around AVAudioPlayer for speaker clip playback.
@available(macOS 14.0, *)
class ClipAudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published var isPlaying = false
    @Published var currentClipURL: URL?

    private var player: AVAudioPlayer?

    func play(url: URL) {
        stop()  // stop any current playback

        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.play()
            isPlaying = true
            currentClipURL = url
        } catch {
            AppLogger.ui.warning("Failed to play speaker clip", ["error": error.localizedDescription])
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        currentClipURL = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async {
            self.isPlaying = false
            self.currentClipURL = nil
        }
    }
}
