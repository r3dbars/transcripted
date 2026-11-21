import SwiftUI

/// Prominent speaker identity used by every transcript line: the quick fix
/// for one voice. It is a real single-click button: the popover stages an
/// edit and only writes on Save. Naming every voice at once is the meeting's
/// "Who spoke?" card on Speakers.
struct QuietMeetingSpeakerLabel: View {
    let identity: HomeMeetingSpeakerIdentity
    let knownPeople: [SpeakerNameChoice]
    let isSavedPerson: Bool
    /// The fixed name column, or nil to size to the name (the Meetings card's
    /// inline "Name text" lines).
    var columnWidth: CGFloat? = 116
    /// The faint chevron beside the name when the pointer is elsewhere. The
    /// Meetings transcript hides it until hover, so lines read as "Name words".
    var showsChevronAtRest = true
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
                    .font(TextRole.body.font(weight: .semibold))
                    .foregroundStyle(speakerColor)
                    .underline(isHovering || showsPicker, color: speakerColor.opacity(0.72))
                    .lineLimit(1)
                if canRename {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(speakerColor.opacity(0.75))
                        .opacity((isHovering || showsPicker) ? 1 : (showsChevronAtRest ? 0.34 : 0))
                }
            }
            .frame(maxWidth: columnWidth == nil ? nil : .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRename)
        .onHover { isHovering = $0 }
        .contextMenu {
            if canRename {
                Button("Rename…") { showsPicker = true }
            }
        }
        .accessibilityLabel("Speaker: \(identity.displayName)")
        .accessibilityHint(canRename ? "Assign or correct this person" : "")
        .accessibilityAction(named: "Rename speaker") { showsPicker = true }
        .help(canRename ? "Assign or correct \(identity.displayName)" : "")
        .accessibilityIdentifier("transcripted.home.expansion.speaker.\(identity.stableID)")
        .frame(width: columnWidth, alignment: .leading)
        .fixedSize(horizontal: columnWidth == nil, vertical: false)
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
        if identity.displayName == "You" { return LibraryTokens.ink }
        return HomeMeetingSpeakerColor.color(for: identity)
    }
}

struct HomeMeetingSpeakerPicker: View {
    let identity: HomeMeetingSpeakerIdentity
    let knownPeople: [SpeakerNameChoice]
    let isSavedPerson: Bool
    let onCancel: () -> Void
    let onSave: (HomeMeetingSpeakerAssignment, @escaping (Bool) -> Void) -> Void

    @State private var nameDraft: String
    @State private var selectedProfileID: UUID?
    @State private var isSaving = false
    @State private var saveFailed = false

    init(
        identity: HomeMeetingSpeakerIdentity,
        knownPeople: [SpeakerNameChoice],
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
                Text("Who\u{2019}s this?")
                    .font(TextRole.heading.font())
                Text(scopeMessage)
                    .font(TextRole.small.font())
                    .foregroundStyle(LibraryTokens.ink2)
                    .accessibilityIdentifier("transcripted.home.speaker-picker.voiceprint-notice")
            }

            SpeakerNameAutocompleteField(
                text: $nameDraft,
                placeholder: "Who\u{2019}s this?",
                options: knownPeople,
                selectedOptionID: $selectedProfileID,
                untouchedPrefill: identity.displayName,
                accessibilityIdentifier: "transcripted.home.speaker-picker.name",
                autoFocus: true,
                onSubmit: save,
                onCancel: onCancel
            )

            if saveFailed {
                Text("Couldn’t save that name. Nothing else was changed.")
                    .font(TextRole.small.font())
                    .foregroundStyle(LibraryTokens.attention)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.transcriptedQuiet)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("transcripted.home.speaker-picker.cancel")
                Button(isSaving ? "Saving…" : "Save", action: save)
                    .buttonStyle(.transcriptedPrimary)
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
        HomeMeetingSpeakerNamingCopy.pickerScope(
            isSavedPerson: isSavedPerson,
            selectedProfileID: selectedProfileID
        )
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
