// EmbeddingParity.swift — `speaker-eval-harness embedding-parity`
//
// Can Nemotron + WeSpeaker voiceprints share the default speakers.sqlite with the
// people saved by today's pyannote pipeline? Nemotron emits no embeddings, so its
// voiceprints come from Core's `FluidWeSpeakerSegmentEmbedder` (FluidAudio's ONLINE
// WeSpeaker model, `wespeaker_v2.mlmodelc`). Today's pyannote backend emits the
// OFFLINE WeSpeaker model's vectors (`Embedding.mlmodelc`). Same network in
// principle, two different Core ML conversions, and nothing upstream checks parity.
// This command measures it on one recording:
//
//   1. run today's DiarizationService (pyannote, native offline WeSpeaker embeddings)
//   2. re-embed each of those SAME segments with FluidWeSpeakerSegmentEmbedder
//   3. compare the two vectors per segment, per speaker cluster (the production
//      quality-filtered mean, which is what the speaker DB stores and matches), and
//      across speakers, so we see both "same voice, other model" and "other voice,
//      other model" against the app's WeSpeaker match floor.
//
// Segment boundaries come from pyannote for both models, so the only thing that
// differs is the embedding model: this isolates the "can the DBs be merged" question
// from "is Nemotron's segmentation better" (that is the speaker lab's job).
//
// Heads-up baked into the output: FluidAudio's offline pipeline hands every segment
// its VBx cluster CENTROID as the embedding (a weighted mean of raw 10 s-window
// embeddings), not a per-segment vector. `nativeIsClusterCentroid` reports whether
// that held on this recording; when it did, native "same speaker" pair cosines are
// trivially ~1 and the useful native numbers are the cross-cluster ones.

import Foundation
import TranscriptedCore

// MARK: - Wire models

/// Equal-width histogram bins over cosine [-1, 1]; lets the lab scorer pool meetings.
let parityHistogramBins = 200
let parityReportSchema = "transcripted.speaker-lab.embedding-parity"

/// One cosine distribution. `nil` summary fields when `count` is 0.
struct ParityStats: Codable {
    let count: Int
    let mean: Double?
    let median: Double?
    let p10: Double?
    let p90: Double?
    let min: Double?
    let max: Double?
    let histogram: [Int]
}

struct ParityPairStats: Codable {
    let sameSpeaker: ParityStats
    let differentSpeaker: ParityStats
}

struct ParityCluster: Codable {
    let cluster: Int                   // pyannote cluster id (dump speakerId)
    let segments: Int                  // compared segments in this cluster
    let speechSeconds: Double
    let meanSegments: Int              // segment vectors behind the online mean (drives the adaptive floor)
    let crossModelCosine: Double       // online mean vs native mean of the SAME cluster
    let bestOtherNativeCosine: Double? // online mean vs the closest OTHER cluster's native mean
    let top1: Bool                     // its own native mean is the closest one
    let matchFloor: Double             // SpeakerEmbeddingThresholds.weSpeaker.adaptiveMatch(meanSegments)
    let clearsMatchFloor: Bool         // crossModelCosine >= matchFloor
}

struct ParityClusterSummary: Codable {
    let clustersCompared: Int
    let top1Count: Int
    let clearsMatchFloorCount: Int
    /// online mean(a) vs native mean(a): would a returning person be found across models?
    let sameCluster: ParityStats
    /// online mean(a) vs native mean(b), a != b (ordered pairs): cross-model false-accept risk.
    let differentCluster: ParityStats
    let differentPairs: Int
    let differentClearsMatchFloorCount: Int
    /// native mean(a) vs native mean(b), a != b: today's single-model baseline for the same risk.
    let nativeDifferentCluster: ParityStats
    let nativeDifferentPairs: Int
    let nativeDifferentClearsMatchFloorCount: Int
    /// online mean(a) vs online mean(b), a != b: the online model's own separation.
    let onlineDifferentCluster: ParityStats
    let perCluster: [ParityCluster]
}

struct ParitySegmentCounts: Codable {
    let total: Int
    let compared: Int             // both vectors present and duration >= minSegmentSeconds
    let tooShort: Int
    let noNativeEmbedding: Int
    let onlineFailed: Int         // online embedder returned nil (or a different dimension)
    let unlabeled: Int            // compared, but no reference speaker covers half the segment
}

struct EmbeddingParityReport: Codable {
    let schema: String
    let schemaVersion: Int
    let meeting: String
    let audioSeconds: Double
    let labelSource: String       // "rttm" (ground truth) | "diarizer" (pyannote clusters)
    let nativeModel: String
    let onlineModel: String
    let minSegmentSeconds: Double
    let pairRowsCap: Int
    let segments: ParitySegmentCounts
    let nativeIsClusterCentroid: Bool
    /// cosine(native_i, online_i) for the same segment.
    let perSegment: ParityStats
    /// keys "native" and "online": pairs of segments within one model, by speaker label.
    let withinModel: [String: ParityPairStats]
    /// online_i vs native_j, i != j, by speaker label.
    let crossModel: ParityPairStats
    let clusters: ParityClusterSummary
    /// `ParityVerdict.looksInterchangeable`; nil with fewer than 2 comparable clusters.
    let looksInterchangeable: Bool?
    let diarizeSeconds: Double
    let embedSeconds: Double
}

// MARK: - Verdict

/// Per-recording heuristic for "the two WeSpeaker paths can share one speaker DB".
/// scripts/score_speaker_lab.py applies the same rule to the pooled corpus counts;
/// keep the constants in sync (PARITY_* there).
enum ParityVerdict {
    /// Share of clusters whose online mean is closest to their OWN native mean.
    static let minTop1Rate = 0.95
    /// Share of clusters whose cross-model cosine clears the WeSpeaker adaptive match floor.
    static let minClearsFloorRate = 0.90
    /// Allowed rise in the different-speaker false-accept rate over the native-only baseline.
    static let maxExtraFalseAcceptRate = 0.02

    static func looksInterchangeable(_ s: ParityClusterSummary) -> Bool? {
        guard s.clustersCompared >= 2 else { return nil }
        let top1Rate = Double(s.top1Count) / Double(s.clustersCompared)
        let clearsRate = Double(s.clearsMatchFloorCount) / Double(s.clustersCompared)
        let crossFA = s.differentPairs > 0 ? Double(s.differentClearsMatchFloorCount) / Double(s.differentPairs) : 0
        let nativeFA = s.nativeDifferentPairs > 0
            ? Double(s.nativeDifferentClearsMatchFloorCount) / Double(s.nativeDifferentPairs) : 0
        return top1Rate >= minTop1Rate
            && clearsRate >= minClearsFloorRate
            && crossFA <= nativeFA + maxExtraFalseAcceptRate
    }
}

// MARK: - Math helpers

private func parityRound(_ x: Double) -> Double { (x * 10_000).rounded() / 10_000 }

/// Linear-interpolated quantile of an ascending, non-empty array (numpy's default).
func parityQuantile(_ sorted: [Double], _ q: Double) -> Double {
    let pos = q * Double(sorted.count - 1)
    let lo = Int(pos.rounded(.down))
    let hi = Swift.min(lo + 1, sorted.count - 1)
    return sorted[lo] + (sorted[hi] - sorted[lo]) * (pos - Double(lo))
}

func parityStats(_ raw: [Double]) -> ParityStats {
    let values = raw.filter { $0.isFinite }
    var histogram = [Int](repeating: 0, count: parityHistogramBins)
    guard !values.isEmpty else {
        return ParityStats(count: 0, mean: nil, median: nil, p10: nil, p90: nil,
                           min: nil, max: nil, histogram: histogram)
    }
    for v in values {
        let clamped = Swift.max(-1.0, Swift.min(1.0, v))
        let bin = Swift.min(parityHistogramBins - 1, Int((clamped + 1.0) / 2.0 * Double(parityHistogramBins)))
        histogram[bin] += 1
    }
    let sorted = values.sorted()
    return ParityStats(
        count: values.count,
        mean: parityRound(values.reduce(0, +) / Double(values.count)),
        median: parityRound(parityQuantile(sorted, 0.5)),
        p10: parityRound(parityQuantile(sorted, 0.1)),
        p90: parityRound(parityQuantile(sorted, 0.9)),
        min: parityRound(sorted[0]),
        max: parityRound(sorted[sorted.count - 1]),
        histogram: histogram
    )
}

struct ParityReferenceTurn {
    let start: Double
    let end: Double
    let speaker: String
}

func loadParityRTTM(_ path: String) -> [ParityReferenceTurn] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { die("cannot read RTTM \(path)") }
    var turns: [ParityReferenceTurn] = []
    for line in text.split(whereSeparator: { $0.isNewline }) {
        let p = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard p.count >= 8, p[0] == "SPEAKER", let start = Double(p[3]), let dur = Double(p[4]) else { continue }
        turns.append(ParityReferenceTurn(start: start, end: start + dur, speaker: String(p[7])))
    }
    guard !turns.isEmpty else { die("RTTM \(path) has no SPEAKER lines") }
    return turns
}

/// Reference speaker holding the most of [start, end), if they cover at least half of it.
func majorityReferenceSpeaker(start: Double, end: Double, reference: [ParityReferenceTurn]) -> String? {
    var bySpeaker: [String: Double] = [:]
    for turn in reference where turn.end > start && turn.start < end {
        bySpeaker[turn.speaker, default: 0] += Swift.min(end, turn.end) - Swift.max(start, turn.start)
    }
    let best = bySpeaker.max { lhs, rhs in
        lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
    }
    guard let best, best.value >= 0.5 * (end - start) else { return nil }
    return best.key
}

private struct ParityRow {
    let segment: SpeakerSegment
    let native: [Float]
    let online: [Float]
    let label: String?
}

/// Cosines between labeled rows, split by same vs different label. `symmetric` = unordered
/// pairs (i < j) of one model; otherwise ordered pairs (i != j) across two models.
private func pairCosines(
    _ rows: [ParityRow],
    _ lhs: (ParityRow) -> [Float],
    _ rhs: (ParityRow) -> [Float],
    symmetric: Bool
) -> (same: [Double], different: [Double]) {
    var same: [Double] = []
    var different: [Double] = []
    for i in rows.indices {
        guard let li = rows[i].label else { continue }
        let x = lhs(rows[i])
        for j in rows.indices where (symmetric ? j > i : j != i) {
            guard let lj = rows[j].label else { continue }
            let c = SpeakerVectorMath.cosineSimilarity(x, rhs(rows[j]))
            guard c.isFinite else { continue }
            if li == lj { same.append(c) } else { different.append(c) }
        }
    }
    return (same, different)
}

/// Pair stats are O(n^2); long own calls can have thousands of segments. Above this many
/// labeled rows, pair stats use an evenly strided subset (per-segment and cluster stats
/// always use every row).
let parityPairRowsCap = 1500

// MARK: - embedding-parity

@available(macOS 14.0, *)
func runEmbeddingParity(_ args: [String]) async {
    let usage = "embedding-parity requires --audio <wav|m4a> --out <parity.json> [--meeting NAME] "
        + "[--rttm <reference.rttm>] [--min-seconds 1.0] "
        + "[--online-models <dir with pyannote_segmentation.mlmodelc + wespeaker_v2.mlmodelc>]"
    guard let audio = argValue("--audio", in: args), let out = argValue("--out", in: args) else {
        die(usage)
    }
    let audioURL = URL(fileURLWithPath: audio)
    guard FileManager.default.fileExists(atPath: audioURL.path) else { die("audio not found: \(audio)") }
    let meeting = argValue("--meeting", in: args) ?? audioURL.deletingPathExtension().lastPathComponent
    let minSeconds = doubleArg("--min-seconds", in: args, default: 1.0)
    guard minSeconds >= 0 else { die("--min-seconds must be >= 0") }
    let reference = argValue("--rttm", in: args).map { loadParityRTTM($0) }
    let onlineModelsDir = argValue("--online-models", in: args).map { URL(fileURLWithPath: $0) }

    let sampleRate = 16000
    let samples: [Float]
    do {
        samples = try AudioResampler.loadAndResample(url: audioURL, targetRate: Double(sampleRate))
    } catch {
        die("cannot load audio \(audio): \(error.localizedDescription)")
    }
    let audioSeconds = Double(samples.count) / Double(sampleRate)

    // 1) Today's pipeline: pyannote + its native offline WeSpeaker embeddings.
    let service = await DiarizationService()
    FileHandle.standardError.write(Data(
        "[parity] \(meeting): initializing pyannote diarizer (may download models on first run)...\n".utf8))
    await service.initialize()
    let ready = await MainActor.run { service.isReady }
    guard ready else { die("pyannote diarizer failed to initialize (see logs)") }
    let t0 = Date()
    let segments: [SpeakerSegment]
    do {
        segments = try await service.diarizeOffline(samples: samples, sampleRate: sampleRate)
    } catch {
        die("diarization failed: \(error.localizedDescription)")
    }
    let diarizeSeconds = Date().timeIntervalSince(t0)
    await service.cleanup()

    // 2) The Nemotron backend's fallback voiceprint: FluidAudio's online WeSpeaker model.
    FileHandle.standardError.write(Data("[parity] \(meeting): loading online WeSpeaker embedder...\n".utf8))
    let embedder: FluidWeSpeakerSegmentEmbedder
    do {
        embedder = try await FluidWeSpeakerSegmentEmbedder.load(bundleDirectory: onlineModelsDir)
    } catch {
        die("online WeSpeaker embedder failed to load: \(error.localizedDescription)")
    }

    // 3) Re-embed the same segments (same slicing as DiarizationService.reembed).
    let t1 = Date()
    var rows: [ParityRow] = []
    var tooShort = 0, noNative = 0, onlineFailed = 0, unlabeled = 0
    for segment in segments {
        guard segment.duration >= minSeconds else { tooShort += 1; continue }
        guard let native = segment.embedding, !native.isEmpty else { noNative += 1; continue }
        let a = max(0, Int(segment.startTime * Double(sampleRate)))
        let b = min(samples.count, Int(segment.endTime * Double(sampleRate)))
        guard b > a,
              let online = embedder.embed(samples: Array(samples[a..<b]), sampleRate: sampleRate),
              online.count == native.count else {
            onlineFailed += 1
            continue
        }
        let label: String?
        if let reference {
            label = majorityReferenceSpeaker(start: segment.startTime, end: segment.endTime, reference: reference)
        } else {
            label = "S\(segment.speakerId)"
        }
        if label == nil { unlabeled += 1 }
        rows.append(ParityRow(segment: segment, native: native, online: online, label: label))
    }
    let embedSeconds = Date().timeIntervalSince(t1)

    // Per segment: the same audio through both models.
    let perSegment = parityStats(rows.map { SpeakerVectorMath.cosineSimilarity($0.native, $0.online) })

    // Pairs of segments, by speaker label (strided subset above the cap).
    let labeled = rows.filter { $0.label != nil }
    let pairRows: [ParityRow]
    if labeled.count > parityPairRowsCap {
        let step = Double(labeled.count) / Double(parityPairRowsCap)
        pairRows = (0..<parityPairRowsCap).map { labeled[Int(Double($0) * step)] }
    } else {
        pairRows = labeled
    }
    let nativePairs = pairCosines(pairRows, { $0.native }, { $0.native }, symmetric: true)
    let onlinePairs = pairCosines(pairRows, { $0.online }, { $0.online }, symmetric: true)
    let crossPairs = pairCosines(pairRows, { $0.online }, { $0.native }, symmetric: false)

    // Does pyannote hand every segment of a cluster the same (centroid) vector?
    let byCluster = Dictionary(grouping: rows, by: { $0.segment.speakerId })
    let multiSegmentClusters = byCluster.values.filter { $0.count >= 2 }
    let nativeIsClusterCentroid = !multiSegmentClusters.isEmpty && multiSegmentClusters.allSatisfy { members in
        members.allSatisfy { SpeakerVectorMath.cosineSimilarity($0.native, members[0].native) >= 0.99999 }
    }

    // Per cluster: the production quality-filtered mean — what the speaker DB stores and matches.
    var nativeMean: [Int: [Float]] = [:]
    var onlineMean: [Int: [Float]] = [:]
    var onlineMeanCount: [Int: Int] = [:]
    for (cid, members) in byCluster {
        let nativeSegs = members.map {
            SegmentDump(speakerId: cid, start: $0.segment.startTime, end: $0.segment.endTime,
                        quality: $0.segment.qualityScore, embedding: $0.native)
        }
        let onlineSegs = members.map {
            SegmentDump(speakerId: cid, start: $0.segment.startTime, end: $0.segment.endTime,
                        quality: $0.segment.qualityScore, embedding: $0.online)
        }
        guard let n = clusterMeanEmbedding(nativeSegs), let o = clusterMeanEmbedding(onlineSegs) else { continue }
        nativeMean[cid] = n.embedding
        onlineMean[cid] = o.embedding
        onlineMeanCount[cid] = o.count
    }
    let thresholds = SpeakerEmbeddingThresholds.weSpeaker
    let clusterIds = nativeMean.keys.sorted()
    var perCluster: [ParityCluster] = []
    var sameCluster: [Double] = []
    var differentCluster: [Double] = []
    var nativeDifferent: [Double] = []
    var onlineDifferent: [Double] = []
    var differentClears = 0
    var nativeDifferentClears = 0
    for a in clusterIds {
        guard let nativeA = nativeMean[a], let onlineA = onlineMean[a] else { continue }
        let meanSegments = onlineMeanCount[a] ?? 1
        let floorValue = thresholds.adaptiveMatch(forSegmentCount: max(1, meanSegments))
        let own = SpeakerVectorMath.cosineSimilarity(onlineA, nativeA)
        sameCluster.append(own)
        var bestOther: Double?
        for b in clusterIds where b != a {
            guard let nativeB = nativeMean[b], let onlineB = onlineMean[b] else { continue }
            let cross = SpeakerVectorMath.cosineSimilarity(onlineA, nativeB)
            differentCluster.append(cross)
            if cross >= floorValue { differentClears += 1 }
            bestOther = max(bestOther ?? -1, cross)
            let nn = SpeakerVectorMath.cosineSimilarity(nativeA, nativeB)
            nativeDifferent.append(nn)
            if nn >= floorValue { nativeDifferentClears += 1 }
            onlineDifferent.append(SpeakerVectorMath.cosineSimilarity(onlineA, onlineB))
        }
        let members = byCluster[a] ?? []
        perCluster.append(ParityCluster(
            cluster: a,
            segments: members.count,
            speechSeconds: parityRound(members.reduce(0.0) { $0 + $1.segment.duration }),
            meanSegments: meanSegments,
            crossModelCosine: parityRound(own),
            bestOtherNativeCosine: bestOther.map(parityRound),
            top1: bestOther.map { own > $0 } ?? true,
            matchFloor: floorValue,
            clearsMatchFloor: own >= floorValue
        ))
    }
    let clusterSummary = ParityClusterSummary(
        clustersCompared: perCluster.count,
        top1Count: perCluster.filter { $0.top1 }.count,
        clearsMatchFloorCount: perCluster.filter { $0.clearsMatchFloor }.count,
        sameCluster: parityStats(sameCluster),
        differentCluster: parityStats(differentCluster),
        differentPairs: differentCluster.count,
        differentClearsMatchFloorCount: differentClears,
        nativeDifferentCluster: parityStats(nativeDifferent),
        nativeDifferentPairs: nativeDifferent.count,
        nativeDifferentClearsMatchFloorCount: nativeDifferentClears,
        onlineDifferentCluster: parityStats(onlineDifferent),
        perCluster: perCluster
    )

    let report = EmbeddingParityReport(
        schema: parityReportSchema,
        schemaVersion: 1,
        meeting: meeting,
        audioSeconds: parityRound(audioSeconds),
        labelSource: reference == nil ? "diarizer" : "rttm",
        nativeModel: "pyannote-offline-wespeaker",
        onlineModel: FluidWeSpeakerSegmentEmbedder.embedderIdentifier,
        minSegmentSeconds: minSeconds,
        pairRowsCap: parityPairRowsCap,
        segments: ParitySegmentCounts(
            total: segments.count, compared: rows.count, tooShort: tooShort,
            noNativeEmbedding: noNative, onlineFailed: onlineFailed, unlabeled: unlabeled),
        nativeIsClusterCentroid: nativeIsClusterCentroid,
        perSegment: perSegment,
        withinModel: [
            "native": ParityPairStats(sameSpeaker: parityStats(nativePairs.same),
                                      differentSpeaker: parityStats(nativePairs.different)),
            "online": ParityPairStats(sameSpeaker: parityStats(onlinePairs.same),
                                      differentSpeaker: parityStats(onlinePairs.different)),
        ],
        crossModel: ParityPairStats(sameSpeaker: parityStats(crossPairs.same),
                                    differentSpeaker: parityStats(crossPairs.different)),
        clusters: clusterSummary,
        looksInterchangeable: ParityVerdict.looksInterchangeable(clusterSummary),
        diarizeSeconds: parityRound(diarizeSeconds),
        embedSeconds: parityRound(embedSeconds)
    )

    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    do {
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(report).write(to: url, options: .atomic)
    } catch {
        die("failed to write \(out): \(error.localizedDescription)")
    }

    let median = perSegment.median.map { String(format: "%.3f", $0) } ?? "n/a"
    let verdict = report.looksInterchangeable.map { $0 ? "yes" : "no" } ?? "n/a"
    FileHandle.standardError.write(Data((
        "[parity] \(meeting): \(rows.count)/\(segments.count) segments compared, per-segment cosine median \(median), "
        + "clusters top1 \(clusterSummary.top1Count)/\(clusterSummary.clustersCompared), "
        + "clear match floor \(clusterSummary.clearsMatchFloorCount)/\(clusterSummary.clustersCompared), "
        + "centroid=\(nativeIsClusterCentroid) interchangeable=\(verdict) -> \(out)\n").utf8))
}
