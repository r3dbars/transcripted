import SwiftUI
import AppKit
import TranscriptedCore

@MainActor
final class SpeakerPeopleSettingsViewModel: ObservableObject {
    @Published var profiles: [SpeakerProfile] = []
    @Published var searchText: String = ""

    private let speakerDatabase: SpeakerDatabase
    private let transcriptsDirectory: URL
    private let preferredClipsDirectory: URL
    private let legacyClipsDirectory: URL

    init(
        speakerDatabase: SpeakerDatabase,
        transcriptsDirectory: URL,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL = CoreStoragePaths.default.speakerClips
    ) {
        self.speakerDatabase = speakerDatabase
        self.transcriptsDirectory = transcriptsDirectory
        self.preferredClipsDirectory = preferredClipsDirectory
        self.legacyClipsDirectory = legacyClipsDirectory
        refresh()
    }

    var filteredProfiles: [SpeakerProfile] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return profiles }

        let query = trimmed.lowercased()
        return profiles.filter { profile in
            if let name = profile.displayName?.lowercased(), name.contains(query) {
                return true
            }
            return profile.id.uuidString.lowercased().contains(query)
        }
    }

    func refresh() {
        let speakerDatabase = self.speakerDatabase
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let profiles = Self.sortedProfiles(from: speakerDatabase)
            DispatchQueue.main.async {
                self?.profiles = profiles
            }
        }
    }

    func clipURL(for speakerId: UUID) -> URL? {
        Self.clipURL(
            for: speakerId,
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory
        )
    }

    func playSample(for speakerId: UUID) {
        guard let url = clipURL(for: speakerId) else { return }
        SpeakerClipPlayback.play(url)
    }

    func rename(profile: SpeakerProfile, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let profileId = profile.id
        let speakerDatabase = self.speakerDatabase
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            speakerDatabase.setDisplayName(id: profileId, name: trimmed, source: NameSource.userManual)
            speakerDatabase.resetDisputeCount(id: profileId)
            TranscriptSaver.retroactivelyUpdateSpeaker(
                dbId: profileId,
                newName: trimmed
            )
            let profiles = Self.sortedProfiles(from: speakerDatabase)
            DispatchQueue.main.async {
                self?.profiles = profiles
            }
        }
    }

    func merge(source: SpeakerProfile, into target: SpeakerProfile) {
        guard source.id != target.id else { return }

        let sourceId = source.id
        let sourceName = source.displayName
        let targetId = target.id
        let targetName = target.displayName
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            Self.promoteClipIfNeeded(
                from: sourceId,
                to: targetId,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            speakerDatabase.mergeProfiles(sourceId: sourceId, into: targetId)
            Self.deleteClips(
                for: sourceId,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )

            let resolvedName = speakerDatabase.getSpeaker(id: targetId)?.displayName
                ?? targetName
                ?? sourceName
                ?? "Speaker \(targetId.uuidString.prefix(8))"

            TranscriptSaver.retroactivelyUpdateSpeaker(
                dbId: sourceId,
                newName: resolvedName
            )
            let profiles = Self.sortedProfiles(from: speakerDatabase)
            DispatchQueue.main.async {
                self?.profiles = profiles
            }
        }
    }

    func delete(profile: SpeakerProfile) {
        let profileId = profile.id
        let speakerDatabase = self.speakerDatabase
        let transcriptsDirectory = self.transcriptsDirectory
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            speakerDatabase.deleteSpeaker(id: profileId)
            Self.deleteClips(
                for: profileId,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            try? AgentOutput.writeIndex(to: transcriptsDirectory, speakerStore: speakerDatabase)
            let profiles = Self.sortedProfiles(from: speakerDatabase)
            DispatchQueue.main.async {
                self?.profiles = profiles
            }
        }
    }

    func mergeTargets(for profile: SpeakerProfile) -> [SpeakerProfile] {
        profiles.filter { $0.id != profile.id }.sorted { lhs, rhs in
            let lhsName = lhs.displayName ?? "Unnamed speaker"
            let rhsName = rhs.displayName ?? "Unnamed speaker"
            if lhsName == rhsName {
                return lhs.callCount > rhs.callCount
            }
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
    }

    nonisolated private static func sortedProfiles(from speakerDatabase: SpeakerDatabase) -> [SpeakerProfile] {
        speakerDatabase.allSpeakers().sorted { lhs, rhs in
            let lhsNamed = (lhs.displayName?.isEmpty == false)
            let rhsNamed = (rhs.displayName?.isEmpty == false)
            if lhsNamed != rhsNamed { return lhsNamed && !rhsNamed }
            if lhs.callCount != rhs.callCount { return lhs.callCount > rhs.callCount }
            return lhs.lastSeen > rhs.lastSeen
        }
    }

    nonisolated private static func clipURL(
        for speakerId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) -> URL? {
        SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: preferredClipsDirectory)
            ?? SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: legacyClipsDirectory)
    }

    nonisolated private static func deleteClips(
        for speakerId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) {
        SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: preferredClipsDirectory)
        if legacyClipsDirectory != preferredClipsDirectory {
            SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: legacyClipsDirectory)
        }
    }

    nonisolated private static func promoteClipIfNeeded(
        from sourceId: UUID,
        to targetId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) {
        guard clipURL(
            for: targetId,
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory
        ) == nil,
        let sourceClip = clipURL(
            for: sourceId,
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory
        ) else { return }
        SpeakerClipExtractor.persistClip(
            from: sourceClip,
            speakerId: targetId,
            clipsDirectory: preferredClipsDirectory
        )
    }
}

struct SpeakerPeopleSettingsSection: View {
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    var body: some View {
        SettingsSection(
            title: "People",
            detail: "Review the speaker database Draft uses for meeting matching. Rename or merge people to keep future matches clean. Deleting a person stops future matching but does not rewrite past transcripts."
        ) {
            HStack(spacing: 12) {
                TextField("Search people or IDs", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)

                Button("Refresh") {
                    model.refresh()
                }
            }

            if model.filteredProfiles.isEmpty {
                Text("No speaker profiles yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(model.filteredProfiles, id: \.id) { profile in
                        SpeakerPersonRow(profile: profile, model: model)
                    }
                }
            }
        }
    }
}

private struct SpeakerPersonRow: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    @State private var isEditing = false
    @State private var renameDraft: String = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))

                    Text(metadataLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button(hasClip ? "Play Sample" : "No Sample") {
                        model.playSample(for: profile.id)
                    }
                    .disabled(!hasClip)

                    if !isEditing {
                        Button(profile.displayName == nil ? "Name" : "Rename") {
                            renameDraft = profile.displayName ?? ""
                            isEditing = true
                        }
                    }

                    if !model.mergeTargets(for: profile).isEmpty {
                        Menu("Merge Into") {
                            ForEach(model.mergeTargets(for: profile), id: \.id) { target in
                                Button(mergeLabel(for: target)) {
                                    model.merge(source: profile, into: target)
                                }
                            }
                        }
                    }

                    Button("Delete", role: .destructive) {
                        showDeleteConfirmation = true
                    }
                }
            }

            if isEditing {
                HStack(spacing: 8) {
                    TextField("Enter a name", text: $renameDraft)
                        .textFieldStyle(.roundedBorder)

                    Button("Save") {
                        model.rename(profile: profile, to: renameDraft)
                        isEditing = false
                    }
                    .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    Button("Cancel") {
                        renameDraft = ""
                        isEditing = false
                    }
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
        .alert("Delete person?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.delete(profile: profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the speaker profile and stored sample clip for future matching. Past transcripts stay unchanged.")
        }
        .onAppear {
            if renameDraft.isEmpty {
                renameDraft = profile.displayName ?? ""
            }
        }
    }

    private var displayName: String {
        profile.displayName ?? "Unnamed speaker"
    }

    private var metadataLine: String {
        var parts = [
            profile.callCount == 1 ? "1 call" : "\(profile.callCount) calls",
            "last seen \(Self.lastSeenFormatter.string(from: profile.lastSeen))"
        ]
        if profile.disputeCount > 0 {
            let disputes = profile.disputeCount == 1 ? "1 dispute" : "\(profile.disputeCount) disputes"
            parts.append(disputes)
        }
        if profile.displayName == nil {
            parts.append(profile.id.uuidString.prefix(8).description)
        }
        return parts.joined(separator: " • ")
    }

    private var hasClip: Bool {
        model.clipURL(for: profile.id) != nil
    }

    private func mergeLabel(for target: SpeakerProfile) -> String {
        let name = target.displayName ?? "Unnamed speaker"
        return "\(name) (\(target.callCount))"
    }

    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
