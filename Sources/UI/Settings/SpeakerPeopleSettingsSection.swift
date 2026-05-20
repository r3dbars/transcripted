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

enum SpeakerDuplicateReason: Int {
    case sameNameAndVoice
    case sameName
    case similarNameAndVoice
    case similarName
    case voiceMatch

    var title: String {
        switch self {
        case .sameNameAndVoice: return "Same name and voice"
        case .sameName: return "Same name"
        case .similarNameAndVoice: return "Similar name and voice"
        case .similarName: return "Similar name"
        case .voiceMatch: return "Voice match"
        }
    }

    var includesVoiceMatch: Bool {
        switch self {
        case .sameNameAndVoice, .similarNameAndVoice, .voiceMatch:
            return true
        case .sameName, .similarName:
            return false
        }
    }
}

struct SpeakerDuplicateCandidate: Identifiable {
    let source: SpeakerProfile
    let target: SpeakerProfile
    let reason: SpeakerDuplicateReason
    let voiceSimilarity: Double?

    var id: String {
        [source.id.uuidString, target.id.uuidString].sorted().joined(separator: "-")
    }

    var detail: String {
        let mergeLine = "Suggested merge: \(Self.displayName(for: source)) into \(Self.displayName(for: target))."
        guard let voiceSimilarity else { return mergeLine }
        return "\(Self.percentFormatter.string(from: NSNumber(value: voiceSimilarity)) ?? "High") voice match. \(mergeLine)"
    }

    static func displayName(for profile: SpeakerProfile) -> String {
        profile.displayName ?? "Unnamed speaker"
    }

    private static let percentFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .percent
        formatter.maximumFractionDigits = 0
        return formatter
    }()
}

@MainActor
final class SpeakerPeopleSettingsViewModel: ObservableObject {
    @Published var profiles: [SpeakerProfile] = []
    @Published var searchText: String = ""
    @Published var profileFilter: SpeakerPeopleProfileFilter = .all
    @Published private(set) var reviewQueueItems: [SpeakerPendingReviewItem] = []
    @Published private(set) var hasLoadedProfiles = false

    private let speakerDatabase: SpeakerDatabase
    private let preferredClipsDirectory: URL
    private let legacyClipsDirectory: URL
    private(set) var duplicateCandidates: [SpeakerDuplicateCandidate] = []
    private var duplicateProfileIDs: Set<UUID> = []
    private var duplicateCountsByProfileID: [UUID: Int] = [:]
    private var mergeTargetsByProfileID: [UUID: [SpeakerProfile]] = [:]
    private var clipURLsByProfileID: [UUID: URL] = [:]
    private var refreshGeneration = 0

    private struct Snapshot {
        let profiles: [SpeakerProfile]
        let duplicateCandidates: [SpeakerDuplicateCandidate]
        let duplicateProfileIDs: Set<UUID>
        let duplicateCountsByProfileID: [UUID: Int]
        let mergeTargetsByProfileID: [UUID: [SpeakerProfile]]
        let clipURLsByProfileID: [UUID: URL]
        let reviewQueueItems: [SpeakerPendingReviewItem]
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
            SpeakerPeopleReviewPolicy.needsReview(profile: profile, duplicateIds: duplicateIds)
        }

        let baseProfiles: [SpeakerProfile]
        switch profileFilter {
        case .all:
            baseProfiles = profiles
        case .needsReview:
            baseProfiles = profiles.filter(reviewProfiles)
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpeakerPeopleReviewPolicy.sortedForPeopleSettings(baseProfiles, duplicateIds: duplicateIds)
        }

        let query = trimmed.lowercased()
        let matches = baseProfiles.filter { profile in
            if let name = profile.displayName?.lowercased(), name.contains(query) {
                return true
            }
            return profile.id.uuidString.lowercased().contains(query)
        }
        return SpeakerPeopleReviewPolicy.sortedForPeopleSettings(matches, duplicateIds: duplicateIds)
    }

    var needsReviewCount: Int {
        profiles.filter {
            SpeakerPeopleReviewPolicy.needsReview(profile: $0, duplicateIds: duplicateProfileIDs)
        }.count
    }

    var duplicateCandidateCount: Int {
        duplicateCandidates.count
    }

    var reviewQueueCount: Int {
        reviewQueueItems.count
    }

    var totalMeetingCount: Int {
        profiles.reduce(0) { $0 + $1.callCount }
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

    func playSample(for item: SpeakerPendingReviewItem) {
        guard let url = item.clipURL else { return }
        SpeakerClipPlayback.play(url)
    }

    func openTranscript(for item: SpeakerPendingReviewItem) {
        NSWorkspace.shared.open(item.transcriptURL)
    }

    func namePendingReviewItem(_ item: SpeakerPendingReviewItem, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let speakerId = item.speakerId
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            speakerDatabase.setDisplayName(id: speakerId, name: trimmed, source: NameSource.userManual)
            speakerDatabase.resetDisputeCount(id: speakerId)
            TranscriptSaver.retroactivelyUpdateSpeaker(dbId: speakerId, newName: trimmed)
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

            TranscriptSaver.retroactivelyMergeSpeaker(
                sourceDbId: sourceId,
                targetDbId: targetId,
                targetName: resolvedName
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

    func mergeTargets(for profile: SpeakerProfile) -> [SpeakerProfile] {
        mergeTargetsByProfileID[profile.id] ?? []
    }

    private func applySnapshot(_ snapshot: Snapshot) {
        duplicateCandidates = snapshot.duplicateCandidates
        duplicateProfileIDs = snapshot.duplicateProfileIDs
        duplicateCountsByProfileID = snapshot.duplicateCountsByProfileID
        mergeTargetsByProfileID = snapshot.mergeTargetsByProfileID
        clipURLsByProfileID = snapshot.clipURLsByProfileID
        reviewQueueItems = snapshot.reviewQueueItems
        hasLoadedProfiles = true
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
        let duplicateCandidates = duplicateCandidates(from: profiles)
        var duplicateCountsByProfileID: [UUID: Int] = [:]
        var duplicatePeerIDsByProfileID: [UUID: Set<UUID>] = [:]

        for candidate in duplicateCandidates {
            let sourceID = candidate.source.id
            let targetID = candidate.target.id
            duplicateCountsByProfileID[sourceID, default: 0] += 1
            duplicateCountsByProfileID[targetID, default: 0] += 1
            duplicatePeerIDsByProfileID[sourceID, default: []].insert(targetID)
            duplicatePeerIDsByProfileID[targetID, default: []].insert(sourceID)
        }

        let duplicateProfileIDs = Set(duplicateCountsByProfileID.keys)
        let mergeTargetsByProfileID = Dictionary(
            uniqueKeysWithValues: profiles.map { profile in
                (
                    profile.id,
                    sortedMergeTargets(
                        for: profile,
                        in: profiles,
                        duplicatePeerIds: duplicatePeerIDsByProfileID[profile.id] ?? []
                    )
                )
            }
        )

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

        let reviewQueueItems = SpeakerReviewQueueScanner.loadPendingItems(
            profiles: profiles,
            clipURLsByProfileID: clipURLsByProfileID
        )

        return Snapshot(
            profiles: profiles,
            duplicateCandidates: duplicateCandidates,
            duplicateProfileIDs: duplicateProfileIDs,
            duplicateCountsByProfileID: duplicateCountsByProfileID,
            mergeTargetsByProfileID: mergeTargetsByProfileID,
            clipURLsByProfileID: clipURLsByProfileID,
            reviewQueueItems: reviewQueueItems
        )
    }

    nonisolated private static func sortedMergeTargets(
        for profile: SpeakerProfile,
        in profiles: [SpeakerProfile],
        duplicatePeerIds: Set<UUID>
    ) -> [SpeakerProfile] {
        profiles.filter { $0.id != profile.id }.sorted { lhs, rhs in
            let lhsIsDuplicate = duplicatePeerIds.contains(lhs.id)
            let rhsIsDuplicate = duplicatePeerIds.contains(rhs.id)
            if lhsIsDuplicate != rhsIsDuplicate {
                return lhsIsDuplicate && !rhsIsDuplicate
            }

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

    nonisolated private static func duplicateCandidates(from profiles: [SpeakerProfile]) -> [SpeakerDuplicateCandidate] {
        guard profiles.count > 1 else { return [] }

        var candidates: [SpeakerDuplicateCandidate] = []
        var seenPairs = Set<String>()

        for lhsIndex in profiles.indices {
            for rhsIndex in profiles.indices where rhsIndex > lhsIndex {
                let lhs = profiles[lhsIndex]
                let rhs = profiles[rhsIndex]
                let voiceSimilarity = cosineSimilarity(lhs.embedding, rhs.embedding)
                guard let reason = duplicateReason(lhs, rhs, voiceSimilarity: voiceSimilarity) else {
                    continue
                }

                let pairId = [lhs.id.uuidString, rhs.id.uuidString].sorted().joined(separator: "-")
                guard !seenPairs.contains(pairId) else { continue }
                seenPairs.insert(pairId)

                let target = suggestedMergeTarget(lhs, rhs)
                let source = target.id == lhs.id ? rhs : lhs
                candidates.append(SpeakerDuplicateCandidate(
                    source: source,
                    target: target,
                    reason: reason,
                    voiceSimilarity: reason.includesVoiceMatch ? voiceSimilarity : nil
                ))
            }
        }

        return candidates.sorted { lhs, rhs in
            if lhs.reason.rawValue != rhs.reason.rawValue {
                return lhs.reason.rawValue < rhs.reason.rawValue
            }
            let lhsSimilarity = lhs.voiceSimilarity ?? 0
            let rhsSimilarity = rhs.voiceSimilarity ?? 0
            if lhsSimilarity != rhsSimilarity {
                return lhsSimilarity > rhsSimilarity
            }
            let lhsCalls = lhs.source.callCount + lhs.target.callCount
            let rhsCalls = rhs.source.callCount + rhs.target.callCount
            return lhsCalls > rhsCalls
        }
    }

    nonisolated private static func duplicateReason(
        _ lhs: SpeakerProfile,
        _ rhs: SpeakerProfile,
        voiceSimilarity: Double?
    ) -> SpeakerDuplicateReason? {
        let lhsName = normalizedName(lhs.displayName)
        let rhsName = normalizedName(rhs.displayName)
        let sameName = lhsName != nil && lhsName == rhsName
        let similarName = !sameName && namesLookRelated(lhsName, rhsName)

        let nameConflict = lhsName != nil && rhsName != nil && !sameName && !similarName
        let voiceThreshold = nameConflict ? 0.96 : 0.90
        let voiceMatch = lhs.disputeCount == 0
            && rhs.disputeCount == 0
            && (voiceSimilarity ?? 0) >= voiceThreshold

        switch (sameName, similarName, voiceMatch) {
        case (true, _, true):
            return .sameNameAndVoice
        case (true, _, false):
            return .sameName
        case (false, true, true):
            return .similarNameAndVoice
        case (false, true, false):
            return .similarName
        case (false, false, true):
            return .voiceMatch
        default:
            return nil
        }
    }

    nonisolated private static func suggestedMergeTarget(_ lhs: SpeakerProfile, _ rhs: SpeakerProfile) -> SpeakerProfile {
        if lhs.callCount != rhs.callCount {
            return lhs.callCount > rhs.callCount ? lhs : rhs
        }

        let lhsNamed = normalizedName(lhs.displayName) != nil
        let rhsNamed = normalizedName(rhs.displayName) != nil
        if lhsNamed != rhsNamed {
            return lhsNamed ? lhs : rhs
        }

        return lhs.lastSeen >= rhs.lastSeen ? lhs : rhs
    }

    nonisolated private static func normalizedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    nonisolated private static func namesLookRelated(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, lhs != rhs else { return false }
        if lhs.count >= 3 && rhs.count >= 3 && (lhs.contains(rhs) || rhs.contains(lhs)) {
            return true
        }

        let lhsTokens = nameTokens(lhs)
        let rhsTokens = nameTokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }
        return lhsTokens.isSubset(of: rhsTokens) || rhsTokens.isSubset(of: lhsTokens)
    }

    nonisolated private static func nameTokens(_ name: String) -> Set<String> {
        Set(name
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 })
    }

    nonisolated private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }

        var dotProduct: Float = 0
        var lhsNorm: Float = 0
        var rhsNorm: Float = 0

        for (left, right) in zip(lhs, rhs) {
            dotProduct += left * right
            lhsNorm += left * left
            rhsNorm += right * right
        }

        let denominator = sqrt(lhsNorm) * sqrt(rhsNorm)
        guard denominator > 0 else { return nil }
        return Double(dotProduct / denominator)
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
            title: actionSectionTitle,
            detail: actionSectionDetail
        ) {
            SpeakerPeopleStatusRow(
                needsReviewCount: model.needsReviewCount,
                duplicateCount: model.duplicateCandidateCount,
                speakerCount: model.profiles.count,
                meetingCount: model.totalMeetingCount,
                onShowNeedsReview: {
                    model.profileFilter = .needsReview
                }
            )
        }

        if !model.reviewQueueItems.isEmpty {
            SettingsSection(
                title: "Please Name These Speakers",
                detail: reviewQueueDetail
            ) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(model.reviewQueueItems.enumerated()), id: \.element.id) { index, item in
                        SpeakerPendingReviewRow(item: item, model: model)

                        if index < model.reviewQueueItems.count - 1 {
                            Divider()
                                .padding(.vertical, 10)
                        }
                    }
                }
            }
        }

        if !model.duplicateCandidates.isEmpty {
            SettingsSection(
                title: "Possible Duplicates",
                detail: "Review these before merging speaker profiles."
            ) {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(model.duplicateCandidates.enumerated()), id: \.element.id) { index, candidate in
                        SpeakerDuplicateCandidateRow(candidate: candidate, model: model)

                        if index < model.duplicateCandidates.count - 1 {
                            Divider()
                        }
                    }
                }
            }
        }

        SettingsSection(
            title: "All Speakers",
            detail: allSpeakersDetail
        ) {
            SpeakerPeopleToolbar(model: model)

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

    private var actionSectionTitle: String {
        if model.reviewQueueCount > 0 {
            return "Speaker Queue"
        }
        if model.needsReviewCount > 0 {
            return "Needs Review"
        }
        return "Speaker Cleanup"
    }

    private var actionSectionDetail: String {
        if model.reviewQueueCount > 0 {
            return "Deferred speaker reviews are ready to finish."
        }
        if model.needsReviewCount > 0 {
            return "Start here when a speaker needs a name or a duplicate needs merging."
        }
        return "A quick check before browsing saved speakers."
    }

    private var reviewQueueDetail: String {
        let count = model.reviewQueueCount
        return count == 1
            ? "1 voice from a saved call still needs a name."
            : "\(count) voices from saved calls still need names."
    }

    private var allSpeakersDetail: String {
        guard !model.profiles.isEmpty else {
            return "People you name after meetings will show up here."
        }

        return "\(Self.speakerCountText(model.profiles.count)) across \(Self.meetingCountText(model.totalMeetingCount))."
    }

    private var emptyPeopleMessage: String {
        if model.profiles.isEmpty {
            return "No saved speakers yet. Name people after a meeting and they will appear here."
        }
        if model.profileFilter == .needsReview {
            return "No deferred speaker reviews right now."
        }
        return "No speakers match that search."
    }

    private static func speakerCountText(_ count: Int) -> String {
        count == 1 ? "1 saved speaker" : "\(count) saved speakers"
    }

    private static func meetingCountText(_ count: Int) -> String {
        count == 1 ? "1 meeting" : "\(count) meetings"
    }
}

private struct SpeakerPendingReviewRow: View {
    let item: SpeakerPendingReviewItem
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    @State private var nameDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 24, height: 24)
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(item.speakerLabel)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)

                        SpeakerStatusBadge(title: item.channelTitle)
                    }

                    Text(meetingLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)

                    Text(sampleLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    nameField
                    actionButtons
                }

                VStack(alignment: .leading, spacing: 8) {
                    nameField
                    actionButtons
                }
            }
        }
        .padding(.vertical, 4)
        .onAppear {
            if nameDraft.isEmpty {
                nameDraft = item.profile.displayName ?? ""
            }
        }
    }

    private var nameField: some View {
        TextField("Name this speaker", text: $nameDraft)
            .textFieldStyle(.roundedBorder)
            .frame(minWidth: 220)
            .onSubmit(saveName)
    }

    private var actionButtons: some View {
        HStack(spacing: 8) {
            SettingsInlineActionButton(
                title: item.clipURL == nil ? "No Sample" : "Sample",
                symbolName: item.clipURL == nil ? "play.slash" : "play.circle.fill",
                tone: item.clipURL == nil ? .neutral : .accent
            ) {
                model.playSample(for: item)
            }
            .disabled(item.clipURL == nil)

            SettingsInlineActionButton(title: "Open Call", symbolName: "doc.text") {
                model.openTranscript(for: item)
            }

            SettingsInlineActionButton(title: "Save Name", tone: .accent) {
                saveName()
            }
            .disabled(!canSave)
        }
    }

    private var meetingLine: String {
        var parts = [item.meetingTitle]
        if let dateText = Self.dateFormatter.stringIfAvailable(from: item.recordedAt ?? item.fallbackDate) {
            parts.append(dateText)
        }
        let calls = item.callCount == 1 ? "1 call" : "\(item.callCount) calls"
        parts.append(calls)
        return parts.joined(separator: " - ")
    }

    private var sampleLine: String {
        guard let sampleText = item.sampleText,
              !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No transcript sample found for this voice."
        }
        return "\"\(sampleText)\""
    }

    private var canSave: Bool {
        !nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func saveName() {
        guard canSave else { return }
        model.namePendingReviewItem(item, to: nameDraft)
        nameDraft = ""
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension DateFormatter {
    func stringIfAvailable(from date: Date) -> String? {
        date == .distantPast ? nil : string(from: date)
    }
}

private struct SpeakerPeopleStatusRow: View {
    let needsReviewCount: Int
    let duplicateCount: Int
    let speakerCount: Int
    let meetingCount: Int
    let onShowNeedsReview: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 12) {
                statusIcon
                statusCopy
                Spacer(minLength: 12)
                reviewButton
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    statusIcon
                    statusCopy
                }
                reviewButton
            }
        }
    }

    private var statusIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(iconColor)
            .frame(width: 24, height: 24)
            .padding(.top, 1)
    }

    private var statusCopy: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    metrics
                }

                VStack(alignment: .leading, spacing: 6) {
                    metrics
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var metrics: some View {
        SpeakerPeopleMetricPill(value: "\(speakerCount)", label: speakerCount == 1 ? "saved speaker" : "saved speakers")
        SpeakerPeopleMetricPill(value: "\(meetingCount)", label: meetingCount == 1 ? "meeting" : "meetings")
        SpeakerPeopleMetricPill(value: "\(needsReviewCount)", label: "to review", tone: hasWork ? .warning : .neutral)
        if duplicateCount > 0 {
            SpeakerPeopleMetricPill(
                value: "\(duplicateCount)",
                label: duplicateCount == 1 ? "duplicate pair" : "duplicate pairs",
                tone: .warning
            )
        }
    }

    @ViewBuilder
    private var reviewButton: some View {
        if hasWork {
            SettingsInlineActionButton(title: "Show Review", tone: .warning) {
                onShowNeedsReview()
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var hasWork: Bool {
        needsReviewCount > 0
    }

    private var iconName: String {
        if speakerCount == 0 {
            return "person.crop.circle.badge.plus"
        }
        return hasWork ? "exclamationmark.circle.fill" : "checkmark.circle.fill"
    }

    private var iconColor: Color {
        if speakerCount == 0 {
            return .secondary
        }
        return hasWork ? .orange : .green
    }

    private var title: String {
        if speakerCount == 0 {
            return "No saved speakers yet"
        }

        if hasWork {
            return needsReviewCount == 1
                ? "1 speaker needs review"
                : "\(needsReviewCount) speakers need review"
        }

        return "No speaker cleanup needed"
    }

    private var detail: String {
        if speakerCount == 0 {
            return "After a meeting, speakers you name or save will show up here."
        }

        if hasWork {
            if duplicateCount > 0 {
                return "Fix names, review flagged speakers, or merge likely duplicates before trusting old labels."
            }
            return "Name the rows marked Needs Name or Review. Everything else is already browsable below."
        }

        return "Nothing needs your attention. Browse everyone below by name and meeting count."
    }
}

private struct SpeakerPeopleMetricPill: View {
    let value: String
    let label: String
    var tone: SettingsInteractionTone = .neutral

    var body: some View {
        HStack(spacing: 5) {
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(valueColor)

            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(fillColor))
    }

    private var valueColor: Color {
        switch tone {
        case .warning:
            return .orange
        case .destructive:
            return .red
        case .accent:
            return .accentColor
        case .neutral:
            return .primary
        }
    }

    private var fillColor: Color {
        switch tone {
        case .warning:
            return Color.orange.opacity(0.11)
        case .destructive:
            return Color.red.opacity(0.09)
        case .accent:
            return Color.accentColor.opacity(0.10)
        case .neutral:
            return Color.primary.opacity(0.045)
        }
    }
}

private struct SpeakerPeopleToolbar: View {
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search speakers or IDs", text: $model.searchText)
                .textFieldStyle(.roundedBorder)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    filterControl
                    Spacer(minLength: 12)
                    refreshButton
                }

                VStack(alignment: .leading, spacing: 10) {
                    filterControl
                    refreshButton
                }
            }
        }
    }

    private var filterControl: some View {
        HStack(spacing: 8) {
            Text("Show")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Show speakers", selection: $model.profileFilter) {
                ForEach(SpeakerPeopleProfileFilter.allCases) { filter in
                    Text(filter.title).tag(filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 190)
        }
    }

    private var refreshButton: some View {
        SettingsInlineActionButton(title: "Refresh", symbolName: "arrow.clockwise") {
            model.refresh()
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

private struct SpeakerDuplicateCandidateRow: View {
    let candidate: SpeakerDuplicateCandidate
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 20)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(candidate.reason.title)
                        .font(.subheadline.weight(.semibold))

                    Text(candidate.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    model.merge(source: candidate.source, into: candidate.target)
                } label: {
                    Label("Merge", systemImage: "arrow.triangle.merge")
                }
                .help("Merge \(SpeakerDuplicateCandidate.displayName(for: candidate.source)) into \(SpeakerDuplicateCandidate.displayName(for: candidate.target))")
            }

            HStack(alignment: .top, spacing: 12) {
                DuplicatePersonSummary(profile: candidate.source, role: "Merge from", model: model)

                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 28)

                DuplicatePersonSummary(profile: candidate.target, role: "Keep", model: model)
            }
        }
        .padding(.vertical, 8)
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

            Text(profile.callCount == 1 ? "1 meeting" : "\(profile.callCount) meetings")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Button {
                model.playSample(for: profile.id)
            } label: {
                Label(hasClip ? "Sample" : "No Sample", systemImage: hasClip ? "play.circle.fill" : "play.slash")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: hasClip ? .accent : .neutral,
                cornerRadius: 8,
                normalFill: hasClip ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.025),
                normalStroke: hasClip ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.06)
            ))
            .disabled(!hasClip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var hasClip: Bool {
        model.clipURL(for: profile.id) != nil
    }
}

private struct SpeakerPersonRow: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    @State private var isEditing = false
    @State private var renameDraft: String = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)

                    Text(metadataLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)

                    if !statusBadges.isEmpty {
                        HStack(spacing: 6) {
                            ForEach(statusBadges, id: \.self) { badge in
                                SpeakerStatusBadge(title: badge)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                SpeakerMeetingCountBadge(count: profile.callCount)
            }

            SpeakerPersonActions(
                profile: profile,
                model: model,
                isEditing: $isEditing,
                renameDraft: $renameDraft,
                showDeleteConfirmation: $showDeleteConfirmation,
                hasClip: hasClip
            )

            if isEditing {
                renameEditor
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

    private var renameEditor: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                renameField
                renameButtons
            }

            VStack(alignment: .leading, spacing: 8) {
                renameField
                renameButtons
            }
        }
    }

    private var renameField: some View {
        TextField("Enter a speaker name", text: $renameDraft)
            .textFieldStyle(.roundedBorder)
    }

    private var renameButtons: some View {
        HStack(spacing: 8) {
            SettingsInlineActionButton(title: "Save", tone: .accent) {
                model.rename(profile: profile, to: renameDraft)
                isEditing = false
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            SettingsInlineActionButton(title: "Cancel") {
                renameDraft = ""
                isEditing = false
            }
        }
    }

    private var statusBadges: [String] {
        var badges: [String] = []
        if model.duplicateCount(for: profile) > 0 {
            badges.append("Duplicate")
        }
        if profile.disputeCount > 0 {
            badges.append("Review")
        }
        if profile.displayName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
            badges.append("Needs Name")
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

private struct SpeakerMeetingCountBadge: View {
    let count: Int

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text("\(count)")
                .font(.headline.weight(.semibold))
                .monospacedDigit()

            Text(count == 1 ? "meeting" : "meetings")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 72, alignment: .trailing)
    }
}

private struct SpeakerStatusBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private var color: Color {
        title == "Duplicate" || title == "Needs Name" ? .orange : .secondary
    }
}

private struct SpeakerPersonActions: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @Binding var isEditing: Bool
    @Binding var renameDraft: String
    @Binding var showDeleteConfirmation: Bool
    let hasClip: Bool

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                actionItems
            }

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 112), spacing: 8, alignment: .leading)],
                alignment: .leading,
                spacing: 8
            ) {
                actionItems
            }
        }
    }

    @ViewBuilder
    private var actionItems: some View {
        SpeakerActionButton(
            title: hasClip ? "Sample" : "No Sample",
            symbolName: hasClip ? "play.circle.fill" : "play.slash",
            tone: hasClip ? .accent : .neutral,
            minWidth: 104,
            isDisabled: !hasClip
        ) {
            model.playSample(for: profile.id)
        }

        if !isEditing {
            SpeakerActionButton(
                title: profile.displayName == nil ? "Name" : "Rename",
                symbolName: "pencil",
                minWidth: 104
            ) {
                renameDraft = profile.displayName ?? ""
                isEditing = true
            }
        }

        if !model.mergeTargets(for: profile).isEmpty {
            SpeakerMergeMenu(profile: profile, model: model)
        }

        SpeakerActionButton(
            title: "Delete",
            symbolName: "trash",
            tone: .destructive,
            minWidth: 104
        ) {
            showDeleteConfirmation = true
        }
    }
}

private struct SpeakerActionButton: View {
    let title: String
    let symbolName: String
    var tone: SettingsInteractionTone = .neutral
    var minWidth: CGFloat = 96
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            SpeakerActionLabel(title: title, symbolName: symbolName, minWidth: minWidth)
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: tone,
            cornerRadius: 8,
            normalFill: SpeakerActionChrome.fill(for: tone),
            normalStroke: SpeakerActionChrome.stroke(for: tone)
        ))
        .disabled(isDisabled)
    }
}

private struct SpeakerMergeMenu: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    var body: some View {
        Menu {
            ForEach(model.mergeTargets(for: profile), id: \.id) { target in
                Button(mergeLabel(for: target)) {
                    model.merge(source: profile, into: target)
                }
            }
        } label: {
            SpeakerActionLabel(title: "Merge", symbolName: "arrow.triangle.merge", minWidth: 104)
        }
        .buttonStyle(SettingsHoverButtonStyle(
            cornerRadius: 8,
            normalFill: SpeakerActionChrome.fill(for: .neutral),
            normalStroke: SpeakerActionChrome.stroke(for: .neutral)
        ))
        .help("Merge this speaker into another saved profile")
    }

    private func mergeLabel(for target: SpeakerProfile) -> String {
        let name = target.displayName ?? "Unnamed speaker"
        let meetingCount = target.callCount == 1 ? "1 meeting" : "\(target.callCount) meetings"
        return "\(name) (\(meetingCount))"
    }
}

private struct SpeakerActionLabel: View {
    let title: String
    let symbolName: String
    let minWidth: CGFloat

    var body: some View {
        Label(title, systemImage: symbolName)
            .labelStyle(.titleAndIcon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(minWidth: minWidth, alignment: .center)
    }
}

private enum SpeakerActionChrome {
    static func fill(for tone: SettingsInteractionTone) -> Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.025)
        case .accent:
            return Color.accentColor.opacity(0.08)
        case .warning:
            return Color.orange.opacity(0.08)
        case .destructive:
            return Color.red.opacity(0.06)
        }
    }

    static func stroke(for tone: SettingsInteractionTone) -> Color {
        switch tone {
        case .neutral:
            return Color.primary.opacity(0.06)
        case .accent:
            return Color.accentColor.opacity(0.16)
        case .warning:
            return Color.orange.opacity(0.16)
        case .destructive:
            return Color.red.opacity(0.14)
        }
    }
}
