#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

struct PersonalNextWordStoredCheckpoint: Codable, Equatable, Sendable {
    private static let version = 1

    let v: Int
    let historyIdentifier: String
    let experimentIdentifier: String
    let excludedApps: [String]
    let checkpoint: PersonalNextWordShadowCheckpoint

    init(
        historyIdentifier: String,
        experimentIdentifier: String,
        excludedApps: Set<String>,
        checkpoint: PersonalNextWordShadowCheckpoint
    ) {
        v = Self.version
        self.historyIdentifier = historyIdentifier
        self.experimentIdentifier = experimentIdentifier
        self.excludedApps = PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
        self.checkpoint = checkpoint
    }

    func matches(
        historyIdentifier: String,
        experimentIdentifier: String,
        excludedApps: Set<String>
    ) -> Bool {
        v == Self.version
            && self.historyIdentifier == historyIdentifier
            && self.experimentIdentifier == experimentIdentifier
            && self.excludedApps == PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
    }

    fileprivate var hasValidEnvelope: Bool {
        v > 0
            && PersonalHistoryEvent.validIdentifier(historyIdentifier)
            && PersonalHistoryEvent.validIdentifier(experimentIdentifier)
            && excludedApps == PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
    }

    var isCompatibleWithCurrentExperiment: Bool {
        v == Self.version && checkpoint.isCompatibleWithCurrentExperiment
    }
}

/// The trained table plus the scope it was trained under. The scope fields are
/// the checkpoint's, checked the same way: a rotated history or experiment
/// identifier, or a changed exclusion list, means this table was learned from
/// a corpus the owner has since redrawn, and it is discarded rather than
/// carried across the boundary.
struct PersonalNextWordStoredModel: Codable, Equatable, Sendable {
    private static let version = 1

    let v: Int
    let historyIdentifier: String
    let experimentIdentifier: String
    let excludedApps: [String]
    /// The log position (`PersonalHistoryStore.append`'s return value) the
    /// table has already consumed. Records after it still need replaying.
    let coveredThroughSequence: Int64
    let model: PersonalNextWordTrainedModel

    init(
        historyIdentifier: String,
        experimentIdentifier: String,
        excludedApps: Set<String>,
        coveredThroughSequence: Int64,
        model: PersonalNextWordTrainedModel
    ) {
        v = Self.version
        self.historyIdentifier = historyIdentifier
        self.experimentIdentifier = experimentIdentifier
        self.excludedApps = PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
        self.coveredThroughSequence = coveredThroughSequence
        self.model = model
    }

    func matches(
        historyIdentifier: String,
        experimentIdentifier: String,
        excludedApps: Set<String>
    ) -> Bool {
        v == Self.version
            && self.historyIdentifier == historyIdentifier
            && self.experimentIdentifier == experimentIdentifier
            && self.excludedApps == PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
            && coveredThroughSequence >= 0
            && model.isCompatibleWithCurrentRecipe
    }

    fileprivate var hasValidEnvelope: Bool {
        v > 0
            && PersonalHistoryEvent.validIdentifier(historyIdentifier)
            && PersonalHistoryEvent.validIdentifier(experimentIdentifier)
            && excludedApps == PersonalHistoryCapturePolicy.normalizedExcludedApps(excludedApps)
            && coveredThroughSequence >= 0
    }
}
