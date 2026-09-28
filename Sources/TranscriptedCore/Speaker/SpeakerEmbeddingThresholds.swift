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

    public init(matchOneSegment: Double, matchFewSegments: Double, matchManySegments: Double,
                ghostMergeFloor: Double, consolidation: Float, absorb: Float, microAbsorb: Float,
                perSegmentSplit: Float, knownProfileConflict: Float) {
        self.matchOneSegment = matchOneSegment
        self.matchFewSegments = matchFewSegments
        self.matchManySegments = matchManySegments
        self.ghostMergeFloor = ghostMergeFloor
        self.consolidation = consolidation
        self.absorb = absorb
        self.microAbsorb = microAbsorb
        self.perSegmentSplit = perSegmentSplit
        self.knownProfileConflict = knownProfileConflict
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
    public static let eRes2Net = SpeakerEmbeddingThresholds(
        matchOneSegment: 0.70, matchFewSegments: 0.62, matchManySegments: 0.55,
        ghostMergeFloor: 0.55,
        consolidation: LabKnobOverrides.float("speaker.cluster.same_voice_consolidation.eres2net", default: 0.65),
        absorb: LabKnobOverrides.float("speaker.cluster.small_cluster_absorb.eres2net", default: 0.55),
        microAbsorb: 0.45,
        perSegmentSplit: 0.50, knownProfileConflict: 0.55)
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
/// File format: one JSON object with all nine fields, in snake_case or camelCase:
///
///     {"match_one_segment": 0.70, "match_few_segments": 0.62, "match_many_segments": 0.55,
///      "ghost_merge_floor": 0.55, "consolidation": 0.65, "absorb": 0.55, "micro_absorb": 0.45,
///      "per_segment_split": 0.50, "known_profile_conflict": 0.55}
///
/// The same object may instead sit under a top-level `"thresholds"` key, next to
/// provenance such as the model id and the false-accept rates it was matched to.
/// Other keys are ignored. A missing field, or a value that is not a cosine in
/// [-1, 1], is an error: a file never silently falls back to another model's bars.
extension SpeakerEmbeddingThresholds: Codable {
    enum CodingKeys: String, CodingKey {
        case matchOneSegment, matchFewSegments, matchManySegments, ghostMergeFloor
        case consolidation, absorb, microAbsorb, perSegmentSplit, knownProfileConflict
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
        self.init(
            matchOneSegment: try cosine(.matchOneSegment),
            matchFewSegments: try cosine(.matchFewSegments),
            matchManySegments: try cosine(.matchManySegments),
            ghostMergeFloor: try cosine(.ghostMergeFloor),
            consolidation: Float(try cosine(.consolidation)),
            absorb: Float(try cosine(.absorb)),
            microAbsorb: Float(try cosine(.microAbsorb)),
            perSegmentSplit: Float(try cosine(.perSegmentSplit)),
            knownProfileConflict: Float(try cosine(.knownProfileConflict)))
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
