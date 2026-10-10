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
    /// Told who the voice became once a name is saved, so the card can keep
    /// it on screen and light that person's print.
    var onNamed: ((SpeakerReviewNamedVoice) -> Void)? = nil
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
    @Environment(\.colorScheme) private var colorScheme

    static let printDiameter: CGFloat = 36

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
            // The voice's print is the play button, like the island's review:
            // empty rings (nobody's confirmed it yet) that ripple while the
            // clip plays. No quote; people pick a voice by ear.
            HStack(alignment: .center, spacing: 14) {
                VoicePrintRepresentable(
                    model: VoicePrintView.Model(
                        style: printStyle,
                        colorIndex: printStyle.preferredColorIndex,
                        litRings: 0,
                        surface: colorScheme == .dark ? .settingsDark : .settingsLight
                    ),
                    diameter: Self.printDiameter,
                    isPlaying: isPlaying,
                    onPlay: hasClip ? { model.playSample(for: group.representative) } : nil,
                    accessibilityIdentifier: "transcripted.speakers.voice-to-name.play"
                )
                .frame(width: Self.printDiameter, height: Self.printDiameter)
                .help(SpeakerClipPlaybackPresentation.helpText(hasClip: hasClip, isPlaying: isPlaying))

                VStack(alignment: .leading, spacing: 2) {
                    Text("Unknown voice")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LibraryTokens.ink2)
                    Text(metaLine)
                        .font(LibraryTokens.meta)
                        .monospacedDigit()
                        .foregroundStyle(LibraryTokens.ink2)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                overflowMenu
            }

            if !nameChips.isEmpty {
                HStack(spacing: 6) {
                    ForEach(nameChips) { chip in
                        SpeakerNameChipButton(chip: chip, isDisabled: isSaving) {
                            if let person = chip.person {
                                join(person)
                            } else {
                                nameDraft = chip.name
                                saveName()
                            }
                        }
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
                .padding(.leading, 50)
                .accessibilityIdentifier("transcripted.speakers.voice-to-name.invitees")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    nameField
                    saveHint
                    quietQueueActions
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 8) {
                    nameField
                    HStack(spacing: 10) {
                        saveHint
                        quietQueueActions
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.leading, 50)

            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 50)
            }

            if let deleteErrorMessage {
                Text(deleteErrorMessage)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 50)
            }
        }
        .padding(.vertical, 10)
        .onAppear {
            if nameDraft.isEmpty {
                nameDraft = group.representative.profile.displayName ?? ""
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

    private var printStyle: VoicePrintStyle { VoicePrintStyle(id: group.id) }

    /// Invitees first (each one that's a saved person shows their print),
    /// then up to two saved people still learning who weren't invited.
    private var nameChips: [SpeakerNameChip] {
        let voiceID = group.representative.speakerId
        var chips = inviteeChoices.shown.map { name -> SpeakerNameChip in
            let person = model.uniqueSavedPerson(named: name, excluding: voiceID)
            return SpeakerNameChip(name: name, person: person, standing: person.flatMap(model.namingStanding(for:)), isInvitee: true)
        }
        let taken = Set(chips.compactMap { $0.person?.id })
        for person in model.savedPeopleStillLearning(excluding: invitees) where !taken.contains(person.id) && person.id != voiceID {
            guard let name = person.displayName else { continue }
            chips.append(SpeakerNameChip(name: name, person: person, standing: model.namingStanding(for: person), isInvitee: false))
        }
        return chips
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
        if let existing = model.uniqueSavedPerson(named: nameDraft, excluding: voice.id) {
            isSaving = false
            join(existing)
            return
        }
        let named = SpeakerReviewNamedVoice(
            voiceID: voice.id,
            personID: voice.id,
            name: nameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            confirmedBefore: 0,
            requiredMeetings: SpeakerNamingTierPresentation.segmentCount,
            isNewPerson: true,
            isTrusted: true
        )
        model.namePendingReviewItem(group.representative, to: nameDraft) { didSave in
            isSaving = false
            if didSave {
                nameDraft = ""
                onNamed?(savedProgress(named))
            } else {
                saveErrorMessage = "Couldn't save — the meeting file may have moved."
            }
        }
    }

    /// This voice joins someone already saved. The refreshed store decides
    /// how many distinct meetings that answer confirmed.
    private func join(_ person: SpeakerProfile) {
        guard !isSaving else { return }
        isSaving = true
        saveErrorMessage = nil
        let standing = model.namingStanding(for: person)
        let named = SpeakerReviewNamedVoice(
            voiceID: group.representative.speakerId,
            personID: person.id,
            name: person.displayName ?? nameDraft,
            confirmedBefore: standing?.confirmedMeetings ?? max(0, person.confirmedMeetingCount),
            requiredMeetings: standing?.requiredMeetings ?? SpeakerNamingTierPresentation.segmentCount,
            isNewPerson: false,
            isTrusted: standing?.isTrusted ?? true
        )
        model.mergePendingReviewItem(group.representative, into: person) { didSave in
            isSaving = false
            if didSave {
                nameDraft = ""
                onNamed?(savedProgress(named))
            } else {
                saveErrorMessage = "Couldn't save — the meeting file may have moved."
            }
        }
    }

    /// Save completion runs after the store snapshot is refreshed. One action
    /// can confirm several meetings, or no new meeting for a split voice.
    private func savedProgress(_ voice: SpeakerReviewNamedVoice) -> SpeakerReviewNamedVoice {
        var saved = voice
        let profile = model.profiles.first { $0.id == voice.personID }
        let standing = profile.flatMap { model.namingStanding(for: $0) }
        saved.confirmedAfter = standing?.confirmedMeetings ?? profile?.confirmedMeetingCount ?? voice.confirmedBefore
        saved.requiredMeetings = standing?.requiredMeetings ?? voice.requiredMeetings
        saved.isTrusted = standing?.isTrusted ?? false
        return saved
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
