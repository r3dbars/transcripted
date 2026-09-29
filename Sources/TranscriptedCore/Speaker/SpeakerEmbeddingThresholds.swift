// SpeakerEmbeddingThresholds.swift
// Per-model cosine thresholds for the speaker identity stack. Different embedding
// models have different cosine geometry, so the matcher / clusterer thresholds
// must be model-specific. WeSpeaker (the diarizer's built-in 256-d model) keeps
// the production-tuned values; ERes2Net (192-d) uses values calibrated on AMI
// ground truth — see scripts/recalibrate_eres2net_groundtruth.py.
//
// Calibration method: for each WeSpeaker operating point we measured its true
// false-accept rate on AMI (RTTM ground truth), then chose the ERes2Net threshold
// that achieves the SAME false-accept rate. ERes2Net separates speakers far better
// cross-call (EER 0% vs WeSpeaker 5.2%; different-speaker p95 cosine 0.40 vs 0.62),
// so its thresholds are lower while *reducing* false merges and false rejects.

import Foundation

public struct SpeakerEmbeddingThresholds: Sendable, Equatable {
    /// Cross-call DB match, adaptive by how many segments backed the mean embedding
    /// (fewer segments → noisier mean → stricter threshold).
    public let matchOneSegment: Double      // 1 segment
    public let matchFewSegments: Double     // 2–3 segments
    public let matchManySegments: Double    // 4+ segments
    /// Floor for force-merging a low-quality "ghost" speaker into the closest real one.
    public let ghostMergeFloor: Double
    /// Within-meeting clustering thresholds.
    public let consolidation: Float         // merge over-segmented same-voice clusters
    public let absorb: Float                // absorb a small cluster into a large one
    public let microAbsorb: Float           // absorb a very short cluster
    public let perSegmentSplit: Float       // DB-informed split of a mixed cluster
    public let knownProfileConflict: Float  // "these centroids may be different known people"

    // MARK: Identity bars (matching guards, write-back, naming ladder, cleanup)
    //
    // Every other cosine bar the speaker stack compares a voiceprint against. They
    // were tuned on WeSpeaker and used for every model until now, so both presets
    // keep exactly those values (the init defaults below), and a calibration file
    // may set any of them for a new model.

    /// Match guard: extra similarity a profile heard in 2 or fewer calls must clear
    /// on top of the adaptive match floor (`Transcription.matchAgainstProfiles`).
    public let immatureProfileMatchBonus: Double
    /// Match guard: extra similarity for a profile heard in 3–4 calls.
    public let developingProfileMatchBonus: Double
    /// Match guard: a runner-up profile this close to the winner makes the match ambiguous.
    public let ambiguousMatchMargin: Double
    /// Negative-exemplar veto floor (`SpeakerNegativeExemplarPolicy`).
    public let negativeVetoFloor: Double
    /// Write-back: minimum margin to the runner-up before a match may adapt the voiceprint
    /// (`SpeakerWritePathPolicy`).
    public let writeBackMarginMin: Double
    /// Write-back: at or above this a match adapts the voiceprint at the full rate.
    public let confidentWriteBack: Double
    /// Write-back: at or above this (and below `confidentWriteBack`) it adapts slowly.
    public let cautiousWriteBack: Double
    /// Two clusters that matched the same profile fuse only at or above this
    /// cluster-to-cluster cosine (`SpeakerWritePathPolicy.shouldFuseMatchedClusters`).
    public let crossClusterLink: Double
    /// Multi-exemplar voiceprints: at or above this a new session mean counts as the same
    /// capture condition as an existing representative (`SpeakerExemplarPolicy`).
    public let exemplarSameCondition: Double
    /// Naming ladder: silent auto-accept needs similarity above this (`SpeakerNamingPolicy`).
    public let autoAcceptSimilarity: Double
    /// Naming ladder: and at least this margin to the runner-up.
    public let autoAcceptMarginMin: Double
    /// Lineup naming: the lower similarity bar for a person on the meeting's lineup
    /// (`SpeakerNamingPolicy.InviteeBars`).
    public let inviteeSimilarity: Double
    /// Lineup naming: the lower margin bar for a person on the meeting's lineup.
    public let inviteeMarginMin: Double
    /// An auto-named speaker is labeled high confidence above this similarity
    /// (`SpeakerNamingPolicy.confidence`).
    public let highConfidenceSimilarity: Double
    /// After-meeting cleanup merges two saved profiles at or above this cosine
    /// (`SpeakerDatabase.mergeDuplicates`).
    public let duplicateProfileMerge: Double
    /// Speaker separation merges two call-channel voices at or above this cosine
    /// (`SpeakerSeparationOptions.labTuned`).
    public let separationMerge: Double

    public init(matchOneSegment: Double, matchFewSegments: Double, matchManySegments: Double,
                ghostMergeFloor: Double, consolidation: Float, absorb: Float, microAbsorb: Float,
                perSegmentSplit: Float, knownProfileConflict: Float,
                immatureProfileMatchBonus: Double = 0.08,
                developingProfileMatchBonus: Double = 0.04,
                ambiguousMatchMargin: Double = 0.05,
                negativeVetoFloor: Double = 0.80,
                writeBackMarginMin: Double = 0.12,
                confidentWriteBack: Double = 0.80,
                cautiousWriteBack: Double = 0.72,
                crossClusterLink: Double = 0.78,
                exemplarSameCondition: Double = 0.80,
                autoAcceptSimilarity: Double = 0.92,
                autoAcceptMarginMin: Double = 0.12,
                inviteeSimilarity: Double = 0.80,
                inviteeMarginMin: Double = 0.10,
                highConfidenceSimilarity: Double = 0.85,
                duplicateProfileMerge: Double = 0.6,
                separationMerge: Double = 0.6) {
        self.matchOneSegment = matchOneSegment
        self.matchFewSegments = matchFewSegments
        self.matchManySegments = matchManySegments
        self.ghostMergeFloor = ghostMergeFloor
        self.consolidation = consolidation
        self.absorb = absorb
        self.microAbsorb = microAbsorb
        self.perSegmentSplit = perSegmentSplit
        self.knownProfileConflict = knownProfileConflict
        self.immatureProfileMatchBonus = immatureProfileMatchBonus
        self.developingProfileMatchBonus = developingProfileMatchBonus
        self.ambiguousMatchMargin = ambiguousMatchMargin
        self.negativeVetoFloor = negativeVetoFloor
        self.writeBackMarginMin = writeBackMarginMin
        self.confidentWriteBack = confidentWriteBack
        self.cautiousWriteBack = cautiousWriteBack
        self.crossClusterLink = crossClusterLink
        self.exemplarSameCondition = exemplarSameCondition
        self.autoAcceptSimilarity = autoAcceptSimilarity
        self.autoAcceptMarginMin = autoAcceptMarginMin
        self.inviteeSimilarity = inviteeSimilarity
        self.inviteeMarginMin = inviteeMarginMin
        self.highConfidenceSimilarity = highConfidenceSimilarity
        self.duplicateProfileMerge = duplicateProfileMerge
        self.separationMerge = separationMerge
    }

    /// Adaptive DB-match threshold for a speaker whose mean embedding came from
    /// `count` segments.
    public func adaptiveMatch(forSegmentCount count: Int) -> Double {
        switch count {
        case 1: return matchOneSegment
        case 2...3: return matchFewSegments
        default: return matchManySegments
        }
    }

    /// WeSpeaker (256-d) — the diarizer's built-in model. Exactly the production
    /// values the matcher/clusterer used before per-model thresholds existed, so
    /// the default path is unchanged. `consolidation` and `absorb` go through
    /// LabKnobOverrides, which returns these exact defaults unless the hill-climb
    /// lab sets TRANSCRIPTED_LAB_KNOBS_FILE; the value is fixed at first use.
    /// The identity bars are the init defaults, the values they were tuned at.
    public static let weSpeaker = SpeakerEmbeddingThresholds(
        matchOneSegment: 0.85, matchFewSegments: 0.78, matchManySegments: 0.70,
        ghostMergeFloor: 0.72,
        consolidation: LabKnobOverrides.float("speaker.cluster.same_voice_consolidation.wespeaker", default: 0.88),
        absorb: LabKnobOverrides.float("speaker.cluster.small_cluster_absorb.wespeaker", default: 0.72),
        microAbsorb: 0.62,
        perSegmentSplit: 0.62, knownProfileConflict: 0.70)

    /// ERes2Net (192-d) — calibrated on AMI ground truth (equal-false-accept-rate
    /// remap of the WeSpeaker operating points). Lower absolute values because
    /// ERes2Net's different-speaker cosines are much tighter. `consolidation` and
    /// `absorb` go through LabKnobOverrides (defaults unchanged, see weSpeaker).
    /// The identity bars were never recalibrated for ERes2Net: it keeps the
    /// WeSpeaker-scale init defaults it has always run with.
    public static let eRes2Net = SpeakerEmbeddingThresholds(
        matchOneSegment: 0.70, matchFewSegments: 0.62, matchManySegments: 0.55,
        ghostMergeFloor: 0.55,
        consolidation: LabKnobOverrides.float("speaker.cluster.same_voice_consolidation.eres2net", default: 0.65),
        absorb: LabKnobOverrides.float("speaker.cluster.small_cluster_absorb.eres2net", default: 0.55),
        microAbsorb: 0.45,
        perSegmentSplit: 0.50, knownProfileConflict: 0.55)

    /// ReDimNet2 b4 (192-d, Palabra.ai, VoxCeleb2-trained): the voiceprint bake-off winner
    /// (Tools/SpeakerEvalHarness/VOICEPRINT_RESULTS.md). Every bar is WeSpeaker's moved
    /// to ReDimNet2 at the same false-accept rate, measured on 334 human-labeled people
    /// over clean, Opus 12 kbps and noisy audio, holding in the worst of those
    /// (`scripts/voiceprint/calibrate_thresholds.py`). These exact values ran end to end
    /// through the real pipeline with 0 wrong silent names.
    public static let reDimNet2B4 = SpeakerEmbeddingThresholds(
        matchOneSegment: 0.860, matchFewSegments: 0.787, matchManySegments: 0.707,
        ghostMergeFloor: 0.723,
        consolidation: 0.902, absorb: 0.726, microAbsorb: 0.626,
        perSegmentSplit: 0.635, knownProfileConflict: 0.707,
        immatureProfileMatchBonus: 0.085,
        developingProfileMatchBonus: 0.043,
        ambiguousMatchMargin: 0.053,
        negativeVetoFloor: 0.817,
        writeBackMarginMin: 0.128,
        confidentWriteBack: 0.815,
        cautiousWriteBack: 0.728,
        crossClusterLink: 0.795,
        exemplarSameCondition: 0.828,
        autoAcceptSimilarity: 0.946,
        autoAcceptMarginMin: 0.128,
        inviteeSimilarity: 0.815,
        inviteeMarginMin: 0.106,
        highConfidenceSimilarity: 0.869,
        duplicateProfileMerge: 0.598,
        separationMerge: 0.598)
}

// MARK: - Calibration files

/// Why a thresholds calibration file could not be used. The message names the
/// offending key but never a value or a path.
public struct SpeakerEmbeddingThresholdsFileError: Error, LocalizedError, Equatable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// Thresholds for a new voiceprint model come from a calibration file, so a
/// candidate can be tested without code changes. The presets above never read one.
///
/// File format: one JSON object with the nine match and clustering fields, in
/// snake_case or camelCase:
///
///     {"match_one_segment": 0.70, "match_few_segments": 0.62, "match_many_segments": 0.55,
///      "ghost_merge_floor": 0.55, "consolidation": 0.65, "absorb": 0.55, "micro_absorb": 0.45,
///      "per_segment_split": 0.50, "known_profile_conflict": 0.55}
///
/// The same object may instead sit under a top-level `"thresholds"` key, next to
/// provenance such as the model id and the false-accept rates it was matched to.
/// Other keys are ignored. A missing one of those nine, or any value that is not a
/// cosine in [-1, 1], is an error: a file never silently falls back to another
/// model's match or clustering bars.
///
/// The identity bars are optional, and one that is left out keeps its WeSpeaker
/// value (what every model used before they were per-model):
/// `immature_profile_match_bonus`, `developing_profile_match_bonus`,
/// `ambiguous_match_margin`, `negative_veto_floor`, `write_back_margin_min`,
/// `confident_write_back`, `cautious_write_back`, `cross_cluster_link`,
/// `exemplar_same_condition`, `auto_accept_similarity`, `auto_accept_margin_min`,
/// `invitee_similarity`, `invitee_margin_min`, `high_confidence_similarity`,
/// `duplicate_profile_merge`, `separation_merge`.
extension SpeakerEmbeddingThresholds: Codable {
    enum CodingKeys: String, CodingKey {
        case matchOneSegment, matchFewSegments, matchManySegments, ghostMergeFloor
        case consolidation, absorb, microAbsorb, perSegmentSplit, knownProfileConflict
        case immatureProfileMatchBonus, developingProfileMatchBonus, ambiguousMatchMargin
        case negativeVetoFloor
        case writeBackMarginMin, confidentWriteBack, cautiousWriteBack, crossClusterLink
        case exemplarSameCondition
        case autoAcceptSimilarity, autoAcceptMarginMin, inviteeSimilarity, inviteeMarginMin
        case highConfidenceSimilarity
        case duplicateProfileMerge, separationMerge
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func cosine(_ key: CodingKeys) throws -> Double {
            let value = try container.decode(Double.self, forKey: key)
            guard value.isFinite, value >= -1, value <= 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: key, in: container,
                    debugDescription: "\(key.stringValue) must be a cosine between -1 and 1")
            }
            return value
        }
        // Optional identity bar: absent keeps the WeSpeaker value; present must be a cosine.
        let wespeaker = SpeakerEmbeddingThresholds.weSpeaker
        func identityBar(_ key: CodingKeys, _ fallback: Double) throws -> Double {
            container.contains(key) ? try cosine(key) : fallback
        }
        self.init(
            matchOneSegment: try cosine(.matchOneSegment),
            matchFewSegments: try cosine(.matchFewSegments),
            matchManySegments: try cosine(.matchManySegments),
            ghostMergeFloor: try cosine(.ghostMergeFloor),
            consolidation: Float(try cosine(.consolidation)),
            absorb: Float(try cosine(.absorb)),
            microAbsorb: Float(try cosine(.microAbsorb)),
            perSegmentSplit: Float(try cosine(.perSegmentSplit)),
            knownProfileConflict: Float(try cosine(.knownProfileConflict)),
            immatureProfileMatchBonus: try identityBar(.immatureProfileMatchBonus, wespeaker.immatureProfileMatchBonus),
            developingProfileMatchBonus: try identityBar(.developingProfileMatchBonus, wespeaker.developingProfileMatchBonus),
            ambiguousMatchMargin: try identityBar(.ambiguousMatchMargin, wespeaker.ambiguousMatchMargin),
            negativeVetoFloor: try identityBar(.negativeVetoFloor, wespeaker.negativeVetoFloor),
            writeBackMarginMin: try identityBar(.writeBackMarginMin, wespeaker.writeBackMarginMin),
            confidentWriteBack: try identityBar(.confidentWriteBack, wespeaker.confidentWriteBack),
            cautiousWriteBack: try identityBar(.cautiousWriteBack, wespeaker.cautiousWriteBack),
            crossClusterLink: try identityBar(.crossClusterLink, wespeaker.crossClusterLink),
            exemplarSameCondition: try identityBar(.exemplarSameCondition, wespeaker.exemplarSameCondition),
            autoAcceptSimilarity: try identityBar(.autoAcceptSimilarity, wespeaker.autoAcceptSimilarity),
            autoAcceptMarginMin: try identityBar(.autoAcceptMarginMin, wespeaker.autoAcceptMarginMin),
            inviteeSimilarity: try identityBar(.inviteeSimilarity, wespeaker.inviteeSimilarity),
            inviteeMarginMin: try identityBar(.inviteeMarginMin, wespeaker.inviteeMarginMin),
            highConfidenceSimilarity: try identityBar(.highConfidenceSimilarity, wespeaker.highConfidenceSimilarity),
            duplicateProfileMerge: try identityBar(.duplicateProfileMerge, wespeaker.duplicateProfileMerge),
            separationMerge: try identityBar(.separationMerge, wespeaker.separationMerge))
    }

    /// Reads a calibration file (format above).
    public static func load(contentsOf url: URL) throws -> SpeakerEmbeddingThresholds {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw SpeakerEmbeddingThresholdsFileError("thresholds file could not be read")
        }
        return try decode(jsonData: data)
    }

    /// Parses a calibration file's bytes (format above).
    public static func decode(jsonData: Data) throws -> SpeakerEmbeddingThresholds {
        guard let object = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any] else {
            throw SpeakerEmbeddingThresholdsFileError("thresholds file is not a JSON object")
        }
        let body: Data
        if let nested = object["thresholds"] {
            guard let nestedObject = nested as? [String: Any],
                  let nestedData = try? JSONSerialization.data(withJSONObject: nestedObject) else {
                throw SpeakerEmbeddingThresholdsFileError("\"thresholds\" must be a JSON object")
            }
            body = nestedData
        } else {
            body = jsonData
        }
        let decoder = JSONDecoder()
        // snake_case keys convert to the camelCase field names; camelCase keys pass through.
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try decoder.decode(SpeakerEmbeddingThresholds.self, from: body)
        } catch let DecodingError.keyNotFound(key, _) {
            throw SpeakerEmbeddingThresholdsFileError("thresholds file is missing \(key.stringValue)")
        } catch let DecodingError.dataCorrupted(context) {
            throw SpeakerEmbeddingThresholdsFileError(context.debugDescription)
        } catch let DecodingError.typeMismatch(_, context) {
            let key = context.codingPath.last?.stringValue ?? "a field"
            throw SpeakerEmbeddingThresholdsFileError("\(key) must be a number")
        } catch let DecodingError.valueNotFound(_, context) {
            let key = context.codingPath.last?.stringValue ?? "a field"
            throw SpeakerEmbeddingThresholdsFileError("\(key) must be a number")
        } catch {
            throw SpeakerEmbeddingThresholdsFileError("thresholds file could not be parsed")
        }
    }
}
