// SpeakerPeoplePersonRow.swift
// One saved person in Settings › Speakers: their voice print (play in the
// center plays their saved clip), name, meetings and the day last heard, and how far
// they are from being named on their own ("4 of 5"). Hover shows ••• with
// rename, merge, undo merge and delete; a click opens the rename field in
// place; a likely duplicate says who ("Same as Marcus?") and opens the merge
// confirm. Sections and copy: SpeakerPeoplePrintSections.swift and
// SpeakerPrintDirectory.swift.

import SwiftUI
import AppKit
import TranscriptedCore

struct SpeakerPersonRow: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    /// Observed directly so play/stop/finish reliably re-renders THIS row.
    @ObservedObject private var playback = SpeakerClipPlayback.shared
    /// Lifted to the parent list so opening one person closes any other —
    /// "one person open at a time", per spec.
    @Binding var expandedPersonID: UUID?

    @State private var nameDraft: String = ""
    @State private var renameErrorMessage: String?
    @State private var isSavingRename = false
    @State private var showDeleteConfirmation = false
    @State private var actionErrorMessage: String?
    @State private var pendingMergeTarget: SpeakerProfile?
    @State private var showMergeConfirmation = false
    @State private var showUnmergeConfirmation = false

    @State private var isHovering = false

    @Environment(\.colorScheme) private var colorScheme

    private var isExpandedRow: Bool { expandedPersonID == profile.id }

    /// ••• shows on hover and while the person is open, so a keyboard or
    /// VoiceOver user who opens a row can reach Merge into and Delete.
    private var showsRowActions: Bool { isHovering || isExpandedRow }

    /// Print size in Settings, from the approved mockup.
    static let printDiameter: CGFloat = 36

    var body: some View {
        let printRow = SpeakerPrintDirectory.row(standing: standing)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                // The print is the play button: a click (or Space / Return,
                // or VoiceOver's press) plays this person's saved clip.
                // Without a clip it's only a picture and a click on it opens
                // the card like the rest of the row.
                VoicePrintRepresentable(
                    model: VoicePrintView.Model(
                        style: printStyle,
                        colorIndex: printStyle.preferredColorIndex,
                        litRings: printRow.litRings,
                        surface: colorScheme == .dark ? .settingsDark : .settingsLight
                    ),
                    diameter: Self.printDiameter,
                    isPlaying: isPlaying,
                    accessibilityName: profile.displayName,
                    // A yes for them from this page (a voice joined them)
                    // plays the island's match animation here too.
                    celebrateToken: model.celebrationTokens[profile.id] ?? 0,
                    onPlay: hasClip ? { model.playSample(for: profile.id) } : nil,
                    accessibilityIdentifier: "transcripted.speakers.person.play"
                )
                .frame(width: Self.printDiameter, height: Self.printDiameter)
                // The AppKit print still gets the click (and plays), but the
                // row's tap below would fire too, so a no-op tap here claims
                // it first. Off without a clip: the print passes clicks
                // through and the row opens.
                .gesture(TapGesture().onEnded {}, including: hasClip ? .all : .none)
                .help(SpeakerClipPlaybackPresentation.helpText(hasClip: hasClip, isPlaying: isPlaying))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(TextRole.body.font(weight: .semibold))
                            .foregroundStyle(profile.displayName == nil ? LibraryTokens.ink2 : Color.primary)
                            .lineLimit(1)

                        if let duplicate = likelyDuplicate {
                            // Says who, and one click asks to merge them.
                            Button {
                                pendingMergeTarget = duplicate
                                showMergeConfirmation = true
                            } label: {
                                SpeakerStatusBadge(title: SpeakerVoiceRowMenuPolicy.sameAsTitle(for: duplicate.displayName))
                                    .underline(pattern: .dot)
                            }
                            .buttonStyle(.plain)
                            .help("Merge into \(SpeakerDuplicateCandidate.displayName(for: duplicate))")
                            .accessibilityIdentifier("transcripted.speakers.person.same-as")
                        } else if let badge {
                            SpeakerStatusBadge(title: badge)
                        }
                    }

                    HStack(spacing: 8) {
                        Text(metadataLine)
                            .font(LibraryTokens.meta)
                            .monospacedDigit()
                            .foregroundStyle(LibraryTokens.ink2)
                            .lineLimit(1)

                        if let hint = printRow.hint {
                            Text(hint.text)
                                .font(LibraryTokens.meta.weight(.medium))
                                .foregroundStyle(hint.usesPersonColor ? personTextColor : LibraryTokens.ink2)
                                .lineLimit(1)
                                .fixedSize()
                        }
                    }

                    if let quote = displayedQuote {
                        Text("“\(quote)”")
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                            .lineLimit(2)
                    }
                }
                .help(standingExplanation ?? (profile.displayName == nil ? "Name this voice" : "Rename"))
                .accessibilityHint(standingExplanation ?? "")

                Spacer(minLength: 12)

                // An unnamed voice says what to do with it.
                if profile.displayName == nil, !isExpandedRow {
                    Button("Name") { toggleExpansion() }
                        .buttonStyle(.transcriptedQuiet)
                        .controlSize(.small)
                        .accessibilityIdentifier("transcripted.speakers.person.name")
                }

                // Always present so the row keeps one constant height; hover
                // only fades ••• in and tints the background, no size change,
                // matching the Meetings/Dictations rows.
                rowMenu
                    .opacity(showsRowActions ? 1 : 0)
                    .allowsHitTesting(showsRowActions)
                    .accessibilityHidden(!showsRowActions)
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                    .fill((isHovering || isExpandedRow) ? LibraryTokens.rowHover : Color.clear)
            )
            .padding(.horizontal, -12)
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
            }
            // Clicking a print with a clip plays it without opening or
            // closing the card (its own tap gesture above wins); ••• opens
            // its menu. Anywhere else on the row toggles the card.
            .onTapGesture { toggleExpansion() }
            .accessibilityIdentifier("transcripted.speakers.person.row")

            if let actionErrorMessage {
                Text(actionErrorMessage)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.attention)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isExpandedRow {
                expansionCard
            }
        }
        .alert(deleteConfirmationTitle, isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                actionErrorMessage = nil
                model.delete(profile: profile) { didDelete in
                    actionErrorMessage = SpeakerVoiceRowMenuPolicy.deleteErrorMessage(didDelete: didDelete)
                }
            }
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("Removes their voice and its sample. Transcripts keep the name.")
        }
        .alert(
            mergeConfirmationTitle,
            isPresented: $showMergeConfirmation,
            presenting: pendingMergeTarget
        ) { target in
            Button("Merge") {
                actionErrorMessage = nil
                model.merge(source: profile, into: target) { didMerge in
                    actionErrorMessage = didMerge ? nil : "Couldn't merge them. Try again."
                }
                // Only collapse an expansion that belongs to the merge —
                // an unrelated open speaker (and its rename draft) stays put.
                if expandedPersonID == profile.id || expandedPersonID == target.id {
                    expandedPersonID = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Combines their voices and renames past transcripts. You can undo it from •••; past transcripts keep the merged name.")
        }
        .alert(unmergeConfirmationTitle, isPresented: $showUnmergeConfirmation) {
            Button("Undo merge") {
                model.unmerge(into: profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Splits them again for future meetings. Past transcripts keep the merged name.")
        }
    }

    private func toggleExpansion() {
        expandedPersonID = isExpandedRow ? nil : profile.id
    }

    private var rowMenu: some View {
        Menu {
            Button(profile.displayName == nil ? "Name…" : "Rename…") {
                expandedPersonID = profile.id
            }

            let mergeTargets = model.mergeTargets(for: profile)
            if !mergeTargets.isEmpty {
                Menu("Merge into") {
                    ForEach(mergeTargets, id: \.id) { target in
                        Button(mergeLabel(for: target)) {
                            pendingMergeTarget = target
                            showMergeConfirmation = true
                        }
                    }
                }
            }

            if model.undoableMerge(for: profile) != nil {
                Button("Undo merge…") {
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
        .help("Rename, merge or delete")
        .accessibilityLabel(profile.displayName == nil ? "Voice actions" : "Person actions")
        .accessibilityIdentifier("transcripted.speakers.person.menu")
    }

    private var displayName: String {
        profile.displayName ?? "Unknown voice"
    }

    private var mergeConfirmationTitle: String {
        let source = SpeakerDuplicateCandidate.displayName(for: profile)
        guard let pendingMergeTarget else {
            return "Merge “\(source)” into someone else?"
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
        SpeakerPrintDirectory.metaLine(meetings: profile.callCount, lastHeard: profile.lastSeen, now: Date())
    }

    // MARK: - Expansion

    /// The opened row, in place: just the rename field (the row above is
    /// still the identity, the print still plays, ••• still merges and
    /// deletes), plus, for an unnamed voice with a queued meeting, saved
    /// people still learning as one-click names.
    private var expansionCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            expansionNameField
            if !joinChips.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Or one of these. It counts as a yes for them.")
                        .font(TextRole.small.font())
                        .foregroundStyle(LibraryTokens.ink3)
                    HStack(spacing: 6) {
                        ForEach(joinChips) { chip in
                            SpeakerNameChipButton(chip: chip, isDisabled: isSavingRename) {
                                if let person = chip.person { join(person) }
                            }
                        }
                    }
                }
                .accessibilityIdentifier("transcripted.speakers.person.expansion.join")
            }
            if let renameErrorMessage {
                Text(renameErrorMessage).font(LibraryTokens.meta).foregroundStyle(LibraryTokens.attention)
            }
        }
        .padding(.leading, Self.printDiameter + 14)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        // Swallow taps inside the card so the section's background tap
        // catcher (click-away collapse) doesn't fire for clicks on the
        // card's own non-interactive areas — same trick as
        // `QuietMeetingExpansion`.
        .onTapGesture {}
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
        }
        .onChange(of: nameDraft) { _, _ in renameErrorMessage = nil }
        .accessibilityIdentifier("transcripted.speakers.person.expansion")
    }

    private var expansionNameField: some View {
        SpeakerNameAutocompleteField(
            text: $nameDraft,
            placeholder: "Who\u{2019}s this?",
            options: nameSuggestions,
            accessibilityIdentifier: "transcripted.speakers.person.expansion.name",
            onSubmit: commitRename
        )
        .frame(minWidth: 180, maxWidth: 280)
    }

    private var nameSuggestions: [SpeakerNameChoice] {
        SpeakerNameSuggestionSource.options(from: model.profiles, excluding: profile.id)
    }

    /// For an unnamed voice that still has a queued meeting: saved people
    /// still learning, offered the way its review card offers them.
    private var joinChips: [SpeakerNameChip] {
        guard profile.displayName == nil, model.canJoinSavedPerson(profile) else { return [] }
        return model.savedPeopleStillLearning(excluding: [], limit: 3)
            .filter { $0.id != profile.id }
            .compactMap { person in
                person.displayName.map {
                    SpeakerNameChip(name: $0, person: person, standing: model.namingStanding(for: person), isInvitee: false)
                }
            }
    }

    private func join(_ person: SpeakerProfile) {
        guard !isSavingRename else { return }
        isSavingRename = true
        renameErrorMessage = nil
        model.joinSavedPerson(profile, into: person) { didSave in
            isSavingRename = false
            if didSave {
                expandedPersonID = nil
            } else {
                renameErrorMessage = "Couldn't save — the meeting file may have moved."
            }
        }
    }

    private func commitRename() {
        guard SpeakerEveryoneRenamePolicy.acceptsSubmit(typed: nameDraft, saveInFlight: isSavingRename) else { return }
        let submittedDraft = nameDraft
        let trimmed = submittedDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        isSavingRename = true
        renameErrorMessage = nil
        model.renameFromEveryone(profile, to: trimmed) { [id = profile.id] didSave in
            isSavingRename = false
            let box = SpeakerEveryoneRenamePolicy.nameBox(afterSave: didSave, typed: nameDraft, submitted: submittedDraft)
            renameErrorMessage = box.errorMessage
            nameDraft = box.draft
            if !box.isOpen, expandedPersonID == id { expandedPersonID = nil } // only this card
        }
    }

    /// Someone this voice is probably the same as: the first merge target,
    /// since duplicates sort first there.
    private var likelyDuplicate: SpeakerProfile? {
        guard model.duplicateCount(for: profile) > 0 else { return nil }
        return model.mergeTargets(for: profile).first
    }

    private var deleteConfirmationTitle: String {
        guard let name = profile.displayName, !name.isEmpty else { return "Delete this voice?" }
        return "Delete \(name)?"
    }

    private var badge: String? {
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

    /// While this row's clip plays, show the quote that was checked against
    /// the same bytes that started, not a later live reread.
    private var displayedQuote: String? {
        if let url = model.clipURL(for: profile.id), playback.isPlaying(url) {
            return playback.activeValidatedQuote
        }
        return model.clipSampleText(for: profile.id)
    }

    // MARK: - Voice print

    /// Nil for a voice with no name yet.
    private var standing: SpeakerNamingStanding? {
        model.namingStanding(for: profile)
    }

    /// Settings lists everyone at once, so each person keeps their own
    /// preferred color (no per-call de-duplication as in the island).
    private var printStyle: VoicePrintStyle {
        VoicePrintStyle(id: profile.id)
    }

    /// "One more yes" in the person's print color, a darker shade of it on
    /// a light window so the small text stays readable.
    private var personTextColor: Color {
        SpeakerPrintInk.hintColor(for: profile.id, colorScheme: colorScheme)
    }

    /// Hover and VoiceOver hint: how far this person is from being named on
    /// their own. Nil for an unnamed voice.
    private var standingExplanation: String? {
        guard let standing else { return nil }
        return SpeakerNamingTierPresentation.explanation(
            name: displayName,
            confirmed: standing.confirmedMeetings,
            required: standing.requiredMeetings,
            tier: standing.tier,
            isTrusted: standing.isTrusted
        )
    }

    private func mergeLabel(for target: SpeakerProfile) -> String {
        let name = target.displayName ?? "Unknown voice"
        let meetings = target.callCount == 1 ? "1 meeting" : "\(target.callCount) meetings"
        return "\(name) (\(meetings))"
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
