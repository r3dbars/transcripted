import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

struct SpeakerDuplicateCandidate: Identifiable, Sendable {
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

enum SpeakerDuplicateDetection {
    static func duplicateCandidates(
        from profiles: [SpeakerProfile],
        similarity: ([Float], [Float]) -> Double?
    ) -> [SpeakerDuplicateCandidate] {
        guard profiles.count > 1 else { return [] }

        // Normalize and tokenize each name once, not once per pair.
        let nameKeys = profiles.map { SpeakerDuplicateNameKey(displayName: $0.displayName) }
        var candidates: [SpeakerDuplicateCandidate] = []
        var seenPairs = Set<String>()

        for lhsIndex in profiles.indices {
            for rhsIndex in profiles.indices where rhsIndex > lhsIndex {
                let lhs = profiles[lhsIndex]
                let rhs = profiles[rhsIndex]
                let voiceSimilarity = similarity(lhs.embedding, rhs.embedding)
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

    private static func suggestedMergeTarget(
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



}

/// Whole-profile equality keeps cached candidates' embedded profiles current,
/// including fields used by merge previews but not by duplicate detection.
/// Access is serialized with the snapshot queue, or the lock for test callers.
final class SpeakerDuplicateSnapshotCache: @unchecked Sendable {
    private let lock = NSLock()
    private var profiles: [ProfileKey]?
    private var candidates: [SpeakerDuplicateCandidate] = []

    func candidates(
        from profiles: [SpeakerProfile],
        build: ([SpeakerProfile]) -> [SpeakerDuplicateCandidate]
    ) -> [SpeakerDuplicateCandidate] {
        let keys = profiles.map(ProfileKey.init)
        return lock.withLock {
            if self.profiles == keys { return candidates }
            let fresh = build(profiles)
            self.profiles = keys
            candidates = fresh
            return fresh
        }
    }

    private struct ProfileKey: Equatable {
        let id: UUID
        let displayName: String?
        let nameSource: String?
        let embedding: [Float]
        let exemplars: [[Float]]
        let firstSeen: Date
        let lastSeen: Date
        let callCount: Int
        let confirmedMeetingCount: Int
        let confidence: Double
        let disputeCount: Int

        init(_ profile: SpeakerProfile) {
            id = profile.id
            displayName = profile.displayName
            nameSource = profile.nameSource
            embedding = profile.embedding
            exemplars = profile.exemplars
            firstSeen = profile.firstSeen
            lastSeen = profile.lastSeen
            callCount = profile.callCount
            confirmedMeetingCount = profile.confirmedMeetingCount
            confidence = profile.confidence
            disputeCount = profile.disputeCount
        }
    }
}
