import Foundation

public struct PersonalNextWordOutcomeCells: Codable, Equatable, Sendable {
    public private(set) var baselineSilentCandidateSilent: Int
    public private(set) var baselineSilentCandidateCorrect: Int
    public private(set) var baselineSilentCandidateWrong: Int
    public private(set) var baselineCorrectCandidateSilent: Int
    public private(set) var baselineCorrectCandidateCorrect: Int
    public private(set) var baselineCorrectCandidateWrong: Int
    public private(set) var baselineWrongCandidateSilent: Int
    public private(set) var baselineWrongCandidateCorrect: Int
    public private(set) var baselineWrongCandidateWrong: Int

    init(
        baselineSilentCandidateSilent: Int = 0,
        baselineSilentCandidateCorrect: Int = 0,
        baselineSilentCandidateWrong: Int = 0,
        baselineCorrectCandidateSilent: Int = 0,
        baselineCorrectCandidateCorrect: Int = 0,
        baselineCorrectCandidateWrong: Int = 0,
        baselineWrongCandidateSilent: Int = 0,
        baselineWrongCandidateCorrect: Int = 0,
        baselineWrongCandidateWrong: Int = 0
    ) {
        self.baselineSilentCandidateSilent = baselineSilentCandidateSilent
        self.baselineSilentCandidateCorrect = baselineSilentCandidateCorrect
        self.baselineSilentCandidateWrong = baselineSilentCandidateWrong
        self.baselineCorrectCandidateSilent = baselineCorrectCandidateSilent
        self.baselineCorrectCandidateCorrect = baselineCorrectCandidateCorrect
        self.baselineCorrectCandidateWrong = baselineCorrectCandidateWrong
        self.baselineWrongCandidateSilent = baselineWrongCandidateSilent
        self.baselineWrongCandidateCorrect = baselineWrongCandidateCorrect
        self.baselineWrongCandidateWrong = baselineWrongCandidateWrong
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var decoded: [Int] = []
        for _ in 0..<9 { decoded.append(try container.decode(Int.self)) }
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid paired outcome cells"
            )
        }
        baselineSilentCandidateSilent = decoded[0]
        baselineSilentCandidateCorrect = decoded[1]
        baselineSilentCandidateWrong = decoded[2]
        baselineCorrectCandidateSilent = decoded[3]
        baselineCorrectCandidateCorrect = decoded[4]
        baselineCorrectCandidateWrong = decoded[5]
        baselineWrongCandidateSilent = decoded[6]
        baselineWrongCandidateCorrect = decoded[7]
        baselineWrongCandidateWrong = decoded[8]
        guard isValid else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid paired outcome cells"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for value in values { try container.encode(value) }
    }

    public var opportunities: Int { values.reduce(0, Self.addingWithoutOverflow) }
    public var baselinePredictions: Int {
        baselineCorrectCandidateSilent + baselineCorrectCandidateCorrect
            + baselineCorrectCandidateWrong + baselineWrongCandidateSilent
            + baselineWrongCandidateCorrect + baselineWrongCandidateWrong
    }
    public var baselineExactHits: Int {
        baselineCorrectCandidateSilent + baselineCorrectCandidateCorrect
            + baselineCorrectCandidateWrong
    }
    public var candidatePredictions: Int {
        baselineSilentCandidateCorrect + baselineSilentCandidateWrong
            + baselineCorrectCandidateCorrect + baselineCorrectCandidateWrong
            + baselineWrongCandidateCorrect + baselineWrongCandidateWrong
    }
    public var candidateExactHits: Int {
        baselineSilentCandidateCorrect + baselineCorrectCandidateCorrect
            + baselineWrongCandidateCorrect
    }
    fileprivate var minimumPredictionDisagreements: Int {
        baselineSilentCandidateCorrect + baselineSilentCandidateWrong
            + baselineCorrectCandidateSilent + baselineCorrectCandidateWrong
            + baselineWrongCandidateSilent + baselineWrongCandidateCorrect
    }

    fileprivate var isValid: Bool { values.allSatisfy { $0 >= 0 } && sumIsRepresentable }
    fileprivate var values: [Int] {
        [
            baselineSilentCandidateSilent,
            baselineSilentCandidateCorrect,
            baselineSilentCandidateWrong,
            baselineCorrectCandidateSilent,
            baselineCorrectCandidateCorrect,
            baselineCorrectCandidateWrong,
            baselineWrongCandidateSilent,
            baselineWrongCandidateCorrect,
            baselineWrongCandidateWrong,
        ]
    }

    fileprivate mutating func record(
        baseline: PersonalNextWordShadow.PredictionOutcome,
        candidate: PersonalNextWordShadow.PredictionOutcome
    ) {
        switch (baseline, candidate) {
        case (.silent, .silent): baselineSilentCandidateSilent = incremented(baselineSilentCandidateSilent)
        case (.silent, .correct): baselineSilentCandidateCorrect = incremented(baselineSilentCandidateCorrect)
        case (.silent, .wrong): baselineSilentCandidateWrong = incremented(baselineSilentCandidateWrong)
        case (.correct, .silent): baselineCorrectCandidateSilent = incremented(baselineCorrectCandidateSilent)
        case (.correct, .correct): baselineCorrectCandidateCorrect = incremented(baselineCorrectCandidateCorrect)
        case (.correct, .wrong): baselineCorrectCandidateWrong = incremented(baselineCorrectCandidateWrong)
        case (.wrong, .silent): baselineWrongCandidateSilent = incremented(baselineWrongCandidateSilent)
        case (.wrong, .correct): baselineWrongCandidateCorrect = incremented(baselineWrongCandidateCorrect)
        case (.wrong, .wrong): baselineWrongCandidateWrong = incremented(baselineWrongCandidateWrong)
        }
    }

    private var sumIsRepresentable: Bool {
        var total = 0
        for value in values {
            let result = total.addingReportingOverflow(value)
            if result.overflow { return false }
            total = result.partialValue
        }
        return true
    }

    private func incremented(_ value: Int) -> Int {
        value < Int.max ? value + 1 : value
    }

    private static func addingWithoutOverflow(_ left: Int, _ right: Int) -> Int {
        let result = left.addingReportingOverflow(right)
        return result.overflow ? Int.max : result.partialValue
    }
}

public struct PersonalNextWordPairedAggregate: Codable, Equatable, Sendable {
    public let outcomeCells: PersonalNextWordOutcomeCells
    public let predictionDisagreements: Int

    init(
        outcomeCells: PersonalNextWordOutcomeCells = .init(),
        predictionDisagreements: Int = 0
    ) {
        self.outcomeCells = outcomeCells
        self.predictionDisagreements = predictionDisagreements
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        outcomeCells = try container.decode(PersonalNextWordOutcomeCells.self)
        predictionDisagreements = try container.decode(Int.self)
        guard container.isAtEnd, isValid else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid paired aggregate"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(outcomeCells)
        try container.encode(predictionDisagreements)
    }

    public var opportunities: Int { outcomeCells.opportunities }
    public var baselinePredictions: Int { outcomeCells.baselinePredictions }
    public var baselineExactHits: Int { outcomeCells.baselineExactHits }
    public var candidatePredictions: Int { outcomeCells.candidatePredictions }
    public var candidateExactHits: Int { outcomeCells.candidateExactHits }

    fileprivate var isValid: Bool {
        outcomeCells.isValid
            && predictionDisagreements >= 0
            && predictionDisagreements >= outcomeCells.minimumPredictionDisagreements
            && predictionDisagreements <= opportunities
    }
}

public struct PersonalNextWordDailyAggregate: Codable, Equatable, Sendable {
    /// One of the most recent 64 UTC day buckets. Lifetime totals remain in
    /// the checkpoint after an older bucket ages out.
    public let utcDayStartMilliseconds: Int64
    public let aggregate: PersonalNextWordPairedAggregate

    init(
        utcDayStartMilliseconds: Int64,
        aggregate: PersonalNextWordPairedAggregate
    ) {
        self.utcDayStartMilliseconds = utcDayStartMilliseconds
        self.aggregate = aggregate
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        utcDayStartMilliseconds = try container.decode(Int64.self)
        aggregate = try container.decode(PersonalNextWordPairedAggregate.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Invalid daily aggregate"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(utcDayStartMilliseconds)
        try container.encode(aggregate)
    }
}

public struct PersonalNextWordShadowCheckpoint: Codable, Equatable, Sendable {
    public static let version = 1

    public let v: Int
    public let baselineRecipeID: String
    public let candidateRecipeID: String
    public let evaluationStartMilliseconds: Int64
    public let totals: PersonalNextWordPairedAggregate
    public let activeDays: [PersonalNextWordDailyAggregate]
    public let everCapacityLimited: Bool

    init?(
        evaluationStartMilliseconds: Int64,
        totals: PersonalNextWordPairedAggregate,
        activeDays: [PersonalNextWordDailyAggregate],
        everCapacityLimited: Bool = false
    ) {
        self.v = Self.version
        self.baselineRecipeID = PersonalNextWordShadow.baselineRecipeID
        self.candidateRecipeID = PersonalNextWordShadow.candidateRecipeID
        self.evaluationStartMilliseconds = evaluationStartMilliseconds
        self.totals = totals
        self.activeDays = activeDays
        self.everCapacityLimited = everCapacityLimited
        guard isStructurallyValid else { return nil }
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        v = try container.decode(Int.self)
        baselineRecipeID = try container.decode(String.self)
        candidateRecipeID = try container.decode(String.self)
        evaluationStartMilliseconds = try container.decode(Int64.self)
        totals = try container.decode(PersonalNextWordPairedAggregate.self)
        activeDays = try container.decode([PersonalNextWordDailyAggregate].self)
        everCapacityLimited = try container.decode(Bool.self)
        guard container.isAtEnd, isStructurallyValid else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Invalid aggregate checkpoint")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(v)
        try container.encode(baselineRecipeID)
        try container.encode(candidateRecipeID)
        try container.encode(evaluationStartMilliseconds)
        try container.encode(totals)
        try container.encode(activeDays)
        try container.encode(everCapacityLimited)
    }

    /// Whether this structurally safe checkpoint belongs to the active paired
    /// experiment. Old experiments may decode so their aggregates can be
    /// discarded or migrated without duplicating Core's validation rules.
    public var isCompatibleWithCurrentExperiment: Bool {
        v == Self.version
            && baselineRecipeID == PersonalNextWordShadow.baselineRecipeID
            && candidateRecipeID == PersonalNextWordShadow.candidateRecipeID
            && evaluationStartMilliseconds == PersonalNextWordShadow.evaluationStartMilliseconds
    }

    fileprivate var isStructurallyValid: Bool {
        guard v > 0,
              PersonalHistoryEvent.validIdentifier(baselineRecipeID),
              PersonalHistoryEvent.validIdentifier(candidateRecipeID),
              evaluationStartMilliseconds > 0,
              totals.isValid,
              activeDays.count <= PersonalNextWordShadow.maximumActiveDays else {
            return false
        }
        var priorDay: Int64?
        var dailyCells = Array(repeating: 0, count: 9)
        var dailyDisagreements = 0
        for day in activeDays {
            guard day.utcDayStartMilliseconds >= 0,
                  day.utcDayStartMilliseconds % PersonalNextWordShadow.dayMilliseconds == 0,
                  priorDay.map({ $0 < day.utcDayStartMilliseconds }) ?? true,
                  day.aggregate.isValid,
                  day.aggregate.opportunities > 0 else { return false }
            priorDay = day.utcDayStartMilliseconds
            for (index, value) in day.aggregate.outcomeCells.values.enumerated() {
                let sum = dailyCells[index].addingReportingOverflow(value)
                guard !sum.overflow else { return false }
                dailyCells[index] = sum.partialValue
            }
            let disagreementSum = dailyDisagreements.addingReportingOverflow(
                day.aggregate.predictionDisagreements
            )
            guard !disagreementSum.overflow else { return false }
            dailyDisagreements = disagreementSum.partialValue
        }
        return zip(dailyCells, totals.outcomeCells.values).allSatisfy(<=)
            && dailyDisagreements <= totals.predictionDisagreements
    }
}

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

/// Aggregate-only result of the paired local next-word experiment.
public struct PersonalNextWordShadowSnapshot: Equatable, Sendable {
    // Candidate aliases retained for the original live shadow API.
    public let opportunities: Int
    public let predictions: Int
    public let exactHits: Int
    public let learnedContexts: Int
    public let learnedTransitions: Int
    public let capacityLimited: Bool
    public let baselinePredictions: Int
    public let baselineExactHits: Int
    public let outcomeCells: PersonalNextWordOutcomeCells
    public let predictionDisagreements: Int
    public let activeDays: Int

    init(
        opportunities: Int,
        predictions: Int,
        exactHits: Int,
        learnedContexts: Int,
        learnedTransitions: Int,
        capacityLimited: Bool,
        baselinePredictions: Int = 0,
        baselineExactHits: Int = 0,
        outcomeCells: PersonalNextWordOutcomeCells = .init(),
        predictionDisagreements: Int = 0,
        activeDays: Int = 0
    ) {
        self.opportunities = opportunities
        self.predictions = predictions
        self.exactHits = exactHits
        self.learnedContexts = learnedContexts
        self.learnedTransitions = learnedTransitions
        self.capacityLimited = capacityLimited
        self.baselinePredictions = baselinePredictions
        self.baselineExactHits = baselineExactHits
        self.outcomeCells = outcomeCells
        self.predictionDisagreements = predictionDisagreements
        self.activeDays = activeDays
    }

    public var coverage: Double {
        opportunities == 0 ? 0 : Double(predictions) / Double(opportunities)
    }
    public var precision: Double {
        predictions == 0 ? 0 : Double(exactHits) / Double(predictions)
    }
    public var baselineCoverage: Double {
        opportunities == 0 ? 0 : Double(baselinePredictions) / Double(opportunities)
    }
    public var baselinePrecision: Double {
        baselinePredictions == 0 ? 0 : Double(baselineExactHits) / Double(baselinePredictions)
    }
}

/// A single production-serving lookup result from `predictNextWord`. Not
/// part of the paired shadow experiment's scoring types above — this is the
/// read-only path the "Personal suggestions (experimental)" toggle uses.
public struct PersonalNextWordPrediction: Equatable, Sendable {
    public let word: String
    public let support: Int
    public let total: Int
}

/// One parser and count model score the conservative baseline and the candidate.
public struct PersonalNextWordShadow: Sendable {
    public static let baselineRecipeID = "r1435-live-v1"
    public static let candidateRecipeID = "r1945-live-v1"
    public static let recipeID = candidateRecipeID
    public static let evaluationStartMilliseconds: Int64 = 1_786_556_700_000

    static let maximumContexts = 8_192
    static let maximumTransitions = 32_768
    static let maximumActiveStreams = 64
    static let maximumRecentEventIDs = 2_048
    static let maximumActiveDays = 64
    static let dayMilliseconds: Int64 = 24 * 60 * 60 * 1_000
    static let maximumContextWords = 4
    static let maximumTokenCharacters = 30
    private static let minimumWinnerSupport = 2
    private static let streamGapMilliseconds: Int64 = 30 * 60 * 1_000

    fileprivate enum PredictionOutcome { case silent, correct, wrong }

    private struct StreamKey: Hashable, Sendable {
        let history: String
        let consent: String
        let session: String
        let app: String
    }
    private struct EventIdentity: Hashable, Sendable {
        let stream: StreamKey
        let event: String
    }
    private struct Predictions: Equatable, Sendable {
        var baseline: String?
        var candidate: String?
    }
    private struct StreamState: Sendable {
        var token = ""
        var tokenTooLong = false
        var censored = true
        var context: [String] = []
        var hasOpportunity = false
        var predictions = Predictions()
        var lastTimestampMilliseconds: Int64?
    }
    private struct ContextKey: Hashable, Sendable { let tokens: [String] }
    private struct TargetBag: Sendable {
        var counts: [String: Int] = [:]
        var total = 0
        var top: String?
        var runner: String?

        mutating func add(_ target: String) {
            counts[target] = incremented(counts[target, default: 0])
            total = incremented(total)
            let choices = Set([top, runner, target].compactMap { $0 })
            let ranked = choices.sorted { left, right in
                let leftCount = counts[left, default: 0]
                let rightCount = counts[right, default: 0]
                if leftCount != rightCount { return leftCount > rightCount }
                return PersonalNextWordShadow.surfacePrecedes(left, right)
            }
            top = ranked.first
            runner = ranked.dropFirst().first
        }

        var winner: (surface: String, support: Int, runner: Int, total: Int)? {
            guard let top else { return nil }
            return (top, counts[top, default: 0], runner.map { counts[$0, default: 0] } ?? 0, total)
        }

        private func incremented(_ value: Int) -> Int { value == Int.max ? value : value + 1 }
    }

    private let evaluationStart: Int64
    private var model: [ContextKey: TargetBag] = [:]
    private var transitionCount = 0
    private var streams: [StreamKey: StreamState] = [:]
    private var streamOrder: [StreamKey] = []
    private var recentEventIDs: [EventIdentity] = []
    private var recentEventIDSet: Set<EventIdentity> = []
    private var nextEventEvictionIndex = 0
    private var totals = PersonalNextWordPairedAggregate()
    private var days: [Int64: PersonalNextWordPairedAggregate] = [:]
    private var capacityLimited = false
    private var everCapacityLimited = false

    public init(evaluationStartMilliseconds: Int64 = Self.evaluationStartMilliseconds) {
        evaluationStart = max(0, evaluationStartMilliseconds)
    }

    public init?(checkpoint: PersonalNextWordShadowCheckpoint) {
        guard checkpoint.isCompatibleWithCurrentExperiment else { return nil }
        evaluationStart = checkpoint.evaluationStartMilliseconds
        totals = checkpoint.totals
        days = Dictionary(uniqueKeysWithValues: checkpoint.activeDays.map {
            ($0.utcDayStartMilliseconds, $0.aggregate)
        })
        everCapacityLimited = checkpoint.everCapacityLimited
    }

    public var checkpoint: PersonalNextWordShadowCheckpoint {
        precondition(
            evaluationStart == Self.evaluationStartMilliseconds,
            "Only the prospective production experiment can be checkpointed"
        )
        return PersonalNextWordShadowCheckpoint(
            evaluationStartMilliseconds: evaluationStart,
            totals: totals,
            activeDays: days.keys.sorted().map {
                PersonalNextWordDailyAggregate(utcDayStartMilliseconds: $0, aggregate: days[$0]!)
            },
            everCapacityLimited: everCapacityLimited || capacityLimited
        )!
    }

    /// The durable form of everything training has produced. Deterministic
    /// (contexts and transitions in a fixed order) so two shadows that would
    /// predict identically also serialize identically.
    ///
    /// `recentEvents` travels too: an append whose acknowledgement was lost
    /// is retried after a restart, and a restored table must refuse it the
    /// way a rebuild from the log would.
    public var trainedModel: PersonalNextWordTrainedModel {
        let contexts = model.keys
            .sorted { Self.tokensPrecede($0.tokens, $1.tokens) }
            .map { key -> PersonalNextWordTrainedModel.Context in
                let bag = model[key]!
                return PersonalNextWordTrainedModel.Context(
                    tokens: key.tokens,
                    transitions: bag.counts.keys
                        .sorted(by: Self.surfacePrecedes)
                        .map { .init(word: $0, count: bag.counts[$0]!) },
                    total: bag.total,
                    top: bag.top,
                    runner: bag.runner
                )
            }
        let streams = streamOrder.compactMap { key -> PersonalNextWordTrainedModel.Stream? in
            guard let state = self.streams[key] else { return nil }
            return PersonalNextWordTrainedModel.Stream(
                historyIdentifier: key.history,
                consentIdentifier: key.consent,
                sessionIdentifier: key.session,
                appBundleIdentifier: key.app,
                token: state.token,
                tokenTooLong: state.tokenTooLong,
                censored: state.censored,
                context: state.context,
                hasOpportunity: state.hasOpportunity,
                baselinePrediction: state.predictions.baseline,
                candidatePrediction: state.predictions.candidate,
                lastTimestampMilliseconds: state.lastTimestampMilliseconds
            )
        }
        return PersonalNextWordTrainedModel(
            contexts: contexts,
            streams: streams,
            transitionCount: transitionCount,
            capacityLimited: capacityLimited,
            everCapacityLimited: everCapacityLimited,
            recentEvents: recentEventsOldestFirst.map {
                PersonalNextWordTrainedModel.RecentEvent(
                    historyIdentifier: $0.stream.history,
                    consentIdentifier: $0.stream.consent,
                    sessionIdentifier: $0.stream.session,
                    appBundleIdentifier: $0.stream.app,
                    eventID: $0.event
                )
            }
        )
    }

    /// The ring in the order it would be evicted, so a restore rebuilds the
    /// same eviction sequence.
    private var recentEventsOldestFirst: [EventIdentity] {
        guard recentEventIDs.count == Self.maximumRecentEventIDs else { return recentEventIDs }
        return Array(recentEventIDs[nextEventEvictionIndex...] + recentEventIDs[..<nextEventEvictionIndex])
    }

    /// Puts a persisted table back, leaving the paired aggregate counters
    /// (which travel in `PersonalNextWordShadowCheckpoint`) untouched.
    /// Returns false — and changes nothing — for a model from another recipe
    /// or schema, so the caller falls back to rebuilding from raw history.
    @discardableResult
    public mutating func restore(_ trained: PersonalNextWordTrainedModel) -> Bool {
        guard trained.isCompatibleWithCurrentRecipe, trained.isStructurallyValid else {
            return false
        }
        var restored: [ContextKey: TargetBag] = [:]
        restored.reserveCapacity(trained.contexts.count)
        for context in trained.contexts {
            var bag = TargetBag()
            bag.counts = Dictionary(
                uniqueKeysWithValues: context.transitions.map { ($0.word, $0.count) }
            )
            bag.total = context.total
            bag.top = context.top
            bag.runner = context.runner
            restored[ContextKey(tokens: context.tokens)] = bag
        }
        model = restored
        transitionCount = trained.transitionCount
        capacityLimited = trained.capacityLimited
        everCapacityLimited = trained.everCapacityLimited
        recentEventIDs = []
        recentEventIDSet = []
        nextEventEvictionIndex = 0
        for recent in trained.recentEvents {
            let identity = EventIdentity(
                stream: StreamKey(
                    history: recent.historyIdentifier,
                    consent: recent.consentIdentifier,
                    session: recent.sessionIdentifier,
                    app: recent.appBundleIdentifier
                ),
                event: recent.eventID
            )
            guard recentEventIDSet.insert(identity).inserted else { continue }
            recentEventIDs.append(identity)
        }
        streams = [:]
        streamOrder = []
        for stream in trained.streams {
            let key = StreamKey(
                history: stream.historyIdentifier,
                consent: stream.consentIdentifier,
                session: stream.sessionIdentifier,
                app: stream.appBundleIdentifier
            )
            var state = StreamState()
            state.token = stream.token
            state.tokenTooLong = stream.tokenTooLong
            state.censored = stream.censored
            state.context = stream.context
            state.hasOpportunity = stream.hasOpportunity
            state.predictions = Predictions(
                baseline: stream.baselinePrediction,
                candidate: stream.candidatePrediction
            )
            state.lastTimestampMilliseconds = stream.lastTimestampMilliseconds
            streams[key] = state
            streamOrder.append(key)
        }
        return true
    }

    private static func tokensPrecede(_ left: [String], _ right: [String]) -> Bool {
        if left.count != right.count { return left.count < right.count }
        for (leftToken, rightToken) in zip(left, right) where leftToken != rightToken {
            return surfacePrecedes(leftToken, rightToken)
        }
        return false
    }

    public var snapshot: PersonalNextWordShadowSnapshot {
        PersonalNextWordShadowSnapshot(
            opportunities: totals.opportunities,
            predictions: totals.candidatePredictions,
            exactHits: totals.candidateExactHits,
            learnedContexts: model.count,
            learnedTransitions: transitionCount,
            capacityLimited: capacityLimited || everCapacityLimited,
            baselinePredictions: totals.baselinePredictions,
            baselineExactHits: totals.baselineExactHits,
            outcomeCells: totals.outcomeCells,
            predictionDisagreements: totals.predictionDisagreements,
            activeDays: days.count
        )
    }

    public mutating func consume(_ events: [PersonalHistoryEvent], scoring: Bool = true) {
        for event in events {
            let key = StreamKey(
                history: event.historyIdentifier,
                consent: event.consentIdentifier,
                session: event.sessionIdentifier,
                app: event.appBundleIdentifier
            )
            guard remember(event, in: key) else { continue }
            var state = takeStream(for: key)
            if let last = state.lastTimestampMilliseconds,
               event.timestampMilliseconds < last
                || event.timestampMilliseconds - last > Self.streamGapMilliseconds {
                state = StreamState()
            }
            state.lastTimestampMilliseconds = event.timestampMilliseconds

            if event.source == .acceptedSuggestion {
                censorAcceptedText(event.text, state: &state)
            } else {
                for scalar in event.text.precomposedStringWithCanonicalMapping.unicodeScalars {
                    consumeTyped(
                        scalar,
                        timestampMilliseconds: event.timestampMilliseconds,
                        scoring: scoring,
                        state: &state
                    )
                }
            }
            streams[key] = state
        }
    }

    public mutating func reset() { self = Self(evaluationStartMilliseconds: evaluationStart) }

    private mutating func takeStream(for key: StreamKey) -> StreamState {
        if let state = streams.removeValue(forKey: key) { return state }
        if streams.count >= Self.maximumActiveStreams, let oldest = streamOrder.first {
            streamOrder.removeFirst()
            streams.removeValue(forKey: oldest)
        }
        streamOrder.append(key)
        return StreamState()
    }

    private mutating func consumeTyped(
        _ scalar: Unicode.Scalar,
        timestampMilliseconds: Int64,
        scoring: Bool,
        state: inout StreamState
    ) {
        if Self.isLetter(scalar) {
            guard !state.censored, !state.tokenTooLong else { return }
            state.token.unicodeScalars.append(scalar)
            if state.token.unicodeScalars.count > Self.maximumTokenCharacters {
                state.token.removeAll(keepingCapacity: false)
                state.tokenTooLong = true
            }
            return
        }
        if Self.isMark(scalar), !state.censored, !state.tokenTooLong, !state.token.isEmpty {
            let combined = Self.surface(state.token + String(scalar))
            if combined.unicodeScalars.allSatisfy(Self.isLetter) {
                state.token = combined
                return
            }
        }
        if state.censored {
            state.censored = false
            state.token.removeAll(keepingCapacity: true)
            state.tokenTooLong = false
            return
        }
        finishToken(
            timestampMilliseconds: timestampMilliseconds,
            scoring: scoring,
            state: &state
        )
    }

    private mutating func finishToken(
        timestampMilliseconds: Int64,
        scoring: Bool,
        state: inout StreamState
    ) {
        defer {
            state.token.removeAll(keepingCapacity: true)
            state.tokenTooLong = false
        }
        guard !state.tokenTooLong, !state.token.isEmpty else { return }
        let target = Self.surface(state.token)
        guard (1...Self.maximumTokenCharacters).contains(target.unicodeScalars.count) else { return }

        if scoring, state.hasOpportunity, timestampMilliseconds >= evaluationStart {
            record(predictions: state.predictions, target: target, at: timestampMilliseconds)
        }
        learn(target, after: state.context)
        state.context.append(Self.folded(target))
        if state.context.count > Self.maximumContextWords {
            state.context.removeFirst(state.context.count - Self.maximumContextWords)
        }
        state.hasOpportunity = true
        state.predictions = Predictions(
            baseline: candidate(after: state.context, maximumContext: 2, minimumRatio: 2),
            candidate: candidate(after: state.context, maximumContext: 4, minimumRatio: 1)
        )
    }

    private mutating func record(predictions: Predictions, target: String, at timestamp: Int64) {
        let baseline = Self.outcome(predictions.baseline, target: target)
        let candidate = Self.outcome(predictions.candidate, target: target)
        let disagreed = predictions.baseline != predictions.candidate
        var totalCells = totals.outcomeCells
        totalCells.record(baseline: baseline, candidate: candidate)
        totals = PersonalNextWordPairedAggregate(
            outcomeCells: totalCells,
            predictionDisagreements: Self.incremented(totals.predictionDisagreements, if: disagreed)
        )

        let day = timestamp / Self.dayMilliseconds * Self.dayMilliseconds
        var daily = days[day] ?? PersonalNextWordPairedAggregate()
        var dailyCells = daily.outcomeCells
        dailyCells.record(baseline: baseline, candidate: candidate)
        daily = PersonalNextWordPairedAggregate(
            outcomeCells: dailyCells,
            predictionDisagreements: Self.incremented(daily.predictionDisagreements, if: disagreed)
        )
        days[day] = daily
        if days.count > Self.maximumActiveDays, let oldest = days.keys.min() {
            days.removeValue(forKey: oldest)
        }
    }

    private mutating func censorAcceptedText(_ text: String, state: inout StreamState) {
        state.token.removeAll(keepingCapacity: false)
        state.tokenTooLong = false
        state.context.removeAll(keepingCapacity: false)
        state.hasOpportunity = false
        state.predictions = Predictions()
        state.censored = true
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            state.censored = Self.isLetter(scalar)
        }
    }

    private func candidate(
        after history: [String],
        maximumContext: Int,
        minimumRatio: Int
    ) -> String? {
        Self.winningPrediction(
            in: model,
            after: history,
            maximumContext: maximumContext,
            minimumRatio: minimumRatio
        )?.word
    }

    /// Read-only production lookup for experimental personal-word serving
    /// (`docs/plans/road-to-paid.md` Phase 3, the "Personal suggestions
    /// (experimental)" menu toggle). Deliberately reuses the shadow
    /// experiment's own conservative "baseline" recipe parameters
    /// (`baselineRecipeID`'s 2-word context, 2x-support-over-runner-up
    /// ratio) rather than the looser candidate recipe still under live A/B
    /// test — serving a real suggestion should never lean on a threshold
    /// that hasn't itself been vetted as a safe production bar. Purely a
    /// lookup over `model`: no mutation, no interaction with `consume`'s
    /// paired scoring, callable any number of times with no side effects.
    /// Splits `text` into the same letter-run tokens `consume` extracts one
    /// keystroke at a time while training the model: a run of Unicode
    /// letters is one token (a combining mark only extends it when the
    /// combination stays all-letters, matching `consumeTyped`'s rule), and
    /// everything else — whitespace, punctuation, apostrophes, hyphens,
    /// digits — is a separator. Serving must tokenize context with this
    /// exact rule, not a looser one: "don't" was learned as two
    /// transitions, `["don", "t"]`, never as one token `["don't"]`.
    public static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var token = ""
        for scalar in text.precomposedStringWithCanonicalMapping.unicodeScalars {
            if isLetter(scalar) {
                token.unicodeScalars.append(scalar)
                continue
            }
            if isMark(scalar), !token.isEmpty {
                let combined = surface(token + String(scalar))
                if combined.unicodeScalars.allSatisfy(isLetter) {
                    token = combined
                    continue
                }
            }
            if !token.isEmpty {
                tokens.append(surface(token))
                token = ""
            }
        }
        if !token.isEmpty { tokens.append(surface(token)) }
        return tokens
    }

    /// English contraction remainders the letter-run tokenizer produces
    /// when it splits on the apostrophe ("I'll" -> `["i", "ll"]`, "don't"
    /// -> `["don", "t"]`). These are real transitions the model needs for
    /// context, but never a legitimate whole next word on their own —
    /// serving one verbatim glues onto whatever the user is mid-typing
    /// next ("I think I " -> "ll").
    private static let contractionFragments: Set<String> = ["t", "s", "d", "m", "ll", "re", "ve"]

    public func predictNextWord(afterTailWords tailWords: [String]) -> PersonalNextWordPrediction? {
        let folded = tailWords.suffix(Self.maximumContextWords).map(Self.folded)
        guard let prediction = Self.winningPrediction(
            in: model,
            after: Array(folded),
            maximumContext: 2,
            minimumRatio: 2,
            // Never fall all the way back to the empty-context global
            // unigram bag for a served suggestion — a single globally
            // dominant word (e.g. a name typed constantly) would otherwise
            // surface in totally unrelated contexts. The shadow's own A/B
            // recipe evaluation below still backs off to order 0 by
            // default; this bound only tightens what's actually served.
            minimumOrder: 1
        ) else { return nil }
        guard !Self.contractionFragments.contains(Self.folded(prediction.word)) else { return nil }
        return prediction
    }

    private static func winningPrediction(
        in model: [ContextKey: TargetBag],
        after history: [String],
        maximumContext: Int,
        minimumRatio: Int,
        minimumOrder: Int = 0
    ) -> PersonalNextWordPrediction? {
        let maximum = min(maximumContext, history.count)
        guard maximum >= minimumOrder else { return nil }
        for order in stride(from: maximum, through: minimumOrder, by: -1) {
            guard let winner = model[Self.contextKey(order: order, history: history)]?.winner else {
                continue
            }
            let requiredShare = winner.total / 2 + winner.total % 2
            let meetsRatio = minimumRatio == 1
                || winner.runner == 0
                || winner.runner <= winner.support / minimumRatio
            if winner.support >= Self.minimumWinnerSupport,
               winner.support >= requiredShare,
               meetsRatio {
                return PersonalNextWordPrediction(word: winner.surface, support: winner.support, total: winner.total)
            }
        }
        return nil
    }

    private mutating func learn(_ target: String, after history: [String]) {
        guard !capacityLimited else { return }
        let maximum = min(Self.maximumContextWords, history.count)
        let keys = (0...maximum).map { Self.contextKey(order: $0, history: history) }
        let addedContexts = keys.reduce(into: 0) { if model[$1] == nil { $0 += 1 } }
        let addedTransitions = keys.reduce(into: 0) { if model[$1]?.counts[target] == nil { $0 += 1 } }
        guard model.count <= Self.maximumContexts - addedContexts,
              transitionCount <= Self.maximumTransitions - addedTransitions else {
            capacityLimited = true
            everCapacityLimited = true
            return
        }
        for key in keys {
            let isNewTransition = model[key]?.counts[target] == nil
            model[key, default: TargetBag()].add(target)
            if isNewTransition { transitionCount += 1 }
        }
    }

    private mutating func remember(_ event: PersonalHistoryEvent, in stream: StreamKey) -> Bool {
        let identity = EventIdentity(stream: stream, event: event.id)
        guard recentEventIDSet.insert(identity).inserted else { return false }
        if recentEventIDs.count < Self.maximumRecentEventIDs {
            recentEventIDs.append(identity)
        } else {
            recentEventIDSet.remove(recentEventIDs[nextEventEvictionIndex])
            recentEventIDs[nextEventEvictionIndex] = identity
            nextEventEvictionIndex = (nextEventEvictionIndex + 1) % Self.maximumRecentEventIDs
        }
        return true
    }

    private static func outcome(_ prediction: String?, target: String) -> PredictionOutcome {
        guard let prediction else { return .silent }
        return prediction == target ? .correct : .wrong
    }
    private static func incremented(_ value: Int, if condition: Bool) -> Int {
        condition && value < Int.max ? value + 1 : value
    }
    private static func contextKey(order: Int, history: [String]) -> ContextKey {
        ContextKey(tokens: order == 0 ? [] : Array(history.suffix(order)))
    }
    private static func folded(_ token: String) -> String {
        surface(token).folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }
    private static func surface(_ token: String) -> String {
        token.precomposedStringWithCanonicalMapping
    }
    private static func surfacePrecedes(_ left: String, _ right: String) -> Bool {
        var leftScalars = left.unicodeScalars.makeIterator()
        var rightScalars = right.unicodeScalars.makeIterator()
        while let leftScalar = leftScalars.next() {
            guard let rightScalar = rightScalars.next() else { return false }
            if leftScalar.value != rightScalar.value { return leftScalar.value < rightScalar.value }
        }
        return rightScalars.next() != nil
    }
    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            true
        default: false
        }
    }
    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }
}
