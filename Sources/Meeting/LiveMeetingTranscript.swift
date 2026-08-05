import Foundation

enum LiveMeetingTranscriptSource: String, Codable, Equatable {
    case microphone
    case system

    var displayName: String {
        switch self {
        case .microphone:
            return "Microphone"
        case .system:
            return "System audio"
        }
    }
}

struct LiveMeetingTranscriptEntry: Codable, Equatable {
    let source: LiveMeetingTranscriptSource
    let text: String
    let timestampSeconds: TimeInterval
    let createdAt: Date
    let isFinal: Bool

    init(
        source: LiveMeetingTranscriptSource,
        text: String,
        timestampSeconds: TimeInterval,
        createdAt: Date = Date(),
        isFinal: Bool = true
    ) {
        self.source = source
        self.text = text
        self.timestampSeconds = timestampSeconds
        self.createdAt = createdAt
        self.isFinal = isFinal
    }
}
