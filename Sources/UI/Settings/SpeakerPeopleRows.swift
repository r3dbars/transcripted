import SwiftUI
import AppKit
import Combine
import TranscriptedCore

struct SpeakerVoiceToNameRow: View {
    let group: SpeakerPendingVoiceGroup
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    /// Inside a call's card the meeting name and day are already on top.
    var showsMeeting = true
    /// That call's calendar invitees, offered as one-tap names.
    var invitees: [String] = []
    @State private var showsAllInvitees = false
    /// Observed directly so play/stop/finish reliably re-renders THIS row.
    /// A traced repro showed the earlier notification → parent @State bump
    /// scheme landing in the section without LazyVStack ever re-running the
    /// row bodies — the pause glyph and quote sweep never appeared.
    @ObservedObject private var playback = SpeakerClipPlayback.shared

    @State private var nameDraft = ""
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?
    @State private var isMarkingAsMe = false
    @State private var clipDuration = SpeakerClipProgressBar.fallbackDuration

    private var isPlaying: Bool {
        if let clipURL = group.representative.clipURL {
            return playback.isPlaying(clipURL)
        }
        return group.representative.retainedAudioSample.map(playback.isPlaying) ?? false
    }

    private var hasClip: Bool {
        group.representative.clipURL != nil || group.representative.retainedAudioSample != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The quote is the playable object: a quiet play/pause glyph sits
            // inline with it, and while the clip plays an accent sweep runs
            // under the words being spoken. At rest there is no bar at all.
            HStack(alignment: .top, spacing: 4) {
                SpeakerQuietPlayButton(
                    hasClip: hasClip,
                    isPlaying: isPlaying,
                    action: { model.playSample(for: group.representative) }
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(quoteLine)
                        .font(LibraryTokens.body)
                        .foregroundStyle(group.sampleText == nil ? LibraryTokens.ink2 : Color.primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    SpeakerClipProgressBar(isPlaying: isPlaying, duration: clipDuration)
                        .frame(maxWidth: 240)
                        .opacity(isPlaying ? 1 : 0)
                        .animation(.easeOut(duration: 0.18), value: isPlaying)

                    Text(metaLine)
                        .font(LibraryTokens.meta)
                        .monospacedDigit()
                        .foregroundStyle(LibraryTokens.ink2)
                        .lineLimit(2)
                }
                .padding(.top, 11)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    nameField
                    saveHint
                    quietQueueActions
                    Spacer(minLength: 0)
                    overflowMenu
                }

                VStack(alignment: .leading, spacing: 8) {
                    nameField
                    HStack(spacing: 10) {
                        saveHint
                        quietQueueActions
                        Spacer(minLength: 0)
                        overflowMenu
                    }
                }
            }
            .padding(.leading, 44)

            if !inviteeChoices.shown.isEmpty {
                HStack(spacing: 6) {
                    ForEach(inviteeChoices.shown, id: \.self) { name in
                        Button(name) {
                            nameDraft = name
                            saveName()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("\(name) was on the calendar invite.")
                        .disabled(isSaving)
                    }
                    if inviteeChoices.hidden > 0 {
                        Button {
                            showsAllInvitees = true
                        } label: {
                            Image(systemName: "chevron.right")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityLabel("Show \(inviteeChoices.hidden) more invitees")
                    }
                }
                .padding(.leading, 44)
                .accessibilityIdentifier("transcripted.speakers.voice-to-name.invitees")
            }

            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
            }

            if let deleteErrorMessage {
                Text(deleteErrorMessage)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 44)
            }
        }
        .padding(.vertical, 10)
        .onAppear {
            if nameDraft.isEmpty {
                nameDraft = group.representative.profile.displayName ?? ""
            }
            if let clipURL = group.representative.clipURL {
                clipDuration = probeClipDuration(clipURL)
            } else if let sample = group.representative.retainedAudioSample {
                clipDuration = sample.duration
            }
        }
        .onChange(of: nameDraft) { _, _ in
            saveErrorMessage = nil
        }
        .alert(
            SpeakerVoiceRowMenuPolicy.deleteConfirmationTitle,
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                deleteVoice()
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(SpeakerVoiceRowMenuPolicy.deleteConfirmationMessage)
        }
    }

    private var inviteeChoices: (shown: [String], hidden: Int) {
        NotchIslandSpeakerReviewPolicy.inviteeChips(
            invitees: invitees,
            alreadyUsed: [],
            showAll: showsAllInvitees
        )
    }

    private var nameSuggestions: [SpeakerNameChoice] {
        SpeakerNameSuggestionSource.options(
            from: model.profiles,
            excluding: group.representative.speakerId
        )
    }

    private var nameField: some View {
        SpeakerNameAutocompleteField(
            text: $nameDraft,
            placeholder: "Who is this?",
            options: nameSuggestions,
            accessibilityIdentifier: "transcripted.speakers.voice-to-name.name",
            onSubmit: saveName
        )
        .frame(minWidth: 200)
    }

    /// Quiet ⏎-to-save hint replacing the old "Save Name" button — the field
    /// itself commits on Enter (`onSubmit: saveName`), matching the person
    /// card's "⏎ to rename" pattern.
    private var saveHint: some View {
        Text(isSaving ? "Saving…" : "⏎ to save")
            .font(.system(size: 11))
            .foregroundStyle(LibraryTokens.ink3)
            .fixedSize()
    }

    /// "This is me" / "Skip" — quiet text actions, not chips: matches the
    /// prototype's `<a>` affordances and the surface's "color only for
    /// action/attention" rule.
    private var quietQueueActions: some View {
        HStack(spacing: 6) {
            if SpeakerVoiceQueueRowActionPolicy.showsThisIsMe(channel: group.representative.channel) {
                SpeakerQuietLinkButton(
                    title: isMarkingAsMe ? "Saving…" : SpeakerVoiceQueueRowActionPolicy.thisIsMeTitle,
                    action: markAsMe
                )
                .disabled(isSaving || isMarkingAsMe)
                .accessibilityIdentifier("transcripted.speakers.voice-to-name.this-is-me")

                Text("·")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }

            SpeakerQuietLinkButton(
                title: SpeakerVoiceQueueRowActionPolicy.skipTitle,
                action: { model.skip(group) }
            )
            .accessibilityIdentifier("transcripted.speakers.voice-to-name.skip")
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button(SpeakerVoiceRowMenuAction.showTranscript.title) {
                model.openTranscript(for: group.representative)
            }

            Divider()

            Button(SpeakerVoiceRowMenuAction.deleteVoice.title, role: .destructive) {
                showDeleteConfirmation = true
            }
            .disabled(isDeleting)
        } label: {
            SpeakerCompactIconLabel(
                systemName: "ellipsis",
                foregroundColor: .secondary,
                fontSize: 13,
                fontWeight: .semibold
            )
        }
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Show transcript or delete this voice")
        .accessibilityLabel("Voice actions")
        .accessibilityIdentifier("transcripted.speakers.voice-to-name.menu")
    }

    private var quoteLine: String {
        guard let sampleText = group.sampleText else {
            return "No transcript sample for this voice."
        }
        return "\u{201C}\(sampleText)\u{201D}"
    }

    private var metaLine: String {
        let item = group.representative
        var parts: [String] = []
        if showsMeeting {
            parts.append(item.meetingTitle)
            if let dateText = Self.dateFormatter.stringIfAvailable(from: item.recordedAt ?? item.fallbackDate) {
                parts.append(dateText)
            }
        }
        parts.append(item.channel == .mic ? "In the room" : "Remote")
        if group.meetingCount > 1 {
            let others = group.meetingCount - 1
            parts.append(others == 1 ? "+1 more meeting" : "+\(others) more meetings")
        }
        return parts.joined(separator: " · ")
    }

    private var canSave: Bool {
        !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveName() {
        guard canSave, !isSaving else { return }
        isSaving = true
        saveErrorMessage = nil
        // A name that already belongs to one saved person (an invitee chip
        // or a typed "Alice") adds this voice to them, like the island and
        // the review window do, instead of making a second Alice.
        let voice = group.representative.profile
        if let existing = SpeakerNameSelectionPolicy.uniqueSavedPerson(
            named: nameDraft,
            among: model.profiles,
            excluding: voice.id,
            id: \.id,
            displayName: \.displayName
        ) {
            model.mergePendingReviewItem(group.representative, into: existing) { didSave in
                isSaving = false
                if didSave {
                    nameDraft = ""
                } else {
                    saveErrorMessage = "Couldn't save — the meeting file may have moved."
                }
            }
            return
        }
        model.namePendingReviewItem(group.representative, to: nameDraft) { didSave in
            isSaving = false
            if didSave {
                nameDraft = ""
            } else {
                saveErrorMessage = "Couldn't save — the meeting file may have moved."
            }
        }
    }

    private func markAsMe() {
        guard !isSaving, !isMarkingAsMe else { return }
        isMarkingAsMe = true
        saveErrorMessage = nil
        model.markPendingReviewItemAsMe(group.representative) { didSave in
            isMarkingAsMe = false
            if !didSave {
                saveErrorMessage = "Couldn't save — the meeting file may have moved."
            }
        }
    }

    private func deleteVoice() {
        guard !isDeleting else { return }
        isDeleting = true
        deleteErrorMessage = nil
        model.deleteVoice(group) { didDelete in
            isDeleting = false
            // On success the row's voice group drops out of the refreshed
            // snapshot, so this view disappears. Only a failed delete keeps the
            // row around to show the surfaced error.
            deleteErrorMessage = SpeakerVoiceRowMenuPolicy.deleteErrorMessage(didDelete: didDelete)
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

private extension DateFormatter {
    func stringIfAvailable(from date: Date) -> String? {
        date == .distantPast ? nil : string(from: date)
    }
}
