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

struct SpeakerPersonRow: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    /// Observed directly so play/stop/finish reliably re-renders THIS row —
    /// see the matching note on `SpeakerVoiceToNameRow`.
    @ObservedObject private var playback = SpeakerClipPlayback.shared
    /// Lifted to the parent list so opening one person closes any other —
    /// "one person open at a time", per spec.
    @Binding var expandedPersonID: UUID?

    @State private var nameDraft: String = ""
    @State private var renameErrorMessage: String?
    @State private var isSavingRename = false
    @State private var expansionClipDuration = SpeakerClipProgressBar.fallbackDuration
    @State private var showDeleteConfirmation = false
    @State private var pendingMergeTarget: SpeakerProfile?
    @State private var showMergeConfirmation = false
    @State private var showUnmergeConfirmation = false

    @State private var isHovering = false

    private var isExpandedRow: Bool { expandedPersonID == profile.id }

    /// Play + ••• stay hidden until hover, but a row whose clip is playing
    /// keeps its controls (and pause glyph) visible so "what is playing"
    /// never goes dark mid-clip.
    private var showsRowActions: Bool { isHovering || isPlaying }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SpeakerAvatarView(name: profile.displayName)

                Text(displayName)
                    .font(LibraryTokens.rowTitle)
                    .foregroundStyle(profile.displayName == nil ? LibraryTokens.ink2 : Color.primary)
                    .lineLimit(1)

                if let badge {
                    SpeakerStatusBadge(title: badge)
                }

                Spacer(minLength: 12)

                // Always present so the row keeps one constant height; hover
                // only fades the actions in and tints the background — no
                // size change, matching the Meetings/Dictations rows.
                HStack(spacing: 2) {
                    if hasClip {
                        SpeakerQuietPlayButton(
                            hasClip: hasClip,
                            isPlaying: isPlaying,
                            action: { model.playSample(for: profile.id) },
                            accessibilityIdentifier: "transcripted.speakers.person.play"
                        )
                    }

                    rowMenu
                }
                .opacity(showsRowActions ? 1 : 0)
                .allowsHitTesting(showsRowActions)
                .accessibilityHidden(!showsRowActions)

                Text(metadataLine)
                    .font(LibraryTokens.meta)
                    .monospacedDigit()
                    .foregroundStyle(LibraryTokens.ink3)
                    .lineLimit(1)
                    .fixedSize()
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 1, style: .continuous)
                    .fill((isHovering || isExpandedRow) ? LibraryTokens.rowHover : Color.clear)
            )
            .padding(.horizontal, -10)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            // Buttons and the menu above consume their own taps before this
            // ever fires, so hover actions (play / rename via the menu /
            // more) keep working without also toggling the expansion.
            .onTapGesture { toggleExpansion() }
            .help("Open speaker")
            .accessibilityIdentifier("transcripted.speakers.person.row")

            if isExpandedRow {
                expansionCard
            }
        }
        .alert("Delete this speaker?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.delete(profile: profile)
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This removes the saved voice profile and sample clip. Past transcripts stay unchanged.")
        }
        .alert(
            mergeConfirmationTitle,
            isPresented: $showMergeConfirmation,
            presenting: pendingMergeTarget
        ) { target in
            Button("Merge") {
                model.merge(source: profile, into: target)
                // Only collapse an expansion that belongs to the merge —
                // an unrelated open speaker (and its rename draft) stays put.
                if expandedPersonID == profile.id || expandedPersonID == target.id {
                    expandedPersonID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This combines their voices into one and renames them in past transcripts. You can split the voices apart later from this speaker's ••• menu, but past transcripts keep the merged name.")
        }
        .alert(unmergeConfirmationTitle, isPresented: $showUnmergeConfirmation) {
            Button("Undo Merge") {
                model.unmerge(into: profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This splits the merged voice back into two separate profiles so future recordings match the right person. Past transcripts keep the merged name.")
        }
    }

    private func toggleExpansion() {
        expandedPersonID = isExpandedRow ? nil : profile.id
    }

    private var rowMenu: some View {
        Menu {
            Button(profile.displayName == nil ? "Add Name…" : "Rename…") {
                expandedPersonID = profile.id
            }

            let mergeTargets = model.mergeTargets(for: profile)
            if !mergeTargets.isEmpty {
                Menu("Merge Into") {
                    ForEach(mergeTargets, id: \.id) { target in
                        Button(mergeLabel(for: target)) {
                            pendingMergeTarget = target
                            showMergeConfirmation = true
                        }
                    }
                }
            }

            if model.undoableMerge(for: profile) != nil {
                Button("Undo Last Merge…") {
                    showUnmergeConfirmation = true
                }
            }

            Divider()

            Button("Delete…", role: .destructive) {
                showDeleteConfirmation = true
            }
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
        .help("Rename, merge, or delete this speaker")
        .accessibilityLabel("Speaker actions")
        .accessibilityIdentifier("transcripted.speakers.person.menu")
    }

    private var displayName: String {
        profile.displayName ?? "Unknown voice"
    }

    private var mergeConfirmationTitle: String {
        let source = SpeakerDuplicateCandidate.displayName(for: profile)
        guard let pendingMergeTarget else {
            return "Merge “\(source)” into another speaker?"
        }
        return "Merge “\(source)” into “\(SpeakerDuplicateCandidate.displayName(for: pendingMergeTarget))”?"
    }

    private var unmergeConfirmationTitle: String {
        let name = SpeakerDuplicateCandidate.displayName(for: profile)
        if let merge = model.undoableMerge(for: profile), let sourceName = merge.sourceName {
            return "Undo merge of “\(sourceName)” into “\(name)”?"
        }
        return "Undo the last merge into “\(name)”?"
    }

    private var metadataLine: String {
        let meetings = profile.callCount == 1 ? "1 meeting" : "\(profile.callCount) meetings"
        var parts = [meetings]
        if let lastHeard = Self.relativeFormatter.string(for: profile.lastSeen) {
            parts.append("last heard \(lastHeard)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Expansion

    /// The opened person, expanded in place as a raised card: title (already
    /// shown in the row above), meta line, a voice-sample player, an inline
    /// rename field (autocomplete-backed, same as the queue row), and a quiet
    /// "Merge into…" affordance that shares this row's own merge alert.
    private var expansionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName)
                    .font(.system(size: 15, weight: .semibold))
                Text(metadataLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LibraryTokens.ink3)
            }

            expansionPlayerRow
            expansionRenameRow
            if let renameErrorMessage {
                Text(renameErrorMessage).font(LibraryTokens.meta).foregroundStyle(LibraryTokens.attention)
            }
        }
        .padding(16)
        .contentShape(Rectangle())
        // Swallow taps inside the card so the section's background tap
        // catcher (click-away collapse) doesn't fire for clicks on the
        // card's own non-interactive areas — same trick as
        // `QuietMeetingExpansion`.
        .onTapGesture {}
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .overlay(alignment: .topTrailing) {
            // Zero-size hidden control so Esc collapses the expansion,
            // matching `QuietMeetingExpansion`'s same trick on Home.
            Button(action: { expandedPersonID = nil }) { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(.bottom, 8)
        .onAppear {
            nameDraft = profile.displayName ?? ""
            renameErrorMessage = nil
            if let clipURL = model.clipURL(for: profile.id) {
                expansionClipDuration = probeClipDuration(clipURL)
            }
        }
        .onChange(of: nameDraft) { _, _ in renameErrorMessage = nil }
        .accessibilityIdentifier("transcripted.speakers.person.expansion")
    }

    private var expansionPlayerRow: some View {
        HStack(spacing: 6) {
            SpeakerQuietPlayButton(
                hasClip: hasClip,
                isPlaying: isPlaying,
                action: { model.playSample(for: profile.id) },
                accessibilityIdentifier: "transcripted.speakers.person.expansion.play"
            )

            Text(isPlaying ? "playing voice sample" : "voice sample")
                .font(.system(size: 11))
                .foregroundStyle(isPlaying ? LibraryTokens.ink2 : LibraryTokens.ink3)

            SpeakerClipProgressBar(isPlaying: isPlaying, duration: expansionClipDuration)
                .frame(maxWidth: 160)
                .opacity(isPlaying ? 1 : 0)
                .animation(.easeOut(duration: 0.18), value: isPlaying)

            Spacer(minLength: 0)
        }
    }

    private var expansionRenameRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                expansionNameField
                Text("⏎ to rename")
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryTokens.ink3)
                Spacer(minLength: 8)
                mergeIntoAffordance
            }

            VStack(alignment: .leading, spacing: 8) {
                expansionNameField
                HStack {
                    Text("⏎ to rename")
                        .font(.system(size: 11))
                        .foregroundStyle(LibraryTokens.ink3)
                    Spacer()
                    mergeIntoAffordance
                }
            }
        }
    }

    private var expansionNameField: some View {
        SpeakerNameAutocompleteField(
            text: $nameDraft,
            placeholder: "Speaker name",
            options: nameSuggestions,
            accessibilityIdentifier: "transcripted.speakers.person.expansion.name",
            onSubmit: commitRename
        )
        .frame(minWidth: 180, maxWidth: 240)
    }

    @ViewBuilder
    private var mergeIntoAffordance: some View {
        let targets = model.mergeTargets(for: profile)
        if !targets.isEmpty {
            Menu {
                ForEach(targets, id: \.id) { target in
                    Button(mergeLabel(for: target)) {
                        pendingMergeTarget = target
                        showMergeConfirmation = true
                    }
                }
            } label: {
                Text("Merge into…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityIdentifier("transcripted.speakers.person.expansion.merge")
        }
    }

    private var nameSuggestions: [SpeakerNameChoice] {
        SpeakerNameSuggestionSource.options(from: model.profiles, excluding: profile.id)
    }

    private func commitRename() {
        guard SpeakerEveryoneRenamePolicy.acceptsSubmit(typed: nameDraft, saveInFlight: isSavingRename) else { return }
        let trimmed = nameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingRename = true
        renameErrorMessage = nil
        model.renameFromEveryone(profile, to: trimmed) { [id = profile.id] didSave in
            isSavingRename = false
            let box = SpeakerEveryoneRenamePolicy.nameBox(afterSave: didSave, typed: nameDraft)
            renameErrorMessage = box.errorMessage
            nameDraft = box.draft
            if !box.isOpen, expandedPersonID == id { expandedPersonID = nil } // only this card
        }
    }

    private var badge: String? {
        if model.duplicateCount(for: profile) > 0 {
            return "Possible duplicate"
        }
        if profile.disputeCount > 0 {
            return "Check name"
        }
        if model.reviewStack.isWaitingForReview(profile) {
            return SpeakerReviewStack.waitingBadgeTitle
        }
        return nil
    }

    private var hasClip: Bool {
        model.clipURL(for: profile.id) != nil
    }

    private var isPlaying: Bool {
        model.clipURL(for: profile.id).map(playback.isPlaying) ?? false
    }

    private func mergeLabel(for target: SpeakerProfile) -> String {
        let name = target.displayName ?? "Unknown voice"
        let meetings = target.callCount == 1 ? "1 meeting" : "\(target.callCount) meetings"
        return "\(name) (\(meetings))"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        return formatter
    }()
}

private struct SpeakerAvatarView: View {
    let name: String?

    var body: some View {
        Circle()
            .fill(color.opacity(0.16))
            .frame(width: 24, height: 24)
            .overlay(
                Text(initials)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color)
            )
    }

    private var initials: String {
        guard let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "?"
        }
        let words = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let letters = words.compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    private var color: Color {
        guard let name, !name.isEmpty else { return .secondary }
        return HomeMeetingSpeakerColor.color(for: name)
    }
}

/// Quiet inline status note next to a speaker's name — e.g. "Possible duplicate".
/// Plain ink text, no filled capsule: hierarchy comes from ink level, not a box.
private struct SpeakerStatusBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(LibraryTokens.meta.weight(.medium))
            .foregroundStyle(LibraryTokens.ink3)
            .lineLimit(1)
    }
}


private extension DateFormatter {
    func stringIfAvailable(from date: Date) -> String? {
        date == .distantPast ? nil : string(from: date)
    }
}
