#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Aggregate-only keyboard counters. Personal History is a separate, explicit subsystem.
enum GhostStats {
    private static let live = GhostStatsStore()

    static func recordAccepted(_ text: String) { live.recordAccepted(text) }
    static func recordSuggestionShown() { live.recordSuggestionShown() }
    static func recordSuggestionAccepted() { live.recordSuggestionAccepted() }
    static func recordFailure(_ outcome: GhostBrainResponse.Outcome) { live.recordFailure(outcome) }
    static func flush(force: Bool = false) { live.flush(force: force) }
}

/// Each store owns its aggregation state. Tests inject in-memory preferences,
/// a fixed clock and a serial queue instead of sharing the live keyboard store.
final class GhostStatsStore: @unchecked Sendable {
    private let persistenceQueue: DispatchQueue
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var pending = [String: Int]()
    private var lastFlush = Date.distantPast

    init(
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = { Date() },
        persistenceQueue: DispatchQueue = DispatchQueue(
            label: "com.justinbetker.draft.keyboard.ghost-stats", qos: .utility
        )
    ) {
        self.defaults = defaults
        self.now = now
        self.persistenceQueue = persistenceQueue
    }

    func recordAccepted(_ text: String) {
        let count = text.split(whereSeparator: \Character.isWhitespace).count
        guard count > 0 else { return }
        record(count, key: "wordsAccepted")
    }

    func recordSuggestionShown() {
        record(1, key: "suggestionsShown")
    }

    func recordSuggestionAccepted() {
        record(1, key: "suggestionsAccepted")
    }

    func recordFailure(_ outcome: GhostBrainResponse.Outcome) {
        let key: String
        switch outcome {
        case .error: key = "completionErrors"
        case .timeout: key = "completionTimeouts"
        case .invalidRequest, .unsupported: key = "completionInvalidRequests"
        case .suggestion, .silence, .unavailable, .recorded: return
        }
        record(1, key: key)
    }

    private func record(_ count: Int, key: String) {
        let now = now()
        persistenceQueue.async { [self] in
            pending[key, default: 0] += count
            persist(now: now, force: false)
        }
    }

    func flush(force: Bool = false) {
        let now = now()
        if force {
            persistenceQueue.sync { persist(now: now, force: true) }
        } else {
            persistenceQueue.async { [self] in persist(now: now, force: false) }
        }
    }

    private func persist(now: Date, force: Bool) {
        guard force || now.timeIntervalSince(lastFlush) > 20 else { return }
        let recorded = pending
        guard !recorded.isEmpty else { return }
        lastFlush = now
        pending.removeAll(keepingCapacity: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = "stats." + formatter.string(from: now)
        var day = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        for (counter, count) in recorded {
            day[counter, default: 0] += count
        }
        defaults.set(day, forKey: key)
    }
}
