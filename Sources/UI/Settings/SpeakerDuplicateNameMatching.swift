import Foundation

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

/// A saved name prepared once per profile for the pairwise duplicate scan, so
/// the scan doesn't trim, lowercase and tokenize both names for every pair.
struct SpeakerDuplicateNameKey: Sendable {
    /// Trimmed and lowercased, or nil for an unnamed or blank name.
    let normalized: String?
    let characterCount: Int
    let tokens: Set<String>

    init(displayName: String?) {
        guard let trimmed = displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            normalized = nil
            characterCount = 0
            tokens = []
            return
        }
        let lowered = trimmed.lowercased()
        normalized = lowered
        characterCount = lowered.count
        tokens = Set(lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 })
    }
}

/// Why two saved people look like the same person, if they do.
enum SpeakerDuplicateMatchPolicy {
    static func reason(
        _ lhs: SpeakerDuplicateNameKey,
        _ rhs: SpeakerDuplicateNameKey,
        lhsDisputeCount: Int,
        rhsDisputeCount: Int,
        voiceSimilarity: Double?
    ) -> SpeakerDuplicateReason? {
        let sameName = lhs.normalized != nil && lhs.normalized == rhs.normalized
        let similarName = !sameName && namesLookRelated(lhs, rhs)

        let nameConflict = lhs.normalized != nil && rhs.normalized != nil && !sameName && !similarName
        let voiceThreshold = nameConflict ? 0.96 : 0.90
        let voiceMatch = lhsDisputeCount == 0
            && rhsDisputeCount == 0
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

    static func namesLookRelated(_ lhs: SpeakerDuplicateNameKey, _ rhs: SpeakerDuplicateNameKey) -> Bool {
        guard let lhsName = lhs.normalized, let rhsName = rhs.normalized, lhsName != rhsName else {
            return false
        }
        if lhs.characterCount >= 3 && rhs.characterCount >= 3
            && (lhsName.contains(rhsName) || rhsName.contains(lhsName)) {
            return true
        }

        guard !lhs.tokens.isEmpty, !rhs.tokens.isEmpty else { return false }
        return lhs.tokens.isSubset(of: rhs.tokens) || rhs.tokens.isSubset(of: lhs.tokens)
    }
}
