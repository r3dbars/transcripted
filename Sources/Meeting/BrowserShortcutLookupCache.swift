import Foundation

/// Owns shortcut classification for both workspace activations and mic evidence.
/// Results (including misses) last until the app terminates or the detector stops.
@MainActor
final class BrowserShortcutLookupCache {
    enum LookupResult: Equatable {
        case resolved(MeetingPromptProvider?)
        case invalidated
    }

    struct Activation {
        let bundleID: String
        let provider: MeetingPromptProvider
        let at: Date
    }

    private final class Entry {
        var task: Task<MeetingPromptProvider?, Never>?
        var provider: MeetingPromptProvider?
    }

    private var entries: [String: Entry] = [:]
    private(set) var recentActivation: Activation?

    func hasLookup(for bundleID: String) -> Bool { entries[bundleID] != nil }

    func provider(for bundleID: String) -> MeetingPromptProvider? {
        entries[bundleID]?.provider
    }

    /// Admits the request synchronously, so concurrent callers share one resolver.
    func request(
        _ bundleID: String,
        activatedAt: Date? = nil,
        resolver: @escaping (String) async -> MeetingPromptProvider?
    ) -> Task<LookupResult, Never> {
        let entry: Entry
        if let existing = entries[bundleID] {
            entry = existing
        } else {
            entry = Entry()
            entry.task = Task { @MainActor in await resolver(bundleID) }
            entries[bundleID] = entry
        }
        let resolverTask = entry.task
        return Task { @MainActor in
            if let resolverTask {
                let provider = await resolverTask.value
                guard self.entries[bundleID] === entry else { return .invalidated }
                entry.provider = provider
                entry.task = nil
            }
            guard self.entries[bundleID] === entry else { return .invalidated }
            if let activatedAt, let provider = entry.provider {
                self.recordActivation(bundleID: bundleID, provider: provider, at: activatedAt)
            }
            return .resolved(entry.provider)
        }
    }

    /// Also accepts a known classification from the detector's existing entry point.
    func noteActivation(bundleID: String, provider: MeetingPromptProvider, at: Date) {
        if entries[bundleID]?.task != nil || entries[bundleID]?.provider != provider {
            entries[bundleID]?.task?.cancel()
            let entry = Entry()
            entry.provider = provider
            entries[bundleID] = entry
        }
        recordActivation(bundleID: bundleID, provider: provider, at: at)
    }

    private func recordActivation(bundleID: String, provider: MeetingPromptProvider, at: Date) {
        guard recentActivation.map({ at >= $0.at }) ?? true else { return }
        recentActivation = Activation(bundleID: bundleID, provider: provider, at: at)
    }

    func invalidate(_ bundleID: String) {
        entries.removeValue(forKey: bundleID)?.task?.cancel()
        if recentActivation?.bundleID == bundleID { recentActivation = nil }
    }

    func removeAll() {
        for entry in entries.values { entry.task?.cancel() }
        entries.removeAll()
        recentActivation = nil
    }
}
