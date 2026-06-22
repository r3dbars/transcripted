import SwiftUI
import AppKit
import TranscriptedCore

enum SpeakerPeopleSettingsPolishContract {
    static let minimumHitTarget: CGFloat = 40
    static let playButtonVisibleDiameter: CGFloat = 36
    static let compactIconVisibleDiameter: CGFloat = 28
}

private struct SpeakerCompactIconLabel: View {
    let systemName: String
    let foregroundColor: Color
    let fontSize: CGFloat
    let fontWeight: Font.Weight
    var tone: SettingsInteractionTone = .neutral
    var normalFill: Color = Color.primary.opacity(0.025)
    var normalStroke: Color = Color.primary.opacity(0.06)
    var cornerRadius: CGFloat = 8

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: fontSize, weight: fontWeight))
            .foregroundStyle(foregroundColor)
            .frame(
                width: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter,
                height: SpeakerPeopleSettingsPolishContract.compactIconVisibleDiameter
            )
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(fillColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(strokeColor, lineWidth: 1)
            )
            .frame(
                width: SpeakerPeopleSettingsPolishContract.minimumHitTarget,
                height: SpeakerPeopleSettingsPolishContract.minimumHitTarget
            )
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.55)
            .onHover { isHovering = $0 }
            .animation(SettingsInteractionPalette.animation, value: isHovering)
    }

    private var fillColor: Color {
        guard isEnabled else { return normalFill.opacity(0.65) }
        if isHovering { return SettingsInteractionPalette.hoverFill(for: tone) }
        return normalFill
    }

    private var strokeColor: Color {
        guard isEnabled else { return normalStroke.opacity(0.5) }
        if isHovering { return SettingsInteractionPalette.hoverStroke(for: tone) }
        return normalStroke
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
        case .similarName: return "Similar names"
        case .voiceMatch: return "Voices match"
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

    var summaryLine: String {
        var parts = [reason.title]
        if let voiceSimilarity,
           let percent = Self.percentFormatter.string(from: NSNumber(value: voiceSimilarity)) {
            parts.append("\(percent) voice match")
        }
        parts.append("merging keeps \(Self.displayName(for: target))")
        return parts.joined(separator: " · ")
    }

    static func displayName(for profile: SpeakerProfile) -> String {
        profile.displayName ?? "Unknown voice"
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
    @Published private(set) var reviewQueueItems: [SpeakerPendingReviewItem] = []
    @Published private(set) var hasLoadedProfiles = false
    /// Bumped to ask the "Search speakers" field to take focus (⌘F).
    @Published private(set) var searchFocusRequestToken = 0

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

    var pendingVoiceGroups: [SpeakerPendingVoiceGroup] {
        SpeakerReviewQueueScanner.groupedByVoice(reviewQueueItems)
    }

    var filteredProfiles: [SpeakerProfile] {
        let duplicateIds = duplicateProfileIDs
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SpeakerPeopleReviewPolicy.sortedForPeopleSettings(profiles, duplicateIds: duplicateIds)
        }

        let query = trimmed.lowercased()
        let matches = profiles.filter { profile in
            if let name = profile.displayName?.lowercased(), name.contains(query) {
                return true
            }
            return profile.id.uuidString.lowercased().contains(query)
        }
        return SpeakerPeopleReviewPolicy.sortedForPeopleSettings(matches, duplicateIds: duplicateIds)
    }

    /// Asks the "Search speakers" field to take keyboard focus. Drives the ⌘F
    /// "Find Speaker" menu command.
    func requestSearchFocus() {
        searchFocusRequestToken += 1
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

    func isPlayingSample(for speakerId: UUID) -> Bool {
        guard let url = clipURL(for: speakerId) else { return false }
        return SpeakerClipPlayback.isPlaying(url)
    }

    func playSample(for item: SpeakerPendingReviewItem) {
        guard let url = item.clipURL else { return }
        SpeakerClipPlayback.play(url)
    }

    func isPlayingSample(for item: SpeakerPendingReviewItem) -> Bool {
        guard let url = item.clipURL else { return false }
        return SpeakerClipPlayback.isPlaying(url)
    }

    func openTranscript(for item: SpeakerPendingReviewItem) {
        NSWorkspace.shared.open(item.transcriptURL)
    }

    func hasPendingReview(forTranscript transcriptURL: URL) -> Bool {
        let targetPath = transcriptURL.standardizedFileURL.path
        return reviewQueueItems.contains {
            $0.transcriptURL.standardizedFileURL.path == targetPath
        }
    }

    func namePendingReviewItem(
        _ item: SpeakerPendingReviewItem,
        to newName: String,
        completion: ((Bool) -> Void)? = nil
    ) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            completion?(false)
            return
        }

        let speakerId = item.speakerId
        let queuedReviewItems = reviewQueueItems.filter { $0.speakerId == speakerId }
        let matchingReviewItems = queuedReviewItems.isEmpty ? [item] : queuedReviewItems
        let speakerDatabase = self.speakerDatabase
        let preferredClipsDirectory = self.preferredClipsDirectory
        let legacyClipsDirectory = self.legacyClipsDirectory
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var allTranscriptUpdatesSucceeded = true
            for reviewItem in matchingReviewItems {
                let didUpdate = TranscriptSaver.updateDeferredSpeakerName(
                    transcriptURL: reviewItem.transcriptURL,
                    dbId: speakerId,
                    diarizerSpeakerId: reviewItem.diarizerSpeakerId,
                    channel: reviewItem.channel,
                    newName: trimmed
                )
                allTranscriptUpdatesSucceeded = allTranscriptUpdatesSucceeded && didUpdate
            }

            if allTranscriptUpdatesSucceeded {
                speakerDatabase.setDisplayName(id: speakerId, name: trimmed, source: NameSource.userManual)
                speakerDatabase.resetDisputeCount(id: speakerId)
            }
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
                completion?(allTranscriptUpdatesSucceeded)
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

    /// Deletes the voice behind a pending review group. Thin wrapper over
    /// `delete(profile:)` so the "voices to name" overflow menu shares the same
    /// real deletion path as the all-speakers list.
    func deleteVoice(_ group: SpeakerPendingVoiceGroup, completion: ((Bool) -> Void)? = nil) {
        delete(profile: group.representative.profile, completion: completion)
    }

    func delete(profile: SpeakerProfile, completion: ((Bool) -> Void)? = nil) {
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
            // Confirm the row is actually gone before reporting success so a
            // failed delete surfaces an error instead of silently no-opping.
            let didDelete = speakerDatabase.getSpeaker(id: profileId) == nil
            let snapshot = Self.snapshot(
                from: speakerDatabase,
                preferredClipsDirectory: preferredClipsDirectory,
                legacyClipsDirectory: legacyClipsDirectory
            )
            DispatchQueue.main.async {
                self?.applySnapshot(snapshot)
                completion?(didDelete)
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

            let lhsName = lhs.displayName ?? "Unknown voice"
            let rhsName = rhs.displayName ?? "Unknown voice"
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
        return SpeakerVectorMath.cosineSimilarity(lhs, rhs)
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
    enum ScrollTarget: Hashable {
        case reviewQueue
    }

    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @State private var playbackStateVersion = 0

    var body: some View {
        Group {
            let voiceGroups = model.pendingVoiceGroups

            if !voiceGroups.isEmpty {
                SettingsSection(
                    title: voicesToNameTitle(count: voiceGroups.count),
                    detail: "Play a clip. If you recognize the voice, type their name — it updates every meeting they're in."
                ) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(voiceGroups.enumerated()), id: \.element.id) { index, group in
                            SpeakerVoiceToNameRow(group: group, model: model)

                            if index < voiceGroups.count - 1 {
                                Divider()
                                    .padding(.vertical, 12)
                            }
                        }
                    }
                }
                .id(ScrollTarget.reviewQueue)
                .accessibilityIdentifier("transcripted.speakers.inbox")
            }

            if !model.duplicateCandidates.isEmpty {
                SettingsSection(
                    title: "Possible duplicates",
                    detail: duplicatesDetail
                ) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(model.duplicateCandidates.enumerated()), id: \.element.id) { index, candidate in
                            SpeakerDuplicateCandidateRow(candidate: candidate, model: model)

                            if index < model.duplicateCandidates.count - 1 {
                                Divider()
                                    .padding(.vertical, 10)
                            }
                        }
                    }
                }
            }

            SettingsSection(
                title: "All speakers",
                detail: allSpeakersDetail
            ) {
                if !model.profiles.isEmpty {
                    SpeakerSearchRow(model: model)
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
        .onReceive(NotificationCenter.default.publisher(for: SpeakerClipPlayback.stateDidChangeNotification)) { _ in
            playbackStateVersion += 1
        }
        .onDisappear {
            SpeakerClipPlayback.stop()
        }
    }

    private func voicesToNameTitle(count: Int) -> String {
        count == 1 ? "1 voice to name" : "\(count) voices to name"
    }

    private var duplicatesDetail: String {
        model.duplicateCandidates.count == 1
            ? "These two sound like the same person. Merging combines them into one."
            : "These pairs sound like the same person. Merging combines each pair into one."
    }

    private var allSpeakersDetail: String {
        let count = model.profiles.count
        guard count > 0 else {
            return "People from your meetings show up here once a meeting is saved."
        }
        return count == 1 ? "1 saved speaker." : "\(count) saved speakers."
    }

    private var emptyPeopleMessage: String {
        if model.profiles.isEmpty {
            return "No speakers yet. After your next meeting, the people in it will appear here."
        }
        return "No speakers match your search."
    }
}

// MARK: - Voices to name

private struct SpeakerVoiceToNameRow: View {
    let group: SpeakerPendingVoiceGroup
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    @State private var nameDraft = ""
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var showDeleteConfirmation = false
    @State private var isDeleting = false
    @State private var deleteErrorMessage: String?

    private var isPlaying: Bool {
        model.isPlayingSample(for: group.representative)
    }

    private var hasClip: Bool {
        group.representative.clipURL != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                SpeakerPlayClipButton(
                    hasClip: hasClip,
                    isPlaying: isPlaying,
                    action: { model.playSample(for: group.representative) }
                )

                VStack(alignment: .leading, spacing: 4) {
                    Text(quoteLine)
                        .font(.subheadline)
                        .foregroundStyle(group.sampleText == nil ? .secondary : .primary)
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(metaLine)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
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

            if let saveErrorMessage {
                Text(saveErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let deleteErrorMessage {
                Text(deleteErrorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, isActiveHighlight ? 8 : 0)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(isActiveHighlight ? 0.08 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(isActiveHighlight ? 0.35 : 0), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.15), value: isActiveHighlight)
        .onAppear {
            if nameDraft.isEmpty {
                nameDraft = group.representative.profile.displayName ?? ""
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
        } message: {
            Text(SpeakerVoiceRowMenuPolicy.deleteConfirmationMessage)
        }
    }

    private var isActiveHighlight: Bool {
        SpeakerClipPlaybackPresentation.isActiveHighlight(hasClip: hasClip, isPlaying: isPlaying)
    }

    private var nameSuggestions: [SpeakerIdentityOption] {
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

    private var actionButtons: some View {
        HStack(spacing: 8) {
            SettingsInlineActionButton(title: isSaving ? "Saving…" : "Save Name", tone: .accent) {
                saveName()
            }
            .disabled(!canSave || isSaving)

            overflowMenu
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
        var parts = [item.meetingTitle]
        if let dateText = Self.dateFormatter.stringIfAvailable(from: item.recordedAt ?? item.fallbackDate) {
            parts.append(dateText)
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
        model.namePendingReviewItem(group.representative, to: nameDraft) { didSave in
            isSaving = false
            if didSave {
                nameDraft = ""
            } else {
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

private struct SpeakerPlayClipButton: View {
    let hasClip: Bool
    let isPlaying: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: SpeakerClipPlaybackPresentation.symbolName(isPlaying: isPlaying))
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(hasClip ? Color.white : Color.secondary)
                .frame(
                    width: SpeakerPeopleSettingsPolishContract.playButtonVisibleDiameter,
                    height: SpeakerPeopleSettingsPolishContract.playButtonVisibleDiameter
                )
                .background(Circle().fill(hasClip ? Color.accentColor : Color.primary.opacity(0.06)))
                .overlay(
                    Circle()
                        .stroke(Color.accentColor.opacity(isActive ? 0.9 : 0), lineWidth: 2)
                        .padding(-2)
                )
                .frame(
                    width: SpeakerPeopleSettingsPolishContract.minimumHitTarget,
                    height: SpeakerPeopleSettingsPolishContract.minimumHitTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasClip)
        .help(SpeakerClipPlaybackPresentation.helpText(hasClip: hasClip, isPlaying: isPlaying))
        .accessibilityLabel(SpeakerClipPlaybackPresentation.accessibilityLabel(isPlaying: isPlaying))
        .accessibilityIdentifier("transcripted.speakers.voice-to-name.play")
    }

    private var isActive: Bool {
        SpeakerClipPlaybackPresentation.isActiveHighlight(hasClip: hasClip, isPlaying: isPlaying)
    }
}

private extension DateFormatter {
    func stringIfAvailable(from date: Date) -> String? {
        date == .distantPast ? nil : string(from: date)
    }
}

// MARK: - Possible duplicates

private struct SpeakerDuplicateCandidateRow: View {
    let candidate: SpeakerDuplicateCandidate
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    @State private var showMergeConfirmation = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    SpeakerDuplicateNameChip(profile: candidate.source, model: model)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)

                    SpeakerDuplicateNameChip(profile: candidate.target, model: model)
                }

                Text(candidate.summaryLine)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsInlineActionButton(title: "Merge", symbolName: "arrow.triangle.merge", tone: .accent) {
                showMergeConfirmation = true
            }
            .help("Merge \(SpeakerDuplicateCandidate.displayName(for: candidate.source)) into \(SpeakerDuplicateCandidate.displayName(for: candidate.target))")
        }
        .padding(.vertical, 4)
        .alert(mergeConfirmationTitle, isPresented: $showMergeConfirmation) {
            Button("Merge") {
                model.merge(source: candidate.source, into: candidate.target)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This combines their history and can't be undone. Past transcripts are updated.")
        }
    }

    private var mergeConfirmationTitle: String {
        let source = SpeakerDuplicateCandidate.displayName(for: candidate.source)
        let target = SpeakerDuplicateCandidate.displayName(for: candidate.target)
        return "Merge “\(source)” into “\(target)”?"
    }
}

private struct SpeakerDuplicateNameChip: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    var body: some View {
        Button {
            model.playSample(for: profile.id)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))

                Text(chipTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
        }
        .buttonStyle(SettingsHoverButtonStyle(
            tone: .accent,
            cornerRadius: 8,
            normalFill: Color.primary.opacity(0.04),
            normalStroke: Color.primary.opacity(0.08)
        ))
        .disabled(!hasClip)
        .help(helpText)
    }

    private var chipTitle: String {
        let name = SpeakerDuplicateCandidate.displayName(for: profile)
        let meetings = profile.callCount == 1 ? "1 meeting" : "\(profile.callCount) meetings"
        return "\(name) · \(meetings)"
    }

    private var hasClip: Bool {
        model.clipURL(for: profile.id) != nil
    }

    private var isPlaying: Bool {
        model.isPlayingSample(for: profile.id)
    }

    private var iconName: String {
        guard hasClip else { return "person.crop.circle" }
        return isPlaying ? "pause.circle.fill" : "play.circle.fill"
    }

    private var helpText: String {
        guard hasClip else { return "No voice clip saved" }
        return isPlaying ? "Pause this voice" : "Play this voice"
    }
}

// MARK: - All speakers

private struct SpeakerSearchRow: View {
    @ObservedObject var model: SpeakerPeopleSettingsViewModel
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            TextField("Search speakers", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
                .focused($isSearchFocused)
                // Fires on first appearance and whenever ⌘F bumps the token,
                // so "Find Speaker" focuses the field whether or not the
                // Speakers page was already open.
                .task(id: model.searchFocusRequestToken) {
                    guard model.searchFocusRequestToken > 0 else { return }
                    isSearchFocused = true
                }

            Button {
                model.refresh()
            } label: {
                SpeakerCompactIconLabel(
                    systemName: "arrow.clockwise",
                    foregroundColor: .primary,
                    fontSize: 12,
                    fontWeight: .semibold
                )
            }
            .buttonStyle(.plain)
            .help("Refresh the speaker list")
            .accessibilityLabel("Refresh speakers")
            .accessibilityIdentifier("transcripted.speakers.refresh")
        }
    }
}

private struct SpeakerPersonRow: View {
    let profile: SpeakerProfile
    @ObservedObject var model: SpeakerPeopleSettingsViewModel

    @State private var isEditing = false
    @State private var renameDraft: String = ""
    @State private var showDeleteConfirmation = false
    @State private var pendingMergeTarget: SpeakerProfile?
    @State private var showMergeConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                SpeakerAvatarView(name: profile.displayName)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(displayName)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(profile.displayName == nil ? .secondary : .primary)
                            .lineLimit(1)

                        if let badge {
                            SpeakerStatusBadge(title: badge)
                        }
                    }

                    Text(metadataLine)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

                if hasClip {
                    Button {
                        model.playSample(for: profile.id)
                    } label: {
                        SpeakerCompactIconLabel(
                            systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill",
                            foregroundColor: .accentColor,
                            fontSize: 15,
                            fontWeight: .semibold,
                            tone: .accent,
                            normalFill: .clear,
                            normalStroke: .clear
                        )
                    }
                    .buttonStyle(.plain)
                    .help(isPlaying ? "Pause this voice" : "Play this voice")
                    .accessibilityLabel(isPlaying ? "Pause voice sample" : "Play voice sample")
                    .accessibilityIdentifier("transcripted.speakers.person.play")
                }

                rowMenu
            }

            if isEditing {
                renameEditor
            }
        }
        .padding(.vertical, 10)
        .alert("Delete this speaker?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.delete(profile: profile)
            }
            Button("Cancel", role: .cancel) {}
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
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This combines their history and can't be undone. Past transcripts are updated.")
        }
    }

    private var rowMenu: some View {
        Menu {
            Button(profile.displayName == nil ? "Add Name…" : "Rename…") {
                renameDraft = profile.displayName ?? ""
                isEditing = true
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

    private var metadataLine: String {
        let meetings = profile.callCount == 1 ? "1 meeting" : "\(profile.callCount) meetings"
        var parts = [meetings]
        if let lastHeard = Self.relativeFormatter.string(for: profile.lastSeen) {
            parts.append("last heard \(lastHeard)")
        }
        return parts.joined(separator: " · ")
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
        TextField("Speaker name", text: $renameDraft)
            .textFieldStyle(.roundedBorder)
            .onSubmit(saveRename)
    }

    private var renameButtons: some View {
        HStack(spacing: 8) {
            SettingsInlineActionButton(title: "Save", tone: .accent) {
                saveRename()
            }
            .disabled(renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            SettingsInlineActionButton(title: "Cancel") {
                renameDraft = ""
                isEditing = false
            }
        }
    }

    private func saveRename() {
        let trimmed = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.rename(profile: profile, to: trimmed)
        isEditing = false
    }

    private var badge: String? {
        if model.duplicateCount(for: profile) > 0 {
            return "Possible duplicate"
        }
        if profile.disputeCount > 0 {
            return "Check name"
        }
        return nil
    }

    private var hasClip: Bool {
        model.clipURL(for: profile.id) != nil
    }

    private var isPlaying: Bool {
        model.isPlayingSample(for: profile.id)
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
            .frame(width: 32, height: 32)
            .overlay(
                Text(initials)
                    .font(.system(size: 12, weight: .bold))
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
        let palette: [NSColor] = [
            .systemBlue,
            .systemGreen,
            .systemPurple,
            .systemOrange,
            .systemPink,
            .systemTeal,
            .systemRed,
            .systemIndigo,
        ]
        let normalized = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let value = normalized.unicodeScalars.reduce(UInt32(0)) { partial, scalar in
            partial &+ scalar.value
        }
        return Color(nsColor: palette[Int(value % UInt32(palette.count))])
    }
}

private struct SpeakerStatusBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.orange)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange.opacity(0.12)))
    }
}
