import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

enum SpeakerDuplicateReason: Int {
    case sameNameAndVoice
    case sameName
    case similarNameAndVoice
    case similarName
    case voiceMatch

    var title: String {
        switch self {
        case .sameNameAndVoice: return "Same saved name and similar voice"
        case .sameName: return "Same saved name"
        case .similarNameAndVoice: return "Similar saved name and voice"
        case .similarName: return "Similar saved name"
        case .voiceMatch: return "Similar voice"
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
        guard let voiceSimilarity else { return reason.title }
        let percent = Self.percentFormatter.string(from: NSNumber(value: voiceSimilarity)) ?? "similar"
        return "\(reason.title) • \(percent) voice similarity"
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

enum SpeakerDuplicateReviewPolicy {
    static let maxVisibleCandidates = 25

    static func candidates(from profiles: [SpeakerProfile]) -> [SpeakerDuplicateCandidate] {
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

    private static func duplicateReason(
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

    private static func suggestedMergeTarget(_ lhs: SpeakerProfile, _ rhs: SpeakerProfile) -> SpeakerProfile {
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

    private static func normalizedName(_ name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func namesLookRelated(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs, lhs != rhs else { return false }

        let lhsTokens = nameTokens(lhs)
        let rhsTokens = nameTokens(rhs)
        guard !lhsTokens.isEmpty, !rhsTokens.isEmpty else { return false }
        let lhsSignificantName = significantNameText(lhs)
        let rhsSignificantName = significantNameText(rhs)
        if lhsSignificantName.count >= 3
            && rhsSignificantName.count >= 3
            && (lhsSignificantName.contains(rhsSignificantName) || rhsSignificantName.contains(lhsSignificantName)) {
            return true
        }
        return lhsTokens.isSubset(of: rhsTokens) || rhsTokens.isSubset(of: lhsTokens)
    }

    private static func significantNameText(_ name: String) -> String {
        significantNameTokens(name).joined(separator: " ")
    }

    private static func nameTokens(_ name: String) -> Set<String> {
        Set(significantNameTokens(name))
    }

    private static func significantNameTokens(_ name: String) -> [String] {
        let ignoredTokens: Set<String> = ["speaker", "unknown", "unnamed", "person", "profile"]
        return name
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !ignoredTokens.contains($0) }
    }

    private static func cosineSimilarity(_ lhs: [Float], _ rhs: [Float]) -> Double? {
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
}
