import Foundation

/// Tracks which review generation owns each stable transcript identity.
///
/// Callers deliberately consult and mutate this registry while holding
/// `TranscriptSaver`'s file-update serializer. That makes ownership changes
/// atomic with transcript replacement/finalization ordering: a stale callback
/// either finishes before supersession (and is then overwritten by the new
/// transcript) or observes that it no longer owns the file and does nothing.
final class SpeakerNamingRequestOwnership: @unchecked Sendable {
    private struct Entry {
        let requestId: UUID
        let transcriptURL: URL
    }

    private let lock = NSLock()
    private var entriesByTranscriptId: [UUID: [Entry]] = [:]

    func install(requestId: UUID, transcriptId: UUID, transcriptURL: URL) {
        lock.lock()
        var entries = entriesByTranscriptId[transcriptId, default: []]
        entries.removeAll { $0.requestId == requestId }
        entries.append(Entry(
            requestId: requestId,
            transcriptURL: transcriptURL.standardizedFileURL
        ))
        entriesByTranscriptId[transcriptId] = entries
        lock.unlock()
    }

    func isCurrent(requestId: UUID, transcriptId: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entriesByTranscriptId[transcriptId]?.last?.requestId == requestId
    }

    func requestId(transcriptId: UUID) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return entriesByTranscriptId[transcriptId]?.last?.requestId
    }

    func requests(transcriptURL: URL) -> [UUID: Set<UUID>] {
        let targetURL = transcriptURL.standardizedFileURL
        lock.lock()
        defer { lock.unlock() }
        return entriesByTranscriptId.compactMapValues { entries in
            let requestIds = Set(entries.compactMap { entry in
                entry.transcriptURL == targetURL ? entry.requestId : nil
            })
            return requestIds.isEmpty ? nil : requestIds
        }
    }

    func invalidate(transcriptId: UUID, requestId: UUID? = nil) {
        lock.lock()
        defer { lock.unlock() }
        if let requestId {
            entriesByTranscriptId[transcriptId]?.removeAll { $0.requestId == requestId }
            if entriesByTranscriptId[transcriptId]?.isEmpty == true {
                entriesByTranscriptId.removeValue(forKey: transcriptId)
            }
        } else {
            entriesByTranscriptId.removeValue(forKey: transcriptId)
        }
    }
}
