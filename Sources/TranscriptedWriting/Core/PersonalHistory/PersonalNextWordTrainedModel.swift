import Foundation

/// The trained next-word model itself: the context→target count table the
/// serving lookup reads, plus the per-stream parser state that decides how the
/// next keystroke extends it.
///
/// Until this existed, only `PersonalNextWordShadowCheckpoint`'s paired
/// aggregate counters were durable, and the table was rebuilt on every launch
/// from a bounded tail of raw history — so everything learned beyond that tail
/// quietly disappeared. Persisting it is only safe if a restore is
/// indistinguishable from that rebuild, which is why the streams travel with
/// the table: a restart in the middle of a sentence must not reset the context
/// words, the half-typed token, or the censoring state.
///
/// It carries writing (learned words and the words being typed) and so is only
/// ever written to the same owner-only encrypted store as the history log, and
/// never to a log, diagnostic, or report.
public struct PersonalNextWordTrainedModel: Codable, Equatable, Sendable {
    /// 2: the bounded duplicate-event guard travels with the table, so a
    /// retried append after a restart is skipped exactly as a rebuild would
    /// skip it. A version-1 file is refused and rebuilt from history.
    public static let version = 2

    /// One consumed event, as the shadow remembers it to refuse a repeat.
    public struct RecentEvent: Codable, Equatable, Sendable {
        public let historyIdentifier: String
        public let consentIdentifier: String
        public let sessionIdentifier: String
        public let appBundleIdentifier: String
        public let eventID: String
    }

    public struct Transition: Codable, Equatable, Sendable {
        public let word: String
        public let count: Int
    }

    public struct Context: Codable, Equatable, Sendable {
        public let tokens: [String]
        public let transitions: [Transition]
        public let total: Int
        public let top: String?
        public let runner: String?
    }

    public struct Stream: Codable, Equatable, Sendable {
        public let historyIdentifier: String
        public let consentIdentifier: String
        public let sessionIdentifier: String
        public let appBundleIdentifier: String
        public let token: String
        public let tokenTooLong: Bool
        public let censored: Bool
        public let context: [String]
        public let hasOpportunity: Bool
        public let baselinePrediction: String?
        public let candidatePrediction: String?
        public let lastTimestampMilliseconds: Int64?
    }

    public let v: Int
    /// The learning recipe the table was built with. A recipe change means the
    /// counts no longer mean what a restore would assume, so the model is
    /// discarded and rebuilt rather than misread.
    public let recipeID: String
    public let contexts: [Context]
    public let streams: [Stream]
    public let transitionCount: Int
    public let capacityLimited: Bool
    public let everCapacityLimited: Bool
    /// The in-session duplicate guard, oldest first, bounded by
    /// `PersonalNextWordShadow.maximumRecentEventIDs`.
    public let recentEvents: [RecentEvent]

    init(
        contexts: [Context],
        streams: [Stream],
        transitionCount: Int,
        capacityLimited: Bool,
        everCapacityLimited: Bool,
        recentEvents: [RecentEvent] = []
    ) {
        v = Self.version
        recipeID = PersonalNextWordShadow.recipeID
        self.contexts = contexts
        self.streams = streams
        self.transitionCount = transitionCount
        self.capacityLimited = capacityLimited
        self.everCapacityLimited = everCapacityLimited
        self.recentEvents = recentEvents
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        v = try container.decode(Int.self)
        recipeID = try container.decode(String.self)
        contexts = try container.decode([Context].self)
        streams = try container.decode([Stream].self)
        transitionCount = try container.decode(Int.self)
        capacityLimited = try container.decode(Bool.self)
        everCapacityLimited = try container.decode(Bool.self)
        recentEvents = try container.decode([RecentEvent].self)
        guard container.isAtEnd, isStructurallyValid else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid trained model")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(v)
        try container.encode(recipeID)
        try container.encode(contexts)
        try container.encode(streams)
        try container.encode(transitionCount)
        try container.encode(capacityLimited)
        try container.encode(everCapacityLimited)
        try container.encode(recentEvents)
    }

    /// A schema or recipe change rebuilds instead of misreading a table whose
    /// counts were produced by different rules.
    public var isCompatibleWithCurrentRecipe: Bool {
        v == Self.version && recipeID == PersonalNextWordShadow.recipeID
    }

    var isStructurallyValid: Bool {
        guard v > 0,
              PersonalHistoryEvent.validIdentifier(recipeID),
              transitionCount >= 0,
              transitionCount <= PersonalNextWordShadow.maximumTransitions,
              contexts.count <= PersonalNextWordShadow.maximumContexts,
              streams.count <= PersonalNextWordShadow.maximumActiveStreams,
              recentEvents.count <= PersonalNextWordShadow.maximumRecentEventIDs else { return false }
        var contextKeys = Set<[String]>()
        var transitions = 0
        for context in contexts {
            guard context.tokens.count <= PersonalNextWordShadow.maximumContextWords,
                  context.tokens.allSatisfy(Self.isValidToken),
                  contextKeys.insert(context.tokens).inserted,
                  !context.transitions.isEmpty,
                  context.total >= 0 else { return false }
            var words = Set<String>()
            var largest = 0
            for transition in context.transitions {
                guard transition.count > 0,
                      Self.isValidToken(transition.word),
                      words.insert(transition.word).inserted else { return false }
                largest = max(largest, transition.count)
            }
            guard context.total >= largest else { return false }
            // Transitions are non-empty above, so a top word always exists.
            guard let top = context.top, words.contains(top),
                  context.runner.map({ words.contains($0) && $0 != top }) ?? true else { return false }
            transitions += context.transitions.count
            guard transitions <= PersonalNextWordShadow.maximumTransitions else { return false }
        }
        guard transitions == transitionCount else { return false }
        var streamKeys = Set<[String]>()
        for stream in streams {
            guard PersonalHistoryEvent.validIdentifier(stream.historyIdentifier),
                  PersonalHistoryEvent.validIdentifier(stream.consentIdentifier),
                  PersonalHistoryEvent.validIdentifier(stream.sessionIdentifier),
                  PersonalHistoryEvent.validBundleIdentifier(stream.appBundleIdentifier),
                  streamKeys.insert([
                      stream.historyIdentifier, stream.consentIdentifier,
                      stream.sessionIdentifier, stream.appBundleIdentifier,
                  ]).inserted,
                  stream.token.unicodeScalars.count <= PersonalNextWordShadow.maximumTokenCharacters,
                  stream.context.count <= PersonalNextWordShadow.maximumContextWords,
                  stream.context.allSatisfy(Self.isValidToken),
                  stream.baselinePrediction.map(Self.isValidToken) ?? true,
                  stream.candidatePrediction.map(Self.isValidToken) ?? true,
                  stream.lastTimestampMilliseconds.map({ $0 >= 0 }) ?? true else { return false }
        }
        return true
    }

    private static func isValidToken(_ token: String) -> Bool {
        !token.isEmpty
            && token.unicodeScalars.count <= PersonalNextWordShadow.maximumTokenCharacters
    }
}
