import Foundation

/// What the call app (Zoom, Meet, Teams, Slack) showed about who was talking
/// during one recording, read over Accessibility by the app side and handed
/// to the pipeline after Stop. Times are seconds from the start of the
/// recording, the same base as the system track's utterance times.
///
/// Participant names are user content: they stay on this Mac, in memory and
/// in the saved meeting. Never log, report or send them.
public struct CallSpeakerActivity: Sendable, Codable, Equatable {
    /// One participant's tile showed them as speaking from `start` to `end`.
    public struct Interval: Sendable, Codable, Equatable {
        public let name: String
        public let start: Double
        public let end: Double

        public init(name: String, start: Double, end: Double) {
            self.name = name
            self.start = start
            self.end = end
        }
    }

    /// A span where the reader had a trustworthy read of a meeting window
    /// with a speaking indicator. Outside these spans there is no evidence
    /// either way (no window, windows disagreed, read failed).
    public struct Span: Sendable, Codable, Equatable {
        public let start: Double
        public let end: Double

        public init(start: Double, end: Double) {
            self.start = start
            self.end = end
        }
    }

    public var intervals: [Interval]
    public var coverage: [Span]
    /// Observed participant names after known self names are excluded. This
    /// can be a partial roster and does not establish identity or who spoke.
    public var rosterNames: [String]
    /// Names the call app marked as the local user ("You", "(me)").
    public var selfNames: Set<String>
    /// True once any read found a speaking indicator (not just a roster).
    public var sawSpeakingIndicator: Bool

    public init(
        intervals: [Interval] = [],
        coverage: [Span] = [],
        rosterNames: [String] = [],
        selfNames: Set<String> = [],
        sawSpeakingIndicator: Bool = false
    ) {
        self.intervals = intervals
        self.coverage = coverage
        self.rosterNames = rosterNames
        self.selfNames = selfNames
        self.sawSpeakingIndicator = sawSpeakingIndicator
    }

    public var isEmpty: Bool { intervals.isEmpty && rosterNames.isEmpty }
}
