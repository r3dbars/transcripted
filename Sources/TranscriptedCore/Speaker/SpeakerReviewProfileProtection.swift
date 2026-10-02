import Foundation

/// Saved-person ids that open speaker reviews still point at.
///
/// Every finished transcription runs duplicate cleanup and weak-profile pruning
/// over the whole people database. Those used to protect only the finishing
/// meeting's own review rows, so a review left open (or queued behind another)
/// could have its people merged away or deleted before the user pressed Save,
/// and the save then failed. The pipeline runner reads this off the main actor,
/// so it is lock-protected rather than main-actor state.
final class SpeakerReviewProfileProtection: @unchecked Sendable {
    private struct Entry {
        let transcriptId: UUID
        let profileIds: Set<UUID>
    }

    private let lock = NSLock()
    private var entriesByRequestId: [UUID: Entry] = [:]

    private static func profileIds(for request: SpeakerNamingRequest) -> Set<UUID> {
        var ids = Set<UUID>()
        for entry in request.speakers {
            ids.insert(entry.id)
            if let suggestedProfileId = entry.suggestedProfileId {
                ids.insert(suggestedProfileId)
            }
            if let snapshotId = entry.matchedProfileSnapshot?.id {
                ids.insert(snapshotId)
            }
        }
        return ids
    }

    func protect(_ request: SpeakerNamingRequest) {
        let ids = Self.profileIds(for: request)
        lock.lock()
        entriesByRequestId[request.id] = Entry(transcriptId: request.transcriptId, profileIds: ids)
        lock.unlock()
    }

    /// Adds the people a Save is about to write to (picked, same-name and coalesced
    /// targets) to a review that is still registered, so another meeting's cleanup
    /// cannot merge or prune them before the save lands. Never registers a review that
    /// was already released.
    func extend(requestId: UUID?, transcriptId: UUID, with ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for (key, entry) in entriesByRequestId
        where requestId.map({ $0 == key }) ?? (entry.transcriptId == transcriptId) {
            entriesByRequestId[key] = Entry(
                transcriptId: entry.transcriptId,
                profileIds: entry.profileIds.union(ids)
            )
        }
    }

    func release(requestId: UUID) {
        lock.lock()
        entriesByRequestId.removeValue(forKey: requestId)
        lock.unlock()
    }

    func release(transcriptId: UUID) {
        lock.lock()
        entriesByRequestId = entriesByRequestId.filter { $0.value.transcriptId != transcriptId }
        lock.unlock()
    }

    func releaseAll() {
        lock.lock()
        entriesByRequestId.removeAll()
        lock.unlock()
    }

    var protectedProfileIds: Set<UUID> {
        lock.lock()
        defer { lock.unlock() }
        return entriesByRequestId.values.reduce(into: Set<UUID>()) { $0.formUnion($1.profileIds) }
    }
}
