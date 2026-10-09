// SpeakerPeoplePersonRow.swift
// One saved person in Settings › Speakers: their voice print (play in the
// center plays their saved clip), name, meetings and the day last heard, and how far
// they are from being named on their own. Hover shows ••• with rename, merge,
// undo merge and delete; a click opens the card in place. Sections and
// copy: SpeakerPeoplePrintSections.swift and SpeakerPrintDirectory.swift.

import SwiftUI
import AppKit
import TranscriptedCore

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

    @Environment(\.colorScheme) private var colorScheme

    private var isExpandedRow: Bool { expandedPersonID == profile.id }

    /// ••• stays hidden until hover; the print is always there.
    private var showsRowActions: Bool { isHovering }

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
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(profile.displayName == nil ? LibraryTokens.ink2 : Color.primary)
                            .lineLimit(1)

                        if let badge {
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
                }
                .help(standingExplanation ?? "Open speaker")
                .accessibilityHint(standingExplanation ?? "")

                Spacer(minLength: 12)

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
                RoundedRectangle(cornerRadius: 12, style: .continuous)
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
        SpeakerPrintDirectory.metaLine(meetings: profile.callCount, lastHeard: profile.lastSeen, now: Date())
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
