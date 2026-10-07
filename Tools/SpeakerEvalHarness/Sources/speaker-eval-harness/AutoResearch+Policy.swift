import Foundation
import CryptoKit
import TranscriptedCore

/// Count each contaminated (predicted profile, truth-speaker pair) exactly once.
/// A pair is within-meeting when the two truths ever shared a meeting; otherwise
/// it is cross-meeting. The buckets are intentionally disjoint so their sum is
/// a meaningful total instead of counting one collision twice.
func falseMergeIndicators(
    _ meetingsByProfileAndTruth: [UUID: [String: Set<String>]],
    scoredMeetingsByProfileAndTruth: [UUID: [String: Set<String>]]? = nil
) -> (withinMeeting: Int, crossMeeting: Int) {
    var withinMeeting = 0
    var crossMeeting = 0

    for (profileId, meetingsByTruth) in meetingsByProfileAndTruth {
        let truths = meetingsByTruth.keys.sorted()
        guard truths.count > 1 else { continue }
        for firstIndex in 0..<(truths.count - 1) {
            for secondIndex in (firstIndex + 1)..<truths.count {
                if let scoredMeetingsByProfileAndTruth {
                    let scoredByTruth = scoredMeetingsByProfileAndTruth[profileId] ?? [:]
                    let firstWasScored = !(scoredByTruth[truths[firstIndex]]?.isEmpty ?? true)
                    let secondWasScored = !(scoredByTruth[truths[secondIndex]]?.isEmpty ?? true)
                    if !firstWasScored && !secondWasScored {
                        continue
                    }
                }
                let firstMeetings = meetingsByTruth[truths[firstIndex]] ?? []
                let secondMeetings = meetingsByTruth[truths[secondIndex]] ?? []
                if firstMeetings.isDisjoint(with: secondMeetings) {
                    crossMeeting += 1
                } else {
                    withinMeeting += 1
                }
            }
        }
    }
    return (withinMeeting, crossMeeting)
}

func shouldAutoName(
    state: SimulatedProfile,
    match: Transcription.SnapshotMatchResult,
    speaker: FingerprintSpeaker,
    config: AutoResearchConfig
) -> Bool {
    let maturity = config.autoMaturityEvidence == .appearances
        ? state.appearanceCount : state.confirmedMeetings.count
    let runner = match.secondBestAverageSimilarity
    let marginOK = runner < 0 || (match.averageSimilarity - runner) >= config.autoMargin
    let averageOK = config.minimumAverageSimilarity < 0
        || match.averageSimilarity >= config.minimumAverageSimilarity
    let health = SpeakerProfileHealth.assess(
        disputeCount: state.value.disputeCount,
        recentOutcomes: state.recentOutcomes
    )
    let decision = state.value.displayName?.isEmpty == false
        && health == .trusted
        && maturity >= config.requiredMaturityCount
        && match.similarity > config.autoSimilarity
        && marginOK
        && averageOK
        && speaker.durationSeconds >= config.minimumSpeechSeconds
        && speaker.segmentCount >= config.minimumSegmentCount

    if config == .productionBaseline {
        var profile = state.value
        profile.callCount = state.appearanceCount
        profile.confirmedMeetingCount = state.confirmedMeetings.count
        let production = SpeakerNamingPolicy.shouldAutoAccept(
            profile: profile,
            similarity: match.similarity,
            secondBestSimilarity: match.secondBestSimilarity,
            recentOutcomes: state.recentOutcomes,
            marginSimilarities: (match.averageSimilarity, match.secondBestAverageSimilarity)
        )
        precondition(production == decision, "baseline policy parity failure")
    }
    return decision
}


func blendAlpha(
    similarity: Double,
    secondBest: Double,
    config: AutoResearchConfig
) -> Float {
    if secondBest >= 0, similarity - secondBest < config.writeBackMargin { return 0 }
    if similarity >= config.confidentWriteSimilarity { return config.confidentBlendAlpha }
    if similarity >= config.cautiousWriteSimilarity { return config.cautiousBlendAlpha }
    return 0
}

func blend(_ existing: [Float], _ incoming: [Float], alpha: Float) -> [Float] {
    guard existing.count == incoming.count else { return existing }
    let bounded = max(0, min(1, alpha))
    return SpeakerVectorMath.l2Normalize(zip(existing, incoming).map { old, new in
        old * (1 - bounded) + new * bounded
    })
}

func updateExemplars(
    state: inout SimulatedProfile,
    incoming: [Float],
    config: AutoResearchConfig
) {
    guard config.maximumExemplars > 0, incoming.count == state.value.embedding.count else {
        state.value.exemplars = []
        state.exemplarCounts = []
        return
    }
    var exemplars = state.value.exemplars
    var counts = state.exemplarCounts
    while counts.count < exemplars.count { counts.append(1) }
    let averageSimilarity = SpeakerVectorMath.cosineSimilarity(incoming, state.value.embedding)
    var bestSimilarity = averageSimilarity
    var bestIndex: Int?
    for i in exemplars.indices {
        let similarity = SpeakerVectorMath.cosineSimilarity(incoming, exemplars[i])
        if similarity > bestSimilarity { bestSimilarity = similarity; bestIndex = i }
    }
    if bestSimilarity >= config.exemplarSameConditionSimilarity {
        if let bestIndex {
            exemplars[bestIndex] = blend(exemplars[bestIndex], incoming, alpha: config.exemplarBlendAlpha)
            counts[bestIndex] += 1
        }
    } else if exemplars.count < config.maximumExemplars {
        exemplars.append(SpeakerVectorMath.l2Normalize(incoming))
        counts.append(1)
    } else if let victim = mostRedundantExemplar(exemplars, average: state.value.embedding),
              victim.similarity > bestSimilarity {
        exemplars[victim.index] = SpeakerVectorMath.l2Normalize(incoming)
        counts[victim.index] = 1
    }
    state.value.exemplars = exemplars
    state.exemplarCounts = counts
}

private func mostRedundantExemplar(
    _ exemplars: [[Float]],
    average: [Float]
) -> (index: Int, similarity: Double)? {
    guard !exemplars.isEmpty else { return nil }
    var result = (index: 0, similarity: -Double.infinity)
    for i in exemplars.indices {
        var similarity = SpeakerVectorMath.cosineSimilarity(exemplars[i], average)
        for j in exemplars.indices where i != j {
            similarity = max(similarity, SpeakerVectorMath.cosineSimilarity(exemplars[i], exemplars[j]))
        }
        if similarity > result.similarity { result = (i, similarity) }
    }
    return result
}

// MARK: - Stable identity split

func corpusFamily(_ corpus: String) -> String {
    if corpus.hasPrefix("ami_") { return "ami" }
    if corpus.hasPrefix("voxceleb_") { return "voxceleb" }
    if corpus.hasPrefix("voxconverse_") { return "voxconverse" }
    return corpus.split(separator: "_").first.map(String.init) ?? corpus
}

func identitySplit(family: String, truth: String) -> ResearchSplit {
    let bucket = stableFNV1a("\(family)|\(truth)") % 10
    switch bucket {
    case 0...5: return .train
    case 6...7: return .dev
    default: return .holdout
    }
}

private func stableFNV1a(_ value: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in value.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

func deterministicProfileId(_ value: UInt64) -> UUID {
    let suffix = String(format: "%012llx", value)
    return UUID(uuidString: "00000000-0000-0000-0000-\(suffix)")!
}
