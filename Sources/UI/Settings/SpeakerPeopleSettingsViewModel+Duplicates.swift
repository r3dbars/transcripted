import SwiftUI
import AppKit
import Combine
import TranscriptedCore

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

extension SpeakerPeopleSettingsViewModel {
    var isMovingPeopleToNewVoiceModel: Bool {
        if case .moving = voiceprintMigrationPhase { return true }
        return false
    }

    /// The quiet line at the top of Speakers while saved people move to a new
    /// voice model, and afterwards while some of them need one confirmation.
    var voiceprintMigrationStatusLine: String? {
        switch voiceprintMigrationPhase {
        case .moving(let completed, let total?) where total > 0:
            return "Moving your saved people to the new voice model… \(completed) of \(total)"
        case .moving:
            return "Moving your saved people to the new voice model…"
        case .finished(let summary) where summary.peopleNeedingConfirmation > 0:
            let count = summary.peopleNeedingConfirmation
            let who = count == 1 ? "1 saved person needs" : "\(count) saved people need"
            return "\(who) one confirmation with the new voice model. Confirm them when a meeting asks who they are."
        case .failed:
            return "Your saved people haven't moved to the new voice model yet. Transcripted tries again the next time it opens."
        case .idle, .finished:
            return nil
        }
    }

    func playSample(for item: SpeakerPendingReviewItem) {
        if let url = item.clipURL {
            SpeakerClipPlayback.play(url)
        } else if let sample = item.retainedAudioSample {
            SpeakerClipPlayback.shared.play(sample)
        }
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

    nonisolated static func sortedMergeTargets(
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

    nonisolated static func duplicateCandidates(from profiles: [SpeakerProfile]) -> [SpeakerDuplicateCandidate] {
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

    nonisolated static func clipURL(
        for speakerId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) -> URL? {
        SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: preferredClipsDirectory)
            ?? SpeakerClipExtractor.persistentClipURL(for: speakerId, clipsDirectory: legacyClipsDirectory)
    }

    nonisolated static func deleteClips(
        for speakerId: UUID,
        preferredClipsDirectory: URL,
        legacyClipsDirectory: URL
    ) {
        SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: preferredClipsDirectory)
        if legacyClipsDirectory != preferredClipsDirectory {
            SpeakerClipExtractor.deletePersistedClip(for: speakerId, clipsDirectory: legacyClipsDirectory)
        }
    }

    nonisolated static func promoteClipIfNeeded(
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
