import SwiftUI

/// Speaker voice fingerprint management view
/// Clean, minimal — always-visible actions, simple avatars
@available(macOS 14.0, *)
struct SpeakersView: View {

    @State private var speakers: [SpeakerProfile] = []
    @State private var searchText = ""
    @State private var editingId: UUID?
    @State private var editingName: String = ""
    @State private var deleteConfirmId: UUID?

    private var filteredSpeakers: [SpeakerProfile] {
        if searchText.isEmpty {
            return speakers
        }
        let query = searchText.lowercased()
        return speakers.filter {
            ($0.displayName?.lowercased().contains(query) ?? false) ||
            $0.id.uuidString.lowercased().contains(query)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header
                headerSection

                // Search (show when >5 speakers)
                if speakers.count > 5 {
                    searchField
                }

                // Speaker list
                if filteredSpeakers.isEmpty {
                    emptyState
                } else {
                    speakerList
                }
            }
            .padding(Spacing.xl)
        }
        .background(Color.panelCharcoal)
        .onAppear { loadSpeakers() }
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Voice Fingerprints")
                    .font(.headingLarge)
                    .foregroundColor(.panelTextPrimary)

                Spacer()

                Text("\(speakers.count) speaker\(speakers.count == 1 ? "" : "s")")
                    .font(.bodySmall)
                    .foregroundColor(.panelTextMuted)
            }

            Text("Speakers are automatically identified by their voice. Names can be set manually or learned from meeting context.")
                .font(.bodySmall)
                .foregroundColor(.panelTextSecondary)
        }
    }

    // MARK: - Search

    private var searchField: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.panelTextMuted)

            TextField("Search speakers...", text: $searchText)
                .textFieldStyle(.plain)
                .foregroundColor(.panelTextPrimary)
        }
        .padding(Spacing.sm)
        .background {
            RoundedRectangle(cornerRadius: Radius.lawsButton)
                .fill(Color.panelCharcoalSurface)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "person.2.slash")
                .font(.system(size: 40))
                .foregroundColor(.panelTextMuted)

            if searchText.isEmpty {
                Text("No speakers yet")
                    .font(.headingSmall)
                    .foregroundColor(.panelTextSecondary)

                Text("Speakers will appear here after your first recorded call with system audio.")
                    .font(.bodySmall)
                    .foregroundColor(.panelTextMuted)
                    .multilineTextAlignment(.center)
            } else {
                Text("No matching speakers")
                    .font(.headingSmall)
                    .foregroundColor(.panelTextSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.xxl)
    }

    // MARK: - Speaker List

    private var speakerList: some View {
        VStack(spacing: Spacing.sm) {
            ForEach(filteredSpeakers) { speaker in
                SpeakerRow(
                    speaker: speaker,
                    isEditing: editingId == speaker.id,
                    editingName: editingId == speaker.id ? $editingName : .constant(""),
                    showDeleteConfirm: deleteConfirmId == speaker.id,
                    onStartEdit: {
                        editingName = speaker.displayName ?? ""
                        editingId = speaker.id
                    },
                    onCommitEdit: {
                        commitNameEdit(for: speaker.id)
                    },
                    onCancelEdit: {
                        editingId = nil
                    },
                    onRequestDelete: {
                        deleteConfirmId = speaker.id
                    },
                    onConfirmDelete: {
                        deleteSpeaker(id: speaker.id)
                    },
                    onCancelDelete: {
                        deleteConfirmId = nil
                    }
                )
            }
        }
    }

    // MARK: - Actions

    private func loadSpeakers() {
        speakers = SpeakerDatabase.shared.allSpeakers()
    }

    private func commitNameEdit(for id: UUID) {
        let trimmed = editingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            editingId = nil
            return
        }
        SpeakerDatabase.shared.setDisplayName(id: id, name: trimmed, source: "user_manual")
        editingId = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            loadSpeakers()
        }
    }

    private func deleteSpeaker(id: UUID) {
        SpeakerDatabase.shared.deleteSpeaker(id: id)
        deleteConfirmId = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            loadSpeakers()
        }
    }
}

// MARK: - Speaker Row

@available(macOS 14.0, *)
struct SpeakerRow: View {

    let speaker: SpeakerProfile
    let isEditing: Bool
    @Binding var editingName: String
    let showDeleteConfirm: Bool
    let onStartEdit: () -> Void
    let onCommitEdit: () -> Void
    let onCancelEdit: () -> Void
    let onRequestDelete: () -> Void
    let onConfirmDelete: () -> Void
    let onCancelDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.md) {
            // Simple gray avatar
            ZStack {
                Circle()
                    .fill(Color.panelCharcoalSurface)
                    .frame(width: 36, height: 36)

                Text(avatarInitial)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.panelTextSecondary)
            }

            // Name + meta
            VStack(alignment: .leading, spacing: 2) {
                if isEditing {
                    TextField("Speaker name", text: $editingName, onCommit: onCommitEdit)
                        .textFieldStyle(.plain)
                        .font(.bodyMedium)
                        .foregroundColor(.panelTextPrimary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background {
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.panelCharcoalSurface)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 4)
                                        .stroke(Color.accentBlue, lineWidth: 1)
                                }
                        }
                        .onExitCommand(perform: onCancelEdit)
                } else {
                    HStack(spacing: Spacing.xs) {
                        Text(speaker.displayName ?? "Unknown")
                            .font(.bodyMedium)
                            .foregroundColor(speaker.displayName != nil ? .panelTextPrimary : .panelTextMuted)
                            .italic(speaker.displayName == nil)

                        if speaker.displayName == nil {
                            Button(action: onStartEdit) {
                                Text("Set name")
                                    .font(.caption)
                                    .foregroundColor(.accentBlue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .onTapGesture {
                        if speaker.displayName != nil {
                            onStartEdit()
                        }
                    }
                }

                // Meta line
                HStack(spacing: Spacing.sm) {
                    Text(confidenceLabel)
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)

                    Text("\(speaker.callCount) call\(speaker.callCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)

                    Text("Last seen \(relativeDate(speaker.lastSeen))")
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                }
            }

            Spacer()

            // Actions — always visible
            if showDeleteConfirm {
                HStack(spacing: Spacing.xs) {
                    Text("Delete?")
                        .font(.caption)
                        .foregroundColor(.errorRed)

                    Button("Yes") { onConfirmDelete() }
                        .buttonStyle(SettingsDestructiveButtonStyle())

                    Button("No") { onCancelDelete() }
                        .buttonStyle(SettingsSecondaryButtonStyle())
                }
            } else {
                HStack(spacing: Spacing.xs) {
                    if !isEditing && speaker.displayName != nil {
                        Button(action: onStartEdit) {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(SettingsIconButtonStyle())
                        .help("Edit name")
                    }

                    Button(action: onRequestDelete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(SettingsIconButtonStyle())
                    .help("Delete speaker")
                }
            }
        }
        .padding(Spacing.md)
        .background {
            RoundedRectangle(cornerRadius: Radius.lawsCard)
                .fill(Color.panelCharcoalElevated)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Radius.lawsCard)
                .stroke(Color.panelCharcoalSurface, lineWidth: 1)
        }
    }

    // MARK: - Components

    private var avatarInitial: String {
        if let name = speaker.displayName, let first = name.first {
            return String(first).uppercased()
        }
        return "?"
    }

    private var confidenceLabel: String {
        if speaker.confidence >= 0.8 {
            return "High"
        } else if speaker.confidence >= 0.6 {
            return "Medium"
        }
        return "Low"
    }

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    SpeakersView()
        .frame(width: 600, height: 500)
        .background(Color.panelCharcoal)
}
