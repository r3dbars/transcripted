import SwiftUI
import AppKit
import TranscriptedCore

enum SpeakerPeopleProfileFilter: String, CaseIterable, Identifiable {
    case all
    case needsReview

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All"
        case .needsReview: return "Needs Review"
        }
    }
}

@MainActor
final class SpeakerPeopleSettingsViewModel: ObservableObject {
    @Published var profiles: [SpeakerProfile] = []
    @Published var searchText: String = ""
    @Published var profileFilter: SpeakerPeopleProfileFilter = .all

    private let speakerDatabase: SpeakerDatabase
    private let preferredClipsDirectory: URL
    private let legacyClipsDirectory: URL
    private(set) var duplicateCandidates: [SpeakerDuplicateCandidate] = []
    private var duplicateProfileIDs: Set<UUID> = []
    private var duplicateCountsByProfileID: [UUID: Int] = [:]
    private var clipURLsByProfileID: [UUID: URL] = [:]
    private var refreshGeneration = 0

    private struct Snapshot {
        let profiles: [SpeakerProfile]
        let duplicateCandidates: [SpeakerDuplicateCandidate]
        let duplicateProfileIDs: Set<UUID>
        let duplicateCountsByProfileID: [UUID: Int]
        let clipURLsByProfileID: [UUID: URL]
    }

    init(
        speakerDatabase: SpeakerDatabase,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL = CoreStoragePaths.default.speakerClips
    ) {
        self.speakerDatabase = speakerDatabase
        self.preferredClipsDirectory = preferredClipsDirectory
        self.legacyClipsDirectory = legacyClipsDirectory
        refresh()
    }

    var filteredProfiles: [SpeakerProfile] {
        let duplicateIds = duplicateProfileIDs
        let reviewProfiles: (SpeakerProfile) -> Bool = { profile in
            duplicateIds.contains(profile.id)
                || profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
                || profile.disputeCount > 0
        }

        let baseProfiles: [SpeakerProfile]
        switch profileFilter {
        case .all:
            baseProfiles = profiles
        case .needsReview:
            baseProfiles = profiles.filter(reviewProfiles)
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return baseProfiles }

        let query = trimmed.lowercased()
        return baseProfiles.filter { profile in
            if let name = profile.displayName?.lowercased(), name.contains(query) {
                return true
            }
            return profile.id.uuidString.lowercased().contains(query)
        }
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                guard let self, self.refreshGeneration == generation else { return }
                self.applySnapshot(snapshot)
            }
        }
    }

    func clipURL(for speakerId: UUID) -> URL? {
        clipURLsByProfileID[speakerId]
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
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            speakerDatabase.setDisplayName(id: profileId, name: trimmed, source: NameSource.userManual)
            speakerDatabase.resetDisputeCount(id: profileId)
            TranscriptSaver.retroactivelyUpdateSpeaker(dbId: profileId, newName: trimmed)
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
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

            TranscriptSaver.retroactivelyUpdateSpeaker(dbId: sourceId, newName: resolvedName)
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
            }
        }
    }

    func delete(profile: SpeakerProfile) {
        let profileId = profile.id
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            speakerDatabase.deleteSpeaker(id: profileId)
            Self.deleteClips(
                for: profileId,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
            }
        }
    }

    func duplicateCount(for profile: SpeakerProfile) -> Int {
        duplicateCountsByProfileID[profile.id] ?? 0
    }

    private func applySnapshot(_ snapshot: Snapshot) {
        duplicateCandidates = snapshot.duplicateCandidates
        duplicateProfileIDs = snapshot.duplicateProfileIDs
        duplicateCountsByProfileID = snapshot.duplicateCountsByProfileID
        clipURLsByProfileID = snapshot.clipURLsByProfileID
        profiles = snapshot.profiles
    }

    nonisolated private static func snapshot(
        from speakerDatabase: SpeakerDatabase,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) -> Snapshot {
        snapshot(
            from: sortedProfiles(from: speakerDatabase),
            preferredClipsDirectory: preferredClipsDirectory,
            legacyClipsDirectory: legacyClipsDirectory
        )
    }

    nonisolated private static func snapshot(
        from profiles: [SpeakerProfile],
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) -> Snapshot {
        let duplicateCandidates = SpeakerDuplicateReviewPolicy.candidates(from: profiles)
        var duplicateCountsByProfileID: [UUID: Int] = [:]

        for candidate in duplicateCandidates {
            let sourceID = candidate.source.id
            let targetID = candidate.target.id
            duplicateCountsByProfileID[sourceID, default: 0] += 1
            duplicateCountsByProfileID[targetID, default: 0] += 1
        }

        let duplicateProfileIDs = Set(duplicateCountsByProfileID.keys)
        var clipURLsByProfileID: [UUID: URL] = [:]
        for profile in profiles {
            if let url = clipURL(
                for: profile.id,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            ) {
                clipURLsByProfileID[profile.id] = url
            }
        }

        return Snapshot(
            profiles: profiles,
            duplicateCandidates: duplicateCandidates,
            duplicateProfileIDs: duplicateProfileIDs,
            duplicateCountsByProfileID: duplicateCountsByProfileID,
            clipURLsByProfileID: clipURLsByProfileID
        )
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
    @State private var splitLocalSpeakersEnabled: Bool = LocalSpeakerPreferences.isEnabled()

    var body: some View {
        SettingsSection(
            title: "People in the Room",
            detail: "Split the local mic into separate speakers."
        ) {
            Toggle(
                "Identify multiple local speakers",
                isOn: Binding(
                    get: { splitLocalSpeakersEnabled },
                    set: { newValue in
                        splitLocalSpeakersEnabled = newValue
                        LocalSpeakerPreferences.setEnabled(newValue)
                    }
                )
            )

            Text("After a meeting, name each local speaker once. If the split looks wrong, choose \"Keep as You\".")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if !model.profiles.isEmpty {
            SettingsSection(
                title: "Duplicate Review",
                detail: "Possible duplicates only. Nothing merges unless you choose it."
            ) {
                let candidates = model.duplicateCandidates
                if candidates.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)

                        Text("No likely duplicates right now.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    let visibleCandidates = Array(candidates.prefix(SpeakerDuplicateReviewPolicy.maxVisibleCandidates))
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(visibleCandidates.enumerated()), id: \.element.id) { index, candidate in
                            SpeakerDuplicateCandidateRow(candidate: candidate, model: model)

                            if index < visibleCandidates.count - 1 {
                                Divider()
                            }
                        }
                    }

                    if candidates.count > visibleCandidates.count {
                        Text("Showing \(visibleCandidates.count) of \(candidates.count) possible duplicates. Merge a few, then refresh to keep reviewing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }

        SettingsSection(
            title: "People",
            detail: "Rename, play samples, or delete saved speaker profiles."
        ) {
            HStack(spacing: 12) {
                TextField("Search people or IDs", text: $model.searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Filter", selection: $model.profileFilter) {
                    ForEach(SpeakerPeopleProfileFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 190)

                Button("Refresh") {
                    model.refresh()
                }
            }

            if model.filteredProfiles.isEmpty {
                Text(emptyPeopleMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                let profiles = model.filteredProfiles
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                        SpeakerPersonRow(profile: profile, model: model)

                        if index < profiles.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private var emptyPeopleMessage: String {
        if model.profiles.isEmpty {
            return "No speaker profiles yet."
        }
        if model.profileFilter == .needsReview {
            return "No people need review."
        }
        return "No people match that search."
    }
}

private struct SpeakerDuplicateMergeRequest: Identifiable {
    let source: SpeakerProfile
    let target: SpeakerProfile

    var id: String {
        "\(source.id.uuidString)-\(target.id.uuidString)"
    }
}

private struct SpeakerDuplicateCandidateRow: View {
    let candidate: SpeakerDuplicateCandidate
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @State private var pendingMerge: SpeakerDuplicateMergeRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.2.badge.gearshape")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Possible duplicate")
                        .font(.subheadline.weight(.semibold))

                    Text(candidate.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)
            }

            HStack(alignment: .top, spacing: 12) {
                DuplicatePersonSummary(profile: candidate.source, role: "Profile A", model: model)

                Image(systemName: "arrow.left.and.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 28)

                DuplicatePersonSummary(profile: candidate.target, role: "Profile B", model: model)
            }

            HStack(spacing: 8) {
                Button {
                    pendingMerge = SpeakerDuplicateMergeRequest(
                        source: candidate.target,
                        target: candidate.source
                    )
                } label: {
                    Label("Keep Profile A", systemImage: "arrow.triangle.merge")
                }

                Button {
                    pendingMerge = SpeakerDuplicateMergeRequest(
                        source: candidate.source,
                        target: candidate.target
                    )
                } label: {
                    Label("Keep Profile B", systemImage: "arrow.triangle.merge")
                }
            }
        }
        .padding(.vertical, 8)
        .alert("Merge speaker profiles?", isPresented: Binding(
            get: { pendingMerge != nil },
            set: { isPresented in
                if !isPresented {
                    pendingMerge = nil
                }
            }
        )) {
            Button("Merge profiles", role: .destructive) {
                if let request = pendingMerge {
                    model.merge(source: request.source, into: request.target)
                }
                pendingMerge = nil
            }
            Button("Cancel", role: .cancel) {
                pendingMerge = nil
            }
        } message: {
            if let request = pendingMerge {
                Text("Transcripted will keep \(SpeakerDuplicateCandidate.displayName(for: request.target)) and remove \(SpeakerDuplicateCandidate.displayName(for: request.source)). Past transcripts stay readable.")
            }
        }
    }
}

private struct DuplicatePersonSummary: View {
    let profile: SpeakerProfile
    let role: String
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(role)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)

            Text(SpeakerDuplicateCandidate.displayName(for: profile))
                .font(.caption.weight(.semibold))
                .lineLimit(1)

            Text(metadataLine)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                model.playSample(for: profile.id)
            } label: {
                Label(hasClip ? "Sample" : "No Sample", systemImage: hasClip ? "play.circle.fill" : "play.slash")
            }
            .font(.caption)
            .disabled(!hasClip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasClip: Bool {
        model.clipURL(for: profile.id) != nil
    }

    private var metadataLine: String {
        let calls = profile.callCount == 1 ? "1 call" : "\(profile.callCount) calls"
        return "\(calls) • last seen \(Self.lastSeenFormatter.string(from: profile.lastSeen))"
    }

    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
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
                    HStack(spacing: 8) {
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))

                        ForEach(statusBadges, id: \.self) { badge in
                            Text(badge)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(badge == "Possible duplicate" ? Color.orange : Color.secondary)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill((badge == "Possible duplicate" ? Color.orange : Color.secondary).opacity(0.12))
                                )
                        }
                    }

                    Text(metadataLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()

                HStack(spacing: 8) {
                    Button {
                        model.playSample(for: profile.id)
                    } label: {
                        Label(hasClip ? "Sample" : "No Sample", systemImage: hasClip ? "play.circle.fill" : "play.slash")
                    }
                    .disabled(!hasClip)

                    if !isEditing {
                        Button {
                            renameDraft = profile.displayName ?? ""
                            isEditing = true
                        } label: {
                            Label(profile.displayName == nil ? "Name" : "Rename", systemImage: "pencil")
                        }
                    }

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Label("Delete", systemImage: "trash")
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
        .padding(.vertical, 12)
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

    private var statusBadges: [String] {
        var badges: [String] = []
        if model.duplicateCount(for: profile) > 0 {
            badges.append("Possible duplicate")
        }
        if profile.disputeCount > 0 {
            badges.append("Review")
        }
        if profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            badges.append("Unnamed")
        }
        return badges
    }

    private var hasClip: Bool {
        model.clipURL(for: profile.id) != nil
    }

    private static let lastSeenFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
