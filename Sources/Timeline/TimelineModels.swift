import Foundation

struct TimelineScreenshot: Equatable, Identifiable {
    let id: Int64
    let capturedAt: Date
    let idleSecondsAtCapture: TimeInterval
    let appBundleID: String?
    let appName: String?
    let windowTitle: String?

    init(
        id: Int64,
        capturedAt: Date,
        idleSecondsAtCapture: TimeInterval = 0,
        appBundleID: String? = nil,
        appName: String? = nil,
        windowTitle: String? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.idleSecondsAtCapture = idleSecondsAtCapture
        self.appBundleID = appBundleID
        self.appName = appName
        self.windowTitle = windowTitle
    }
}

struct TimelineObservationSegment: Equatable, Codable {
    var startTs: Date
    var endTs: Date
    var observation: String
    var appName: String?
    var windowTitle: String?
}

enum TimelineCardKind: String, Codable, Equatable {
    case activity
    case idle
    case meeting
    case dictation
}

struct ActivityCardData: Equatable, Codable, Identifiable {
    var id: String
    var startTs: Date
    var endTs: Date
    var kind: TimelineCardKind
    var title: String
    var summary: String
    var detailedSummary: String?
    var category: String
    var subcategory: String?

    init(
        id: String = UUID().uuidString,
        startTs: Date,
        endTs: Date,
        kind: TimelineCardKind = .activity,
        title: String,
        summary: String,
        detailedSummary: String? = nil,
        category: String,
        subcategory: String? = nil
    ) {
        self.id = id
        self.startTs = startTs
        self.endTs = endTs
        self.kind = kind
        self.title = title
        self.summary = summary
        self.detailedSummary = detailedSummary
        self.category = category
        self.subcategory = subcategory
    }

    var duration: TimeInterval {
        max(0, endTs.timeIntervalSince(startTs))
    }
}

struct TimelineCategoryDescriptor: Equatable, Codable {
    var id: String
    var name: String
    var colorHex: String
    var details: String
    var order: Int
    var isSystem: Bool
    var isIdle: Bool
}

struct TimelineCardGenerationContext: Equatable {
    var windowStart: Date
    var windowEnd: Date
    var existingCards: [ActivityCardData]
    var fixedCards: [ActivityCardData]
    var categories: [TimelineCategoryDescriptor]
}

enum TimelineProviderType: String, Equatable, Codable {
    case localFoundation
    case ollama
    case gemini
    case mock
}

enum TimelineAnalysisFailureKind: String, Equatable {
    case unavailable
    case rateLimited
    case invalidResponse
    case unknown
}

struct TimelineAnalysisFailure: Error, Equatable {
    var kind: TimelineAnalysisFailureKind
    var reason: String
}
