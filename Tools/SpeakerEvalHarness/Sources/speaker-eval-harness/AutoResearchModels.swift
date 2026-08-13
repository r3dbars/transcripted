import Foundation
import TranscriptedCore


// MARK: - Frozen fingerprint input

struct FingerprintSpeaker: Codable {
    let gtSpeaker: String
    let embedding: [Float]
    let durationSeconds: Double
    let segmentCount: Int
    let clusterCount: Int
    let purity: Double
}

struct FingerprintMeeting: Codable {
    let meeting: String
    let order: Int
    let speakers: [FingerprintSpeaker]
}

struct FingerprintCache: Codable {
    let corpus: String
    let meetings: [FingerprintMeeting]
}

enum ResearchSplit: String, Codable, CaseIterable {
    case train
    case dev
    case holdout
    case all
}

/// Fixed, exhaustive buckets used as promotion guardrails. Each observation
/// belongs to one bucket per dimension, so aggregate improvements cannot hide
/// a regression on weak audio, short turns, sparse evidence, or fragmented
/// diarization.
enum ResearchConditionSlice: String, CaseIterable {
    case lowPurity = "condition/purity/low"
    case scorablePurity = "condition/purity/scorable"
    case shortSpeech = "condition/speech/under-4s"
    case sustainedSpeech = "condition/speech/4s-plus"
    case sparseSegments = "condition/segments/under-3"
    case denseSegments = "condition/segments/3-plus"
    case singleCluster = "condition/clusters/single"
    case multipleClusters = "condition/clusters/multiple"

    func contains(_ speaker: FingerprintSpeaker) -> Bool {
        switch self {
        case .lowPurity:
            speaker.purity < ResearchConstants.scoringPurityFloor
        case .scorablePurity:
            speaker.purity >= ResearchConstants.scoringPurityFloor
        case .shortSpeech:
            speaker.durationSeconds < 4
        case .sustainedSpeech:
            speaker.durationSeconds >= 4
        case .sparseSegments:
            speaker.segmentCount < 3
        case .denseSegments:
            speaker.segmentCount >= 3
        case .singleCluster:
            speaker.clusterCount <= 1
        case .multipleClusters:
            speaker.clusterCount > 1
        }
    }
}

enum MaturityEvidence: String, Codable {
    case appearances
    case confirmedMeetings = "confirmed_meetings"
}

enum WriteBackEvidence: String, Codable {
    /// Current production behavior: every accepted DB match records an appearance and may blend.
    case production
    /// Defer suggest-path blending until the user confirms it; auto-name still adapts.
    case confirmedOrAuto = "confirmed_or_auto"
    /// Only an explicit user confirmation may change the voiceprint.
    case confirmedOnly = "confirmed_only"
}

struct AutoResearchConfig: Codable, Equatable {
    let id: String
    let autoMaturityEvidence: MaturityEvidence
    let matchMaturityEvidence: MaturityEvidence
    let requiredMaturityCount: Int
    let autoSimilarity: Double
    let autoMargin: Double
    let minimumAverageSimilarity: Double
    let minimumSpeechSeconds: Double
    let minimumSegmentCount: Int
    let matchFloorOffset: Double
    let writeBackEvidence: WriteBackEvidence
    let writeBackMargin: Double
    let confidentWriteSimilarity: Double
    let cautiousWriteSimilarity: Double
    let confidentBlendAlpha: Float
    let cautiousBlendAlpha: Float
    let maximumExemplars: Int
    let exemplarSameConditionSimilarity: Double
    let exemplarBlendAlpha: Float

    static let productionBaseline = AutoResearchConfig(
        id: "baseline-production",
        autoMaturityEvidence: .confirmedMeetings,
        matchMaturityEvidence: .appearances,
        requiredMaturityCount: SpeakerNamingPolicy.requiredConfirmedMeetings,
        autoSimilarity: SpeakerNamingPolicy.autoAcceptSimilarityThreshold,
        autoMargin: SpeakerNamingPolicy.autoAcceptMarginMin,
        minimumAverageSimilarity: -1,
        minimumSpeechSeconds: 0,
        minimumSegmentCount: 0,
        matchFloorOffset: 0,
        writeBackEvidence: .production,
        writeBackMargin: SpeakerWritePathPolicy.writeBackMarginMin,
        confidentWriteSimilarity: SpeakerWritePathPolicy.confidentWriteBackSimilarity,
        cautiousWriteSimilarity: SpeakerWritePathPolicy.cautiousWriteBackSimilarity,
        confidentBlendAlpha: SpeakerWritePathPolicy.confidentBlendAlpha,
        cautiousBlendAlpha: SpeakerWritePathPolicy.cautiousBlendAlpha,
        maximumExemplars: SpeakerExemplarPolicy.maxExemplars,
        exemplarSameConditionSimilarity: SpeakerExemplarPolicy.sameConditionSimilarity,
        exemplarBlendAlpha: SpeakerExemplarPolicy.exemplarBlendAlpha
    )
}

struct ConfigEnvelope: Decodable {
    let configs: [AutoResearchConfig]
}

// MARK: - Report schema

struct MetricSnapshot: Codable {
    let observations: Int
    let scorableObservations: Int
    let recurringSpeakerUnits: Int
    let returningOpportunities: Int
    let asks: Int
    let suggestions: Int
    let automaticNames: Int
    let correctAutomaticNames: Int
    let falseAutomaticNames: Int
    let falseAutomaticNamesAllPurities: Int
    let automaticNamesOnLowPurity: Int
    let wrongSuggestions: Int
    let repeatPrompts: Int
    let openSetTrials: Int
    let openSetFalseAutomaticNames: Int
    let openSetWrongSuggestions: Int
    let falseMergeIndicators: Int
    let withinMeetingFalseMergeIndicators: Int
    let crossMeetingFalseMergeIndicators: Int
    let fragmentationExcess: Int
    let contaminatedProfiles: Int
    let profilesAtEnd: Int
    let identitiesReachingAuto: Int
    let meanAppearanceToFirstAuto: Double?
    let meanConfirmedMeetingsAtFirstAuto: Double?
    let promptsPerRecurringSpeaker: Double?
    let autoCoverage: Double?
    let autoPrecision: Double?
    let falseAutoUpper95WhenZero: Double?
}

struct TraceEvent: Codable {
    let corpus: String
    let meeting: String
    let meetingOrder: Int
    let truthSpeaker: String
    let purity: Double
    let speechSeconds: Double
    let segmentCount: Int
    let clusterCount: Int
    let decision: String
    let predictedProfileId: UUID?
    let predictedTruth: String?
    let resolvedProfileId: UUID
    let similarity: Double?
    let secondBestSimilarity: Double?
    let averageSimilarity: Double?
    let secondBestAverageSimilarity: Double?
    let matchThreshold: Double
    let appearanceCountAtDecision: Int?
    let confirmedMeetingsAtDecision: Int?
    let correct: Bool?
}

struct ConfigReport: Codable {
    let config: AutoResearchConfig
    let metrics: MetricSnapshot
    let slices: [String: MetricSnapshot]
    let events: [TraceEvent]?
}

struct AutoResearchReport: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let split: ResearchSplit
    let manifestPath: String
    let inputRoot: String
    let scoringPurityFloor: Double
    let splitContract: String
    let reports: [ConfigReport]
}

// MARK: - Mutable simulation state

struct SimulatedProfile {
    var value: SpeakerProfile
    let labelTruth: String
    var appearanceCount: Int
    var confirmedMeetings: Set<String>
    /// Most-recent-first, matching `SpeakerDatabase.recentMatchOutcomes`.
    var recentOutcomes: [SpeakerMatchOutcomeKind]
    var negativeExemplars: [[Float]]
    var exemplarCounts: [Int]
    var observedTruths: Set<String>
}

struct MutableMetrics {
    var observations = 0
    var scorableObservations = 0
    var recurringSpeakerUnits = 0
    var returningOpportunities = 0
    var asks = 0
    var suggestions = 0
    var automaticNames = 0
    var correctAutomaticNames = 0
    var falseAutomaticNames = 0
    var falseAutomaticNamesAllPurities = 0
    var automaticNamesOnLowPurity = 0
    var wrongSuggestions = 0
    var repeatPrompts = 0
    var openSetTrials = 0
    var openSetFalseAutomaticNames = 0
    var openSetWrongSuggestions = 0
    var withinMeetingFalseMergeIndicators = 0
    var crossMeetingFalseMergeIndicators = 0
    var fragmentationExcess = 0
    var contaminatedProfiles = 0
    var profilesAtEnd = 0
    var firstAutoAppearanceTotal = 0
    var firstAutoConfirmedTotal = 0
    var identitiesReachingAuto = 0

    mutating func merge(_ other: MutableMetrics) {
        observations += other.observations
        scorableObservations += other.scorableObservations
        recurringSpeakerUnits += other.recurringSpeakerUnits
        returningOpportunities += other.returningOpportunities
        asks += other.asks
        suggestions += other.suggestions
        automaticNames += other.automaticNames
        correctAutomaticNames += other.correctAutomaticNames
        falseAutomaticNames += other.falseAutomaticNames
        falseAutomaticNamesAllPurities += other.falseAutomaticNamesAllPurities
        automaticNamesOnLowPurity += other.automaticNamesOnLowPurity
        wrongSuggestions += other.wrongSuggestions
        repeatPrompts += other.repeatPrompts
        openSetTrials += other.openSetTrials
        openSetFalseAutomaticNames += other.openSetFalseAutomaticNames
        openSetWrongSuggestions += other.openSetWrongSuggestions
        withinMeetingFalseMergeIndicators += other.withinMeetingFalseMergeIndicators
        crossMeetingFalseMergeIndicators += other.crossMeetingFalseMergeIndicators
        fragmentationExcess += other.fragmentationExcess
        contaminatedProfiles += other.contaminatedProfiles
        profilesAtEnd += other.profilesAtEnd
        firstAutoAppearanceTotal += other.firstAutoAppearanceTotal
        firstAutoConfirmedTotal += other.firstAutoConfirmedTotal
        identitiesReachingAuto += other.identitiesReachingAuto
    }

    func snapshot() -> MetricSnapshot {
        let promptsPerSpeaker = recurringSpeakerUnits > 0
            ? Double(repeatPrompts) / Double(recurringSpeakerUnits) : nil
        let coverage = returningOpportunities > 0
            ? Double(correctAutomaticNames) / Double(returningOpportunities) : nil
        let precision = automaticNames > 0
            ? Double(automaticNames - falseAutomaticNames) / Double(automaticNames) : nil
        let firstAuto = identitiesReachingAuto > 0
            ? Double(firstAutoAppearanceTotal) / Double(identitiesReachingAuto) : nil
        let firstAutoConfirmed = identitiesReachingAuto > 0
            ? Double(firstAutoConfirmedTotal) / Double(identitiesReachingAuto) : nil
        let upper = falseAutomaticNames == 0 && automaticNames > 0
            ? min(1, 3.0 / Double(automaticNames)) : nil
        return MetricSnapshot(
            observations: observations,
            scorableObservations: scorableObservations,
            recurringSpeakerUnits: recurringSpeakerUnits,
            returningOpportunities: returningOpportunities,
            asks: asks,
            suggestions: suggestions,
            automaticNames: automaticNames,
            correctAutomaticNames: correctAutomaticNames,
            falseAutomaticNames: falseAutomaticNames,
            falseAutomaticNamesAllPurities: falseAutomaticNamesAllPurities,
            automaticNamesOnLowPurity: automaticNamesOnLowPurity,
            wrongSuggestions: wrongSuggestions,
            repeatPrompts: repeatPrompts,
            openSetTrials: openSetTrials,
            openSetFalseAutomaticNames: openSetFalseAutomaticNames,
            openSetWrongSuggestions: openSetWrongSuggestions,
            falseMergeIndicators: withinMeetingFalseMergeIndicators + crossMeetingFalseMergeIndicators,
            withinMeetingFalseMergeIndicators: withinMeetingFalseMergeIndicators,
            crossMeetingFalseMergeIndicators: crossMeetingFalseMergeIndicators,
            fragmentationExcess: fragmentationExcess,
            contaminatedProfiles: contaminatedProfiles,
            profilesAtEnd: profilesAtEnd,
            identitiesReachingAuto: identitiesReachingAuto,
            meanAppearanceToFirstAuto: firstAuto,
            meanConfirmedMeetingsAtFirstAuto: firstAutoConfirmed,
            promptsPerRecurringSpeaker: promptsPerSpeaker,
            autoCoverage: coverage,
            autoPrecision: precision,
            falseAutoUpper95WhenZero: upper
        )
    }
}

struct PendingObservation {
    let input: FingerprintSpeaker
    var match: Transcription.SnapshotMatchResult?
    let matchThreshold: Double
}

struct CacheEvaluation {
    var metrics: MutableMetrics
    var events: [TraceEvent]
}

struct AccumulatedConfig {
    var metrics = MutableMetrics()
    var slices: [String: MutableMetrics] = [:]
    var events: [TraceEvent] = []
}
