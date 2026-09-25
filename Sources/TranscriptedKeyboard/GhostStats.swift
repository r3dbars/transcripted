#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Aggregate-only keyboard counters. Personal History is a separate, explicit subsystem.
enum GhostStats {
    private static let persistenceQueue = DispatchQueue(label: "com.justinbetker.draft.keyboard.ghost-stats", qos: .utility)
    private static var pending = [String: Int]()
    private static var lastFlush = Date.distantPast

    static func recordAccepted(_ text: String) {
        let count = text.split(whereSeparator: \Character.isWhitespace).count
        guard count > 0 else { return }
        record(count, key: "wordsAccepted")
    }

    static func recordSuggestionShown() {
        record(1, key: "suggestionsShown")
    }

    static func recordSuggestionAccepted() {
        record(1, key: "suggestionsAccepted")
    }

    static func recordFailure(_ outcome: GhostBrainResponse.Outcome) {
        let key: String
        switch outcome {
        case .error: key = "completionErrors"
        case .timeout: key = "completionTimeouts"
        case .invalidRequest, .unsupported: key = "completionInvalidRequests"
        case .suggestion, .silence, .unavailable, .recorded: return
        }
        record(1, key: key)
    }

    private static func record(_ count: Int, key: String) {
        let now = Date()
        persistenceQueue.async {
            pending[key, default: 0] += count
            persist(now: now, force: false)
        }
    }

    static func flush(force: Bool = false) {
        let now = Date()
        if force {
            persistenceQueue.sync { persist(now: now, force: true) }
        } else {
            persistenceQueue.async { persist(now: now, force: false) }
        }
    }

    private static func persist(now: Date, force: Bool) {
        guard force || now.timeIntervalSince(lastFlush) > 20 else { return }
        let recorded = pending
        guard !recorded.isEmpty else { return }
        lastFlush = now
        pending.removeAll(keepingCapacity: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let key = "stats." + formatter.string(from: now)
        let defaults = UserDefaults.standard
        var day = defaults.dictionary(forKey: key) as? [String: Int] ?? [:]
        for (counter, count) in recorded {
            day[counter, default: 0] += count
        }
        defaults.set(day, forKey: key)
    }
}
