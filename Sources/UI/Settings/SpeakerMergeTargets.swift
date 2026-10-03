import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

/// The "Merge Into" order for every saved person, built once per Speakers refresh.
///
/// Order for one person: their possible duplicates first, then everyone else;
/// within each group by name A to Z ignoring case (unnamed voices sort as
/// "Unknown voice"), the same name by most meetings first, never the person
/// themselves.
///
/// Instead of a sorted N-1 list per person (N^2 memory, N localized sorts), it
/// keeps one shared sorted array and hands each row a small view over it.
/// When two different saved names compare equal ignoring case ("Alice" and
/// "alice", or "unknown voice" next to unnamed voices), the old comparator
/// isn't a consistent order, so the index falls back to sorting per person
/// exactly as before.
struct SpeakerMergeTargetIndex: Sendable {
    private enum Storage: Sendable {
        case shared(
            order: [SpeakerProfile],
            positionByID: [UUID: Int],
            duplicatePositionsByID: [UUID: [Int]]
        )
        case perProfile([UUID: [SpeakerProfile]])
    }

    static let placeholderName = "Unknown voice"
    static let empty = SpeakerMergeTargetIndex(storage: .perProfile([:]))

    private let storage: Storage

    private init(storage: Storage) {
        self.storage = storage
    }

    init(profiles: [SpeakerProfile], duplicatePeerIDsByProfileID: [UUID: Set<UUID>]) {
        let names = profiles.map { $0.displayName ?? Self.placeholderName }
        guard !Self.hasCaseVariantNames(names) else {
            var table: [UUID: [SpeakerProfile]] = [:]
            table.reserveCapacity(profiles.count)
            for profile in profiles {
                table[profile.id] = Self.perProfileSortedTargets(
                    for: profile,
                    in: profiles,
                    duplicatePeerIds: duplicatePeerIDsByProfileID[profile.id] ?? []
                )
            }
            storage = .perProfile(table)
            return
        }

        // One stable sort: name (case-insensitive), same name by most meetings,
        // then the incoming order (what a stable per-person sort keeps).
        let sortedIndices = profiles.indices.sorted { lhs, rhs in
            let lhsName = names[lhs]
            let rhsName = names[rhs]
            if lhsName == rhsName {
                let lhsCalls = profiles[lhs].callCount
                let rhsCalls = profiles[rhs].callCount
                if lhsCalls != rhsCalls { return lhsCalls > rhsCalls }
                return lhs < rhs
            }
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }

        let order = sortedIndices.map { profiles[$0] }
        var positionByID: [UUID: Int] = [:]
        positionByID.reserveCapacity(order.count)
        for (position, profile) in order.enumerated() {
            positionByID[profile.id] = position
        }

        var duplicatePositionsByID: [UUID: [Int]] = [:]
        for (profileID, peerIDs) in duplicatePeerIDsByProfileID {
            guard positionByID[profileID] != nil else { continue }
            let positions = peerIDs
                .filter { $0 != profileID }
                .compactMap { positionByID[$0] }
                .sorted()
            if !positions.isEmpty {
                duplicatePositionsByID[profileID] = positions
            }
        }

        storage = .shared(
            order: order,
            positionByID: positionByID,
            duplicatePositionsByID: duplicatePositionsByID
        )
    }

    /// O(1) to build: it only captures the shared buffers. Safe to call from a
    /// row's body on every pass.
    func targets(for profileID: UUID) -> SpeakerMergeTargetList {
        switch storage {
        case .shared(let order, let positionByID, let duplicatePositionsByID):
            guard let selfPosition = positionByID[profileID] else { return SpeakerMergeTargetList() }
            return SpeakerMergeTargetList(
                order: order,
                selfPosition: selfPosition,
                duplicatePositions: duplicatePositionsByID[profileID] ?? []
            )
        case .perProfile(let table):
            return SpeakerMergeTargetList(explicit: table[profileID] ?? [])
        }
    }

    /// True when two different names would compare equal ignoring case, which
    /// makes the per-person comparator order depend on the input.
    static func hasCaseVariantNames(_ names: [String]) -> Bool {
        let distinct = Array(Set(names))
        guard distinct.count > 1 else { return false }
        let sorted = distinct.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        for index in sorted.indices.dropFirst()
        where sorted[index - 1].localizedCaseInsensitiveCompare(sorted[index]) == .orderedSame {
            return true
        }
        return false
    }

    /// The original per-person sort, kept as the exact fallback.
    static func perProfileSortedTargets(
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

            let lhsName = lhs.displayName ?? placeholderName
            let rhsName = rhs.displayName ?? placeholderName
            if lhsName == rhsName {
                return lhs.callCount > rhs.callCount
            }
            return lhsName.localizedCaseInsensitiveCompare(rhsName) == .orderedAscending
        }
    }
}

/// One person's "Merge Into" list: a view over the shared sorted order that
/// lists their duplicate peers first, then every other position except
/// themselves. Subscripting costs O(k), where k is their duplicate count.
struct SpeakerMergeTargetList: RandomAccessCollection, Sendable {
    private let order: [SpeakerProfile]
    private let duplicatePositions: [Int]
    /// Sorted positions skipped in the "everyone else" part: self plus duplicates.
    private let excludedPositions: [Int]
    let endIndex: Int

    var startIndex: Int { 0 }

    init() {
        order = []
        duplicatePositions = []
        excludedPositions = []
        endIndex = 0
    }

    init(explicit targets: [SpeakerProfile]) {
        order = targets
        duplicatePositions = []
        excludedPositions = []
        endIndex = targets.count
    }

    init(order: [SpeakerProfile], selfPosition: Int, duplicatePositions: [Int]) {
        self.order = order
        self.duplicatePositions = duplicatePositions
        var excluded = duplicatePositions
        let insertAt = excluded.firstIndex { $0 > selfPosition } ?? excluded.count
        excluded.insert(selfPosition, at: insertAt)
        excludedPositions = excluded
        endIndex = order.count - 1
    }

    subscript(position: Int) -> SpeakerProfile {
        precondition(position >= 0 && position < endIndex, "merge target index out of range")
        if position < duplicatePositions.count {
            return order[duplicatePositions[position]]
        }
        var orderPosition = position - duplicatePositions.count
        for excluded in excludedPositions {
            guard excluded <= orderPosition else { break }
            orderPosition += 1
        }
        return order[orderPosition]
    }
}
