import AppKit
import SwiftUI
import TranscriptedCore

/// A transcript row's clock time, shown only when the meeting kept its audio.
/// Clicking it plays the meeting from that moment.
struct QuietTranscriptTimestamp: View {
    let time: String
    let index: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text(time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isHovering ? LibraryTokens.accent : LibraryTokens.ink3)
                .underline(isHovering)
                .frame(width: 52, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Play from \(time)")
        .accessibilityLabel(Text("Play from \(time)"))
        .accessibilityIdentifier("transcripted.home.expansion.timestamp.\(index)")
    }
}

/// Prominent speaker identity used by every transcript line. It is a real
/// single-click button: the popover stages an edit and only writes on Save.
struct QuietMeetingSpeakerLabel: View {
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

struct HomeMeetingSpeakerPicker: View {
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

struct HomeMeetingSpeakerNamingSheet: View {
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

struct HomeMeetingSpeakerNamingRow: View {
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
