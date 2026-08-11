import AppKit
import SwiftUI
import TranscriptedCore

// Quiet-library Home components (2026-08 redesign).
//
// The Meetings page is a shelf, not a dashboard: one title, one sentence,
// then day-grouped captures. Rows lead with the title; duration is the only
// always-on metadata; time-of-day and actions reveal on hover. Opening a
// capture expands it in place — no sheet, no "Done" button.

// MARK: - Header

/// Page title plus the single status sentence. The sentence carries the
/// capture count and at most one attention clause, rendered as a link to
/// the place where the work lives.
struct QuietHomeHeader: View {
    let capturesToday: Int
    let attentionTitle: String?
    let onAttention: () -> Void
    let onToggleFind: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                // Same title treatment as SettingsPageIntro so Meetings,
                // Dictations, and Speakers read as siblings.
                Text("Meetings")
                    .font(LibraryTokens.title)
                Spacer()
                Button(action: onToggleFind) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(LibraryTokens.ink3)
                        .frame(width: 26, height: 26)
                        .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl))
                }
                .buttonStyle(.plain)
                .help("Find captures")
                .accessibilityIdentifier("transcripted.home.find.toggle")
            }

            HStack(spacing: 0) {
                Text(capturesSummary)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                if let attentionTitle {
                    Text("  ·  ")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink3)
                    Button(action: onAttention) {
                        Text(attentionTitle)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("transcripted.home.attention.link")
                }
            }
        }
    }

    private var capturesSummary: String {
        switch capturesToday {
        case 0: return "No captures yet today"
        case 1: return "1 capture today"
        default: return "\(capturesToday) captures today"
        }
    }
}

// MARK: - Rows

/// Title-first meeting row. Duration always visible; start time and actions
/// fade in on hover.
struct QuietMeetingRow: View {
    let item: RecentMeetingItem
    let isCopied: Bool
    let isExpanded: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let menuItems: [HomeRowMenuItem]
    var showsMicBoostHint: Bool = false

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            if showsMicBoostHint {
                Circle()
                    .fill(LibraryTokens.attention)
                    .frame(width: 6, height: 6)
                    .help("Your mic was muffled by another call app")
            }

            Text(item.title)
                .font(LibraryTokens.rowTitle)
                .lineLimit(1)
                .accessibilityIdentifier("transcripted.home.meeting.preview")

            Spacer(minLength: 12)

            // Always present so the row keeps one constant height; hover only
            // fades the actions in and tints the background — no size change.
            HStack(spacing: 10) {
                Text(startTimeString)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                HomeRowActionButtons(
                    isCopied: isCopied,
                    onCopy: onCopy,
                    menuItems: menuItems
                )
            }
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)

            if let durationString {
                Text(durationString)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 1, style: .continuous)
                .fill((isHovering || isExpanded) ? LibraryTokens.rowHover : Color.clear)
        )
        .padding(.horizontal, -10)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .onTapGesture(perform: onOpen)
        .help("Open capture")
    }

    private var startTimeString: String {
        HomeActivityRowFormatting.timeFormatter.string(from: item.startDate ?? item.date)
    }

    private var durationString: String? {
        guard let start = item.startDate, let end = item.endDate, end > start else { return nil }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        if minutes < 1 { return "<1 min" }
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "\(hours) hr" : "\(hours) hr \(rest) min"
    }
}

/// In-flight transcription rendered as a row-shaped status line instead of a
/// dashboard card. Appears above the day list while work is running.
struct QuietWorkingRow: View {
    let title: String
    let status: String
    let progress: Double?
    let onCancel: (() -> Void)?
    /// When non-nil, the session is actively recording: render a red dot and
    /// the live timer instead of a spinner. Stop stays in the menu bar and
    /// the recording overlay — Home only reflects the state.
    var recordingElapsed: String? = nil

    var body: some View {
        HStack(spacing: 10) {
            if let recordingElapsed {
                HStack(spacing: 8) {
                    Circle()
                        .fill(LibraryTokens.recording)
                        .frame(width: 7, height: 7)
                    Text("Recording")
                        .font(LibraryTokens.rowTitle)
                    Text("·  \(recordingElapsed)")
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Recording, \(recordingElapsed) elapsed")
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(LibraryTokens.rowTitle)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.mini)
                        Text(status)
                            .font(.system(size: 11.5))
                            .foregroundStyle(LibraryTokens.ink2)
                        if let progress, progress > 0 {
                            Text("\(Int(progress * 100))%")
                                .font(.system(size: 11.5))
                                .foregroundStyle(LibraryTokens.ink3)
                        }
                    }
                }
            }
            Spacer()
            if recordingElapsed == nil, let onCancel {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
                    .accessibilityIdentifier("transcripted.home.activity.cancel")
            }
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("transcripted.home.activity.row")
    }

    static func formatElapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%d:%02d", minutes, secs)
    }
}

// MARK: - Inline expansion

/// The opened capture: player, transcript, quiet text actions — revealed in
/// place within the list. Esc or the row click collapses it.
struct QuietMeetingExpansion: View {
    let item: RecentMeetingItem
    let preview: HomeMeetingPreview?
    let isCopied: Bool
    let onCopy: () -> Void
    let onRevealInFinder: () -> Void
    let onCollapse: () -> Void
    let knownPeople: [SpeakerIdentityOption]
    let savedSpeakerIDs: Set<UUID>
    let onAssignSpeakers: (
        [HomeMeetingSpeakerAssignment],
        @escaping (Bool) -> Void
    ) -> Void
    let menuItems: [HomeRowMenuItem]

    @State private var showsFullTranscript = false
    @State private var showsSpeakerNamingSheet = false

    private static let visibleLineLimit = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 15, weight: .semibold))
                        .accessibilityIdentifier("transcripted.home.expansion.title")
                    Text(metaLine)
                        .font(.system(size: 11.5))
                        .foregroundStyle(LibraryTokens.ink3)
                }
                Spacer()
                // Hidden control so Esc collapses the expansion.
                Button(action: onCollapse) { EmptyView() }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .frame(width: 0, height: 0)
                    .opacity(0)
                    .accessibilityHidden(true)
            }

            if let audio = item.audio {
                HomeMeetingPodcastPlayer(audio: audio)
                    .padding(.top, 12)
            }

            content
                .padding(.top, 12)

            HStack(spacing: 16) {
                quietAction(
                    title: isCopied ? "Copied" : "Copy",
                    symbol: isCopied ? "checkmark" : "square.on.square",
                    tint: isCopied ? LibraryTokens.accent : LibraryTokens.ink2,
                    action: onCopy
                )
                .accessibilityIdentifier("transcripted.home.expansion.copy")

                quietAction(
                    title: "Show in Finder",
                    symbol: "folder",
                    tint: LibraryTokens.ink2,
                    action: onRevealInFinder
                )
                .accessibilityIdentifier("transcripted.home.expansion.reveal")

                Spacer()

                if !menuItems.isEmpty {
                    HomeRowMoreMenuButton(
                        items: menuItems,
                        automationIdentifier: "transcripted.home.expansion.more"
                    )
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
                    .padding(.top, 6)
            }
        }
        .padding(18)
        .contentShape(Rectangle())
        // Swallow taps inside the card so the page-level background tap
        // catcher (click-away collapse) doesn't fire for clicks on the
        // expansion's own non-interactive areas.
        .onTapGesture {}
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .padding(.vertical, 6)
        .accessibilityIdentifier("transcripted.home.expansion")
        .sheet(isPresented: $showsSpeakerNamingSheet) {
            if let content = preview?.content {
                HomeMeetingSpeakerNamingSheet(
                    content: content,
                    knownPeople: knownPeople,
                    savedSpeakerIDs: savedSpeakerIDs,
                    onCancel: { showsSpeakerNamingSheet = false },
                    onSave: { assignments, completion in
                        onAssignSpeakers(assignments) { didSave in
                            if didSave { showsSpeakerNamingSheet = false }
                            completion(didSave)
                        }
                    }
                )
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let preview {
            if let readError = preview.readError {
                Text(readError)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.attention)
            } else {
                transcript(for: preview.content)
            }
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.mini)
                Text("Loading…")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func transcript(for content: HomeMeetingPreviewContent) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("TRANSCRIPT")
                    .font(LibraryTokens.label)
                    .tracking(LibraryTokens.labelTracking)
                    .foregroundStyle(LibraryTokens.ink3)
                    .help("Transcribed on this Mac")
                Spacer()
                if !content.transcriptLines.isEmpty {
                    Button {
                        showsSpeakerNamingSheet = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "person.2")
                                .font(.system(size: 10.5, weight: .medium))
                            Text("Name speakers")
                                .font(LibraryTokens.meta)
                        }
                        .foregroundStyle(LibraryTokens.ink2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Assign or correct every speaker in this meeting")
                    .accessibilityIdentifier("transcripted.home.expansion.name-speakers")
                }
            }

            if content.transcriptLines.isEmpty {
                Text(content.fallbackText)
                    .font(LibraryTokens.body)
                    .foregroundStyle(.primary)
                    .lineLimit(showsFullTranscript ? nil : 12)
                    .textSelection(.enabled)
            } else {
                let visibleIndices = showsFullTranscript
                    ? Array(content.transcriptLines.indices)
                    : Array(content.transcriptLines.indices.prefix(Self.visibleLineLimit))
                ForEach(visibleIndices, id: \.self) { index in
                    transcriptLine(content.transcriptLines[index])
                }
                if content.transcriptLines.count > Self.visibleLineLimit {
                    Button(showsFullTranscript
                        ? "Show less"
                        : "Show all \(content.transcriptLines.count) lines"
                    ) {
                        withAnimation(.snappy(duration: 0.2)) { showsFullTranscript.toggle() }
                    }
                    .buttonStyle(.plain)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
                .padding(.top, -6)
        }
    }

    private func transcriptLine(_ line: HomeMeetingTranscriptLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if !line.time.isEmpty {
                Text(line.time)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(LibraryTokens.ink3)
                    .frame(width: 52, alignment: .leading)
            }
            if !line.speaker.isEmpty {
                QuietMeetingSpeakerLabel(
                    identity: line.identity,
                    knownPeople: knownPeople,
                    isSavedPerson: identityIsSaved(line.identity),
                    onAssign: { assignment, completion in
                        onAssignSpeakers([assignment], completion)
                    }
                )
            }
            Text(line.text)
                .font(.system(size: 12.5))
                .foregroundStyle(.primary.opacity(0.9))
                .textSelection(.enabled)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
    }

    private func identityIsSaved(_ identity: HomeMeetingSpeakerIdentity) -> Bool {
        identity.persistentSpeakerID.map(savedSpeakerIDs.contains) ?? false
    }

    private func quietAction(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(LibraryTokens.meta)
            }
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var metaLine: String {
        var parts: [String] = []
        parts.append(Self.timeFormatter.string(from: item.startDate ?? item.date))
        if let start = item.startDate, let end = item.endDate, end > start {
            let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
            parts.append("\(minutes) min")
        }
        return parts.joined(separator: "  ·  ")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Prominent speaker identity used by every transcript line. It is a real
/// single-click button: the popover stages an edit and only writes on Save.
private struct QuietMeetingSpeakerLabel: View {
    let identity: HomeMeetingSpeakerIdentity
    let knownPeople: [SpeakerIdentityOption]
    let isSavedPerson: Bool
    let onAssign: (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void

    @State private var showsPicker = false
    @State private var isHovering = false

    private var canRename: Bool {
        !identity.displayName.isEmpty && identity.rawLabel != "Speaker"
    }

    var body: some View {
        Button {
            guard canRename else { return }
            showsPicker = true
        } label: {
            HStack(spacing: 4) {
                Text(identity.displayName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(speakerColor)
                    .underline(isHovering || showsPicker, color: speakerColor.opacity(0.72))
                    .lineLimit(1)
                if canRename {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(speakerColor.opacity(0.75))
                        .opacity((isHovering || showsPicker) ? 1 : 0.34)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRename)
        .onHover { isHovering = $0 }
        .contextMenu {
            if canRename {
                Button("Rename Speaker…") { showsPicker = true }
            }
        }
        .accessibilityLabel("Speaker: \(identity.displayName)")
        .accessibilityHint(canRename ? "Assign or correct this person" : "")
        .accessibilityAction(named: "Rename speaker") { showsPicker = true }
        .help(canRename ? "Assign or correct \(identity.displayName)" : "")
        .accessibilityIdentifier("transcripted.home.expansion.speaker.\(identity.stableID)")
        .frame(width: 116, alignment: .leading)
        .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
            HomeMeetingSpeakerPicker(
                identity: identity,
                knownPeople: knownPeople.filter { $0.id != identity.persistentSpeakerID },
                isSavedPerson: isSavedPerson,
                onCancel: { showsPicker = false },
                onSave: { assignment, completion in
                    onAssign(assignment) { didSave in
                        if didSave { showsPicker = false }
                        completion(didSave)
                    }
                }
            )
        }
    }

    private var speakerColor: Color {
        if identity.displayName == "You" { return LibraryTokens.accent }
        return HomeMeetingSpeakerColor.color(for: identity.stableID)
    }
}

private struct HomeMeetingSpeakerPicker: View {
    let identity: HomeMeetingSpeakerIdentity
    let knownPeople: [SpeakerIdentityOption]
    let isSavedPerson: Bool
    let onCancel: () -> Void
    let onSave: (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void

    @State private var nameDraft: String
    @State private var selectedProfileID: UUID?
    @State private var isSaving = false
    @State private var saveFailed = false

    init(
        identity: HomeMeetingSpeakerIdentity,
        knownPeople: [SpeakerIdentityOption],
        isSavedPerson: Bool,
        onCancel: @escaping () -> Void,
        onSave: @escaping (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void
    ) {
        self.identity = identity
        self.knownPeople = knownPeople
        self.isSavedPerson = isSavedPerson
        self.onCancel = onCancel
        self.onSave = onSave
        _nameDraft = State(initialValue: identity.displayName)
        _selectedProfileID = State(initialValue: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Who is this?")
                    .font(.system(size: 15, weight: .semibold))
                Text(scopeMessage)
                    .font(.system(size: 11.5))
                    .foregroundStyle(LibraryTokens.ink2)
            }

            SpeakerNameAutocompleteField(
                text: $nameDraft,
                placeholder: "Type a name",
                options: knownPeople,
                selectedOptionID: $selectedProfileID,
                showAllWhenTextEquals: identity.displayName,
                accessibilityIdentifier: "transcripted.home.speaker-picker.name",
                autoFocus: true,
                onSubmit: save,
                onCancel: onCancel
            )
            .frame(height: 28)

            if saveFailed {
                Text("Couldn’t save that name. Nothing else was changed.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(LibraryTokens.attention)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("transcripted.home.speaker-picker.cancel")
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(assignment == nil || isSaving)
                    .accessibilityIdentifier("transcripted.home.speaker-picker.save")
            }
        }
        .padding(16)
        .frame(width: 340)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.speaker-picker")
        .onChange(of: nameDraft) { _, _ in saveFailed = false }
    }

    private var assignment: HomeMeetingSpeakerAssignment? {
        HomeMeetingSpeakerNamingPolicy.assignment(from: HomeMeetingSpeakerNamingDraft(
            identity: identity,
            sampleTexts: [],
            name: nameDraft,
            selectedProfileID: selectedProfileID
        ))
    }

    private var scopeMessage: String {
        if isSavedPerson {
            return selectedProfileID == nil
                ? "Renames this saved person in linked meetings."
                : "Uses this saved person in linked meetings."
        }
        return selectedProfileID == nil
            ? "Updates this meeting only."
            : "Links this voice to the saved person."
    }

    private func save() {
        guard let assignment, !isSaving else { return }
        isSaving = true
        saveFailed = false
        onSave(assignment) { didSave in
            isSaving = false
            saveFailed = !didSave
        }
    }
}

private struct HomeMeetingSpeakerNamingSheet: View {
    let knownPeople: [SpeakerIdentityOption]
    let savedSpeakerIDs: Set<UUID>
    let onCancel: () -> Void
    let onSave: ([HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void
    private let initialDrafts: [HomeMeetingSpeakerNamingDraft]

    @State private var drafts: [HomeMeetingSpeakerNamingDraft]
    @State private var isSaving = false
    @State private var saveFailed = false

    init(
        content: HomeMeetingPreviewContent,
        knownPeople: [SpeakerIdentityOption],
        savedSpeakerIDs: Set<UUID>,
        onCancel: @escaping () -> Void,
        onSave: @escaping ([HomeMeetingSpeakerAssignment], @escaping (Bool) -> Void) -> Void
    ) {
        let initialDrafts = HomeMeetingSpeakerNamingPolicy.drafts(from: content.transcriptLines)
        self.knownPeople = knownPeople
        self.savedSpeakerIDs = savedSpeakerIDs
        self.onCancel = onCancel
        self.onSave = onSave
        self.initialDrafts = initialDrafts
        _drafts = State(initialValue: initialDrafts)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Name speakers")
                        .font(.system(size: 22, weight: .semibold))
                    Text("Give each voice a name and we’ll relabel the whole transcript.")
                        .font(LibraryTokens.body)
                        .foregroundStyle(LibraryTokens.ink2)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Cancel")
                .accessibilityIdentifier("transcripted.home.speaker-sheet.close")
            }
            .padding(20)

            Divider().opacity(0.55)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if hasLocalAndRemoteSpeakers {
                        section("PEOPLE IN THE ROOM", channel: .mic)
                        section("REMOTE PARTICIPANTS", channel: .system)
                        section("OTHER SPEAKERS", channel: nil)
                    } else {
                        ForEach(drafts.indices, id: \.self) { index in
                            speakerRow(at: index)
                        }
                    }
                }
                .padding(20)
            }

            Divider().opacity(0.55)

            HStack(spacing: 10) {
                if saveFailed {
                    Text("One or more names couldn’t be saved. Try again.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(LibraryTokens.attention)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("transcripted.home.speaker-sheet.cancel")
                Button(isSaving ? "Saving…" : "Save names", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(assignments.isEmpty || isSaving)
                    .accessibilityIdentifier("transcripted.home.speaker-sheet.save")
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 680, minHeight: 440, idealHeight: 560)
        .background(LibraryTokens.contentBackground)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("transcripted.home.speaker-sheet")
        .onAppear {
            // SwiftUI can reuse sheet state across presentations. Always start
            // from the latest persisted transcript, never an old cancelled or
            // previously-saved draft.
            drafts = initialDrafts
            isSaving = false
            saveFailed = false
        }
        .onChange(of: drafts) { _, _ in saveFailed = false }
    }

    @ViewBuilder
    private func section(_ title: String, channel: HomeMeetingSpeakerChannel?) -> some View {
        let indices = drafts.indices.filter { drafts[$0].identity.channel == channel }
        if !indices.isEmpty {
            Text(title)
                .font(LibraryTokens.label)
                .tracking(LibraryTokens.labelTracking)
                .foregroundStyle(LibraryTokens.ink3)
                .padding(.top, 2)
            ForEach(indices, id: \.self) { index in
                speakerRow(at: index)
            }
        }
    }

    private func speakerRow(at index: Int) -> some View {
        HomeMeetingSpeakerNamingRow(
            draft: $drafts[index],
            knownPeople: knownPeople.filter { $0.id != drafts[index].identity.persistentSpeakerID },
            isSavedPerson: drafts[index].identity.persistentSpeakerID
                .map(savedSpeakerIDs.contains) ?? false
        )
    }

    private var hasLocalAndRemoteSpeakers: Bool {
        drafts.contains { $0.identity.channel == .mic }
            && drafts.contains { $0.identity.channel == .system }
    }

    private var assignments: [HomeMeetingSpeakerAssignment] {
        HomeMeetingSpeakerNamingPolicy.assignments(from: drafts)
    }

    private func save() {
        let assignments = assignments
        guard !assignments.isEmpty, !isSaving else { return }
        isSaving = true
        saveFailed = false
        onSave(assignments) { didSave in
            isSaving = false
            saveFailed = !didSave
        }
    }
}

private struct HomeMeetingSpeakerNamingRow: View {
    @Binding var draft: HomeMeetingSpeakerNamingDraft
    let knownPeople: [SpeakerIdentityOption]
    let isSavedPerson: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Circle()
                    .fill(speakerColor)
                    .frame(width: 8, height: 8)
                Text(draft.identity.displayName)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(scopeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(LibraryTokens.ink3)
            }

            ForEach(draft.sampleTexts, id: \.self) { sample in
                Text("“\(sample)”")
                    .font(.system(size: 12.5))
                    .foregroundStyle(LibraryTokens.ink2)
                    .lineLimit(2)
                    .padding(.leading, 17)
            }

            SpeakerNameAutocompleteField(
                text: $draft.name,
                placeholder: "Type a name",
                options: knownPeople,
                selectedOptionID: $draft.selectedProfileID,
                showAllWhenTextEquals: draft.identity.displayName,
                accessibilityIdentifier: "transcripted.home.speaker-sheet.row.\(draft.id).name",
                onSubmit: {}
            )
            .frame(height: 30)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .accessibilityIdentifier("transcripted.home.speaker-sheet.row.\(draft.id)")
    }

    private var speakerColor: Color {
        if draft.identity.displayName == "You" { return LibraryTokens.accent }
        return HomeMeetingSpeakerColor.color(for: draft.identity.stableID)
    }

    private var scopeLabel: String {
        isSavedPerson ? "Linked meetings" : "This meeting"
    }
}

// MARK: - Background tap catcher

/// Makes a container's full bounds hit-testable so a tap on otherwise-empty
/// space (the gaps around rows, day-group padding, the space below the last
/// row) can be caught by the shell — typically to collapse an open
/// `QuietMeetingExpansion`. Apply to the list container, not individual
/// rows: SwiftUI resolves gestures on the innermost view that recognizes
/// them first, so a row's own `onTapGesture` (open/toggle) or a button
/// inside the expansion still wins over this background catcher.
private struct HomeBackgroundTapCatcherModifier: ViewModifier {
    let onTap: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
    }
}

extension View {
    /// See `HomeBackgroundTapCatcherModifier`. Wire `onTap` to collapse the
    /// currently-open Home meeting expansion.
    func homeBackgroundTapCatcher(onTap: @escaping () -> Void) -> some View {
        modifier(HomeBackgroundTapCatcherModifier(onTap: onTap))
    }
}
