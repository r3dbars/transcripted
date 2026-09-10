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

struct UsageDigest: Equatable {
    var id: String
    var day: String
    var properties: [String: String]
    var aggregates: [String: [String: String]]
}
