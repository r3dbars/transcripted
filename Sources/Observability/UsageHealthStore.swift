import Foundation

struct UsageFailure: Codable, Equatable, Identifiable {
    var id: String
    var kind: String
    var stage: String
    var time: Date
    var version: String
}

struct UsageDay: Codable, Equatable {
    var day: String
    var startedAt: Date
    var meetingsStarted = 0
    var meetingsCompleted = 0
    // Aggregate rounded minutes only; no per-recording duration or content is retained.
    var meetingMinutes = 0
    var dictationsCompleted = 0
    var dictationDurationCounts: [String: Int] = [:]
    var failuresByKind: [String: Int] = [:]
    var captureQualityCounts: [String: Int] = [:]
    var seenOutcomes: [String] = []
    var digestID = UUID().uuidString
    var digestEnqueued = false
}

struct UsageHealthSnapshot: Equatable {
    var meetings = 0
    var dictations = 0
    var meetingMinutesBucket = "0"
    var qualityCounts: [String: Int] = [:]
    var failures: [UsageFailure] = []
}

/// Bounded metadata ledger, populated from event enums only. Never scans a capture or a log.
final class UsageHealthStore {
    static let shared = UsageHealthStore()
    static let didChange = Notification.Name("TranscriptedUsageHealthDidChange")
    static let storageKey = "observability-usage-health-v1"
    static let durationBuckets = ["lt_10s", "10_29s", "30_119s", "2_9m", "10_29m", "30m_plus"]
    private struct State: Codable {
        var days: [UsageDay] = []
        var failures: [UsageFailure] = []
    }
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var state: State

    init(userDefaults: UserDefaults = .standard) {
        defaults = userDefaults
        state = userDefaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    func clear() {
        lock.lock()
        state = State()
        defaults.removeObject(forKey: Self.storageKey)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    func record(event: String, properties: [String: String], durationSeconds: Double? = nil,
                now: Date = Date(), calendar: Calendar = .current) {
        let relevant = ["meeting_recording_started", "meeting_transcript_saved", "meeting_recording_stopped",
                        "dictation_completed", "meeting_capture_health_snapshot", "reliability_failure_observed"].contains(event)
            || event.hasSuffix("_failed")
        guard relevant else { return }
        lock.lock()
        defer {
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
        guard AnalyticsPreferences.isEnabled(userDefaults: defaults) else { return }
        prune(now: now, calendar: calendar)
        let key = Self.dayKey(now, calendar: calendar)
        if !state.days.contains(where: { $0.day == key }) {
            state.days.append(UsageDay(day: key, startedAt: calendar.startOfDay(for: now)))
        }
        let index = state.days.firstIndex(where: { $0.day == key })!
        var day = state.days[index]
        let isFailure = event.hasSuffix("_failed") || event == "reliability_failure_observed"
        let kind = TelemetryContext.category(properties["failure_kind"]) ?? "unknown"
        let correlation = TelemetryContext.uuid(properties["correlation_id"]) ?? UUID().uuidString
        let outcomeKey = correlation + ":" + (isFailure ? "failure:" + kind : event)
        guard !day.seenOutcomes.contains(outcomeKey) else { return }
        day.seenOutcomes.append(outcomeKey)
        day.seenOutcomes = Array(day.seenOutcomes.suffix(2_000))
        switch event {
        case "meeting_recording_started": day.meetingsStarted += 1
        case "meeting_transcript_saved": day.meetingsCompleted += 1
        case "meeting_recording_stopped":
            if let seconds = durationSeconds, seconds.isFinite, seconds > 0 {
                day.meetingMinutes += Int(min(seconds / 60, 24 * 60).rounded())
            }
        case "dictation_completed":
            day.dictationsCompleted += 1
            if let bucket = properties["duration_bucket"], Self.durationBuckets.contains(bucket) {
                day.dictationDurationCounts[bucket, default: 0] += 1
            }
        case "meeting_capture_health_snapshot":
            let outcome = properties["capture_outcome"] ?? "unknown"
            if outcome != "cancelled" {
                let quality: String
                if ["no_audio", "timed_out", "stop_timed_out", "failed"].contains(outcome) { quality = "failed" }
                else if ["degraded", "fair"].contains(properties["capture_quality"] ?? "") { quality = "degraded" }
                else if ["excellent", "good"].contains(properties["capture_quality"] ?? "") { quality = "good" }
                else { quality = "unknown" }
                day.captureQualityCounts[quality, default: 0] += 1
            }
        default: break
        }
        if isFailure {
            day.failuresByKind[kind, default: 0] += 1
            state.failures.append(UsageFailure(id: outcomeKey, kind: kind,
                stage: TelemetryContext.category(properties["failure_stage"]) ?? "unknown", time: now,
                version: TelemetryContext.category(properties["app_version"]) ?? "unknown"))
            state.failures = Array(state.failures.suffix(3))
        }
        state.days[index] = day
        persist()
    }

    func snapshot(now: Date = Date(), calendar: Calendar = .current) -> UsageHealthSnapshot {
        lock.lock()
        defer { lock.unlock() }
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let days = state.days.filter { week?.contains($0.startedAt) == true }
        var snapshot = UsageHealthSnapshot()
        snapshot.meetings = days.reduce(0) { $0 + $1.meetingsCompleted }
        snapshot.dictations = days.reduce(0) { $0 + $1.dictationsCompleted }
        snapshot.meetingMinutesBucket = Self.minutesBucket(days.reduce(0) { $0 + $1.meetingMinutes })
        for day in days {
            for (key, count) in day.captureQualityCounts { snapshot.qualityCounts[key, default: 0] += count }
        }
        snapshot.failures = Array(state.failures.reversed())
        return snapshot
    }

    static func minutesBucket(_ minutes: Int) -> String {
        switch minutes {
        case ..<1: return "0"
        case ..<15: return "1_14m"
        case ..<60: return "15_59m"
        case ..<180: return "1_2h"
        case ..<600: return "3_9h"
        default: return "10h_plus"
        }
    }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
    }

    private func prune(now: Date, calendar: Calendar) {
        let oldest = calendar.date(byAdding: .day, value: -14, to: now) ?? now
        state.days.removeAll { $0.startedAt < oldest }
        state.days = Array(state.days.sorted { $0.startedAt < $1.startedAt }.suffix(14))
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.storageKey) }
    }
}
