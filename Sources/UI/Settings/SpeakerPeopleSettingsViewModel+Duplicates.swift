import SwiftUI
import AppKit
import Combine
import TranscriptedCore

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

    nonisolated static func duplicateCandidates(from profiles: [SpeakerProfile]) -> [SpeakerDuplicateCandidate] {
        guard profiles.count > 1 else { return [] }

        // Normalize and tokenize each name once, not once per pair.
        let nameKeys = profiles.map { SpeakerDuplicateNameKey(displayName: $0.displayName) }
        var candidates: [SpeakerDuplicateCandidate] = []
        var seenPairs = Set<String>()

        for lhsIndex in profiles.indices {
            for rhsIndex in profiles.indices where rhsIndex > lhsIndex {
                let lhs = profiles[lhsIndex]
                let rhs = profiles[rhsIndex]
                let voiceSimilarity = cosineSimilarity(lhs.embedding, rhs.embedding)
                guard let reason = SpeakerDuplicateMatchPolicy.reason(
                    nameKeys[lhsIndex],
                    nameKeys[rhsIndex],
                    lhsDisputeCount: lhs.disputeCount,
                    rhsDisputeCount: rhs.disputeCount,
                    voiceSimilarity: voiceSimilarity
                ) else {
                    continue
                }

                let pairId = [lhs.id.uuidString, rhs.id.uuidString].sorted().joined(separator: "-")
                guard !seenPairs.contains(pairId) else { continue }
                seenPairs.insert(pairId)

                let target = suggestedMergeTarget(
                    lhs,
                    rhs,
                    lhsNamed: nameKeys[lhsIndex].normalized != nil,
                    rhsNamed: nameKeys[rhsIndex].normalized != nil
                )
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

    nonisolated private static func suggestedMergeTarget(
        _ lhs: SpeakerProfile,
        _ rhs: SpeakerProfile,
        lhsNamed: Bool,
        rhsNamed: Bool
    ) -> SpeakerProfile {
        if lhs.callCount != rhs.callCount {
            return lhs.callCount > rhs.callCount ? lhs : rhs
        }

        if lhsNamed != rhsNamed {
            return lhsNamed ? lhs : rhs
        }

        return lhs.lastSeen >= rhs.lastSeen ? lhs : rhs
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
