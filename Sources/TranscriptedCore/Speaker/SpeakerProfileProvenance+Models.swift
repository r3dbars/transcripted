// SpeakerProfileProvenance+Models.swift
// Value types and snapshot coding for speaker provenance, moved unchanged out of
// SpeakerProfileProvenance.swift (which owns the tables and the un-merge paths).

import Foundation

/// User-facing record of a merge that can be undone.
public struct SpeakerMergeRecord: Identifiable, Sendable {
    public let id: UUID
    public let sourceId: UUID
    public let targetId: UUID
    public let sourceName: String?
    public let targetName: String?
    public let kind: String          // SpeakerMergeKind.rawValue
    public let mergedAt: Date
    public let isUndone: Bool

    public init(
        id: UUID,
        sourceId: UUID,
        targetId: UUID,
        sourceName: String?,
        targetName: String?,
        kind: String,
        mergedAt: Date,
        isUndone: Bool
    ) {
        self.id = id
        self.sourceId = sourceId
        self.targetId = targetId
        self.sourceName = sourceName
        self.targetName = targetName
        self.kind = kind
        self.mergedAt = mergedAt
        self.isUndone = isUndone
    }
}

/// Audit record of a single contribution (clip/recording mean embedding, or a merge
/// fusion marker) that built a profile.
public struct SpeakerContribution: Identifiable, Sendable {
    public let id: UUID
    public let profileId: UUID
    public let kind: String          // SpeakerProvenanceKind.rawValue
    public let sourceProfileId: UUID? // set for `merge` fusion markers
    public let recordedAt: Date
    public let hasEmbedding: Bool

    public init(
        id: UUID,
        profileId: UUID,
        kind: String,
        sourceProfileId: UUID?,
        recordedAt: Date,
        hasEmbedding: Bool
    ) {
        self.id = id
        self.profileId = profileId
        self.kind = kind
        self.sourceProfileId = sourceProfileId
        self.recordedAt = recordedAt
        self.hasEmbedding = hasEmbedding
    }
}

/// Where a provenance row came from.
public enum SpeakerProvenanceKind {
    public static let seed = "seed"                 // first embedding that created the profile
    public static let contribution = "contribution" // a later recording's mean embedding
    public static let merge = "merge"               // marker: an absorbed profile fused in here
}

/// What kind of merge produced a merge event.
public enum SpeakerMergeKind {
    public static let explicit = "explicit"   // user/coordinator merged two profiles
    public static let duplicate = "duplicate" // auto duplicate-merge after a recording
    public static let byName = "by_name"      // same-display-name fuse
}

@available(macOS 14.0, *)
extension SpeakerDatabase {

    // MARK: - Snapshot coding

    struct ProfileSnapshot: Codable {
        let id: UUID
        let displayName: String?
        let nameSource: String?
        let embedding: [Float]
        let firstSeen: String
        let lastSeen: String
        let callCount: Int
        let confidence: Double
        let disputeCount: Int
    }

    static func encodeProfileSnapshot(_ profile: SpeakerProfile) -> String? {
        let isoFormatter = ISO8601DateFormatter()
        let snapshot = ProfileSnapshot(
            id: profile.id,
            displayName: profile.displayName,
            nameSource: profile.nameSource,
            embedding: profile.embedding,
            firstSeen: isoFormatter.string(from: profile.firstSeen),
            lastSeen: isoFormatter.string(from: profile.lastSeen),
            callCount: profile.callCount,
            confidence: profile.confidence,
            disputeCount: profile.disputeCount
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func decodeProfileSnapshot(_ json: String) -> ProfileSnapshot? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ProfileSnapshot.self, from: data)
    }
}
