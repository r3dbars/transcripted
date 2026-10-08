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

    mutating func record(
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
