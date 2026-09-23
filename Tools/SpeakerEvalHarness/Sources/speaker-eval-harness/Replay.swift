// Replay.swift — `speaker-eval-harness replay`
//
// Load cached dumps for a session series IN ORDER, run them through the real
// EmbeddingClusterer.postProcess (within-meeting consolidation) and the real
// SpeakerDatabase match/learn/merge path (cross-meeting re-ID), then emit
// per-segment hypothesis assignments. Cheap; the lab sweeps it.
//
// Knobs (defaults reproduce the pre-lab harness exactly for WeSpeaker dumps):
//   --match <float>|adaptive       cross-meeting DB match floor. `adaptive` is what the app
//                                  ships: thresholds.adaptiveMatch(forSegmentCount:)
//   --consolidation none|<float>   EmbeddingClusterer pairwise merge (pre-lab sweep knob)
//   --same-voice profile|none|<f>  same-voice consolidation; `profile` = thresholds.consolidation
//   --thresholds auto|weSpeaker|eRes2Net   per-model cosine thresholds (auto = from the dumps)
//   --dedup match|<float>          mergeDuplicates threshold after each meeting
//                                  (`match` = the fixed match value, or 0.6 — the app's default — when adaptive)
//   --write-path-fixes off|on      legacy write path vs the SpeakerWritePathPolicy mirror
//   fingerprint update (how a matched voiceprint learns from each meeting):
//   --blend-confident <f>          EMA weight for a confident match      (SpeakerWritePathPolicy.confidentBlendAlpha)
//   --blend-cautious <f>           EMA weight for a decent match         (…cautiousBlendAlpha; fixes=on only)
//   --writeback-confident-sim <f>  similarity for the confident weight   (…confidentWriteBackSimilarity; fixes=on only)
//   --writeback-cautious-sim <f>   similarity for the cautious weight    (…cautiousWriteBackSimilarity; fixes=on only)
//   --writeback-margin <f>         runner-up margin below which we freeze (…writeBackMarginMin; fixes=on only)
// Setting both blend weights to 0 freezes every voiceprint after first sight (no learning).

import Foundation
import TranscriptedCore

// MARK: - Knob parsing

enum ThresholdProfile: String, Codable {
    case weSpeaker
    case eRes2Net

    var thresholds: SpeakerEmbeddingThresholds {
        switch self {
        case .weSpeaker: return .weSpeaker
        case .eRes2Net: return .eRes2Net
        }
    }

    static func parse(_ raw: String) -> ThresholdProfile? {
        switch raw.lowercased() {
        case "wespeaker": return .weSpeaker
        case "eres2net": return .eRes2Net
        default: return nil
        }
    }

    /// The profile a dump's embeddings were calibrated for: its recorded embedder,
    /// else its embedding dimension (192 = ERes2Net), else WeSpeaker.
    static func inferred(from dump: RawDump) -> ThresholdProfile {
        if let embedder = dump.embedder?.lowercased() {
            return embedder == "eres2net" ? .eRes2Net : .weSpeaker
        }
        return dumpEmbeddingDimension(dump) == 192 ? .eRes2Net : .weSpeaker
    }
}

/// Fingerprint write-back policy. Defaults are SpeakerWritePathPolicy's production values;
/// with defaults, `alpha` delegates to the production function so the mirror can't drift.
struct WriteBackPolicy: Codable, Equatable {
    var confidentAlpha: Float
    var cautiousAlpha: Float
    var confidentSimilarity: Double
    var cautiousSimilarity: Double
    var marginMin: Double

    static let production = WriteBackPolicy(
        confidentAlpha: SpeakerWritePathPolicy.confidentBlendAlpha,
        cautiousAlpha: SpeakerWritePathPolicy.cautiousBlendAlpha,
        confidentSimilarity: SpeakerWritePathPolicy.confidentWriteBackSimilarity,
        cautiousSimilarity: SpeakerWritePathPolicy.cautiousWriteBackSimilarity,
        marginMin: SpeakerWritePathPolicy.writeBackMarginMin
    )

    func alpha(similarity: Double, secondBestSimilarity: Double?) -> Float {
        if self == .production {
            return SpeakerWritePathPolicy.voiceprintBlendAlpha(
                similarity: similarity, secondBestSimilarity: secondBestSimilarity)
        }
        if let second = secondBestSimilarity, second >= 0, (similarity - second) < marginMin {
            return SpeakerWritePathPolicy.frozenBlendAlpha
        }
        if similarity >= confidentSimilarity { return confidentAlpha }
        if similarity >= cautiousSimilarity { return cautiousAlpha }
        return SpeakerWritePathPolicy.frozenBlendAlpha
    }
}

/// Parse an optional numeric flag; a present-but-unparseable value is a hard error so a
/// typo in an optimizer's trial never silently runs the default.
func doubleArg(_ name: String, in args: [String], default fallback: Double) -> Double {
    guard let raw = argValue(name, in: args) else { return fallback }
    guard let value = Double(raw) else { die("\(name) expects a number, got '\(raw)'") }
    return value
}

// MARK: - replay

@available(macOS 14.0, *)
func runReplay(_ args: [String]) async {
    guard let inputsCSV = argValue("--inputs", in: args), let out = argValue("--out", in: args) else {
        die("replay requires --inputs <a.json,b.json,...> (session order) --out <result.json> "
            + "[--match <float>|adaptive] [--consolidation none|<float>] [--same-voice profile|none|<float>] "
            + "[--thresholds auto|weSpeaker|eRes2Net] [--dedup match|<float>] [--write-path-fixes off|on] "
            + "[--blend-confident <f>] [--blend-cautious <f>] [--writeback-confident-sim <f>] "
            + "[--writeback-cautious-sim <f>] [--writeback-margin <f>]")
    }

    let inputs = inputsCSV.split(separator: ",").map(String.init)
    let dec = JSONDecoder()
    var dumps: [RawDump] = []
    for path in inputs {
        guard let data = FileManager.default.contents(atPath: path) else { die("cannot read \(path)") }
        do { dumps.append(try dec.decode(RawDump.self, from: data)) }
        catch { die("bad dump \(path): \(error.localizedDescription)") }
    }
    guard !dumps.isEmpty else { die("replay got no inputs") }

    // Never replay embeddings of different models/dimensions into one DB: SpeakerDatabase
    // refuses to blend mismatched dims, so the numbers would be meaningless.
    let dumpDims = Set(dumps.compactMap { dumpEmbeddingDimension($0) })
    if dumpDims.count > 1 { die("dumps mix embedding dimensions \(dumpDims.sorted()); replay one variant at a time") }

    // Per-model thresholds.
    let thresholdsArg = (argValue("--thresholds", in: args) ?? "auto").lowercased()
    let thresholdProfile: ThresholdProfile
    if thresholdsArg == "auto" {
        let inferred = Set(dumps.map { ThresholdProfile.inferred(from: $0).rawValue })
        guard inferred.count == 1, let only = inferred.first, let profile = ThresholdProfile(rawValue: only) else {
            die("dumps disagree on embedder (\(inferred.sorted())); pass --thresholds explicitly")
        }
        thresholdProfile = profile
    } else {
        guard let profile = ThresholdProfile.parse(thresholdsArg) else {
            die("unknown --thresholds \(thresholdsArg); expected auto|weSpeaker|eRes2Net")
        }
        thresholdProfile = profile
    }
    let thresholds = thresholdProfile.thresholds

    // Cross-meeting match: a fixed floor (pre-lab behavior, default 0.6) or the app's adaptive floor.
    let matchArg = (argValue("--match", in: args) ?? "0.6").lowercased()
    let fixedMatch: Double?
    if matchArg == "adaptive" {
        fixedMatch = nil
    } else {
        guard let value = Double(matchArg) else { die("--match expects a number or 'adaptive', got '\(matchArg)'") }
        fixedMatch = value
    }
    func matchFloor(segmentCount: Int) -> Double {
        fixedMatch ?? thresholds.adaptiveMatch(forSegmentCount: max(1, segmentCount))
    }

    // Pairwise merge (the pre-lab "consolidation" sweep knob).
    let consolidationArg = (argValue("--consolidation", in: args) ?? "none").lowercased()
    let consolidation: Float?
    if consolidationArg == "none" {
        consolidation = nil
    } else {
        guard let value = Float(consolidationArg) else { die("--consolidation expects none or a number, got '\(consolidationArg)'") }
        consolidation = value
    }

    // Same-voice consolidation. `profile` = the model's calibrated value, which for WeSpeaker is
    // EmbeddingClusterer.sameVoiceConsolidationThreshold — the value the pre-lab harness used implicitly.
    let sameVoiceArg = (argValue("--same-voice", in: args) ?? "profile").lowercased()
    let sameVoice: Float?
    switch sameVoiceArg {
    case "profile": sameVoice = thresholds.consolidation
    case "none": sameVoice = nil
    default:
        guard let value = Float(sameVoiceArg) else { die("--same-voice expects profile|none|<number>, got '\(sameVoiceArg)'") }
        sameVoice = value
    }

    // Duplicate-merge pass after each meeting. The app calls mergeDuplicates with its 0.6 default;
    // the pre-lab harness used the match threshold.
    let dedupArg = (argValue("--dedup", in: args) ?? "match").lowercased()
    let dedupThreshold: Double
    if dedupArg == "match" {
        dedupThreshold = fixedMatch ?? 0.6
    } else {
        guard let value = Double(dedupArg) else { die("--dedup expects match or a number, got '\(dedupArg)'") }
        dedupThreshold = value
    }

    // Write-path fixes (#6 write-time contamination gate + #8 cross-cluster link/merge decouple).
    // "off" (default) = legacy behavior: every match blends at the confident EMA rate and any clusters
    // matching the same profile collapse together. "on" = apply the SpeakerWritePathPolicy gates,
    // mirroring TranscriptionPipeline. Use the flag to A/B before/after on the same dumps.
    let writePathFixesArg = (argValue("--write-path-fixes", in: args) ?? "off").lowercased()
    guard writePathFixesArg == "on" || writePathFixesArg == "off" else {
        die("--write-path-fixes expects on|off, got '\(writePathFixesArg)'")
    }
    let writePathFixes = writePathFixesArg == "on"

    let prod = WriteBackPolicy.production
    let writeBack = WriteBackPolicy(
        confidentAlpha: Float(doubleArg("--blend-confident", in: args, default: Double(prod.confidentAlpha))),
        cautiousAlpha: Float(doubleArg("--blend-cautious", in: args, default: Double(prod.cautiousAlpha))),
        confidentSimilarity: doubleArg("--writeback-confident-sim", in: args, default: prod.confidentSimilarity),
        cautiousSimilarity: doubleArg("--writeback-cautious-sim", in: args, default: prod.cautiousSimilarity),
        marginMin: doubleArg("--writeback-margin", in: args, default: prod.marginMin)
    )

    // Fresh DB per replay so each threshold combo starts from an empty profile store,
    // exactly like a user who has never run the app before.
    let dbPath = NSTemporaryDirectory() + "speaker-eval-\(UUID().uuidString).sqlite"
    defer { try? FileManager.default.removeItem(atPath: dbPath) }
    let db = SpeakerDatabase(path: dbPath)

    var meetingResults: [MeetingResult] = []

    for dump in dumps {
        // Build SpeakerSegments from the cached embeddings.
        let segs = dump.segments.map {
            SpeakerSegment(speakerId: $0.speakerId, startTime: $0.start, endTime: $0.end,
                           embedding: $0.embedding, qualityScore: $0.quality)
        }

        // 1) Within-meeting consolidation — the real clusterer, DB-informed split uses
        //    profiles learned from prior sessions (cross-meeting context), exactly as in app.
        let existing = await MainActor.run { db.allSpeakers() }
        let profilesBefore = Set(existing.map { $0.id.uuidString })
        let consolidated = await MainActor.run {
            EmbeddingClusterer.postProcess(segments: segs, existingProfiles: existing,
                                           pairwiseMergeThreshold: consolidation,
                                           consolidationThreshold: sameVoice,
                                           thresholds: thresholds)
        }

        // Group consolidated segments by (post-consolidation) cluster id.
        var byCluster: [Int: [SegmentDump]] = [:]
        for s in consolidated {
            byCluster[s.speakerId, default: []].append(
                SegmentDump(speakerId: s.speakerId, start: s.startTime, end: s.endTime,
                            quality: s.qualityScore, embedding: s.embedding))
        }

        // 2) Cross-meeting match / learn: for each cluster, match its mean embedding
        //    against the DB (threshold sweep target); reuse or create a profile, then
        //    learn (EMA blend) — the real cross-meeting re-ID path.
        var clusterEmb: [Int: [Float]] = [:]
        var clusterEmbCount: [Int: Int] = [:]
        for (cid, segs) in byCluster {
            if let mean = clusterMeanEmbedding(segs) {
                clusterEmb[cid] = mean.embedding
                clusterEmbCount[cid] = mean.count
            }
        }
        // Deterministic order so larger (longer-speaking) clusters claim identities first.
        let clusterOrder = clusterEmb.keys.sorted {
            let a = byCluster[$0]!.reduce(0.0) { $0 + ($1.end - $1.start) }
            let b = byCluster[$1]!.reduce(0.0) { $0 + ($1.end - $1.start) }
            return a != b ? a > b : $0 < $1
        }
        var spunOffProfileIds: Set<UUID> = []
        var memberToRep: [Int: Int] = [:]   // (fixes mode) fused member cluster -> representative
        if !writePathFixes {
            // Legacy: match against the live DB, blend every match at the confident EMA rate.
            for cid in clusterOrder {
                let emb = clusterEmb[cid]!
                let floorValue = matchFloor(segmentCount: clusterEmbCount[cid] ?? 1)
                let matched = await MainActor.run { db.matchSpeaker(embedding: emb, threshold: floorValue) }
                _ = await MainActor.run {
                    db.addOrUpdateSpeaker(embedding: emb, existingId: matched?.profile.id,
                                          blendAlpha: writeBack.confidentAlpha)
                }
            }
            // 3) Dedup pass — the app runs mergeDuplicates after each transcript.
            await MainActor.run { db.mergeDuplicates(threshold: dedupThreshold) }
        } else {
            // Production mirror of TranscriptionPipeline's write path: match-all vs the pre-meeting
            // snapshot → cross-cluster link/merge (#8) via the SAME planner the app uses → gated
            // write-back (#6) → mergeDuplicates protecting spun-off distinct voices.
            var matchedProfile: [Int: UUID] = [:]
            var matchSim: [Int: Double] = [:]
            var matchSecond: [Int: Double] = [:]
            for cid in clusterOrder {
                // The exact matcher the app ships: best-of-exemplars scoring,
                // negative-exemplar veto, maturity bonus, and the ambiguity
                // rejection — not a simplified average-only mirror.
                if let m = Transcription.matchAgainstProfiles(
                    clusterEmb[cid]!, profiles: existing,
                    threshold: matchFloor(segmentCount: clusterEmbCount[cid] ?? 1)) {
                    matchedProfile[cid] = m.profileId; matchSim[cid] = m.similarity; matchSecond[cid] = m.secondBestSimilarity
                }
            }
            let plan = Transcription.planCrossClusterLinks(
                matchedProfileBySpeaker: matchedProfile,
                matchSimilarityBySpeaker: matchSim,
                meanBySpeaker: clusterEmb,
                segmentCountBySpeaker: byCluster.mapValues { $0.count }
            )
            memberToRep = plan.remaps
            let spinOffReps = Set(plan.spinOffs)
            // Write-back for representatives + uncontended clusters only; fused members inherit their
            // representative (they don't write back, mirroring the pipeline).
            for cid in clusterOrder where memberToRep[cid] == nil {
                let emb = clusterEmb[cid]!
                if spinOffReps.contains(cid) {
                    let p = await MainActor.run { db.addOrUpdateSpeaker(embedding: emb, existingId: nil) }
                    spunOffProfileIds.insert(p.id)
                } else if let pid = matchedProfile[cid] {
                    let alpha = writeBack.alpha(
                        similarity: matchSim[cid] ?? 0, secondBestSimilarity: matchSecond[cid])
                    _ = await MainActor.run {
                        db.addOrUpdateSpeaker(embedding: emb, existingId: pid, blendAlpha: alpha)
                    }
                } else {
                    _ = await MainActor.run { db.addOrUpdateSpeaker(embedding: emb, existingId: nil) }
                }
            }
            await MainActor.run { db.mergeDuplicates(threshold: dedupThreshold, protecting: spunOffProfileIds) }
        }

        // Resolve each cluster to its FINAL surviving profile. Representatives + uncontended clusters
        // re-match their mean against the post-merge DB; fused members inherit their representative's
        // profile (matchSpeaker alone could wrongly route a spun-off member back to the profile it
        // merely resembled).
        var resolved: [Int: String] = [:]
        for cid in clusterOrder where memberToRep[cid] == nil {
            let emb = clusterEmb[cid]!
            let floorValue = matchFloor(segmentCount: clusterEmbCount[cid] ?? 1)
            let m: SpeakerMatchResult? = await MainActor.run { db.matchSpeaker(embedding: emb, threshold: floorValue) }
            if let m { resolved[cid] = m.profile.id.uuidString }
        }
        for (member, rep) in memberToRep where resolved[rep] != nil {
            resolved[member] = resolved[rep]
        }
        let surviving = Set(await MainActor.run { db.allSpeakers() }.map { $0.id.uuidString })

        // Did this cluster land on a profile that existed before the meeting (the app would
        // RECOGNIZE them) or on one created in this meeting (the user would be asked to name them)?
        var clusterStatus: [String: String] = [:]
        for (cid, pid) in resolved {
            clusterStatus[String(cid)] = profilesBefore.contains(pid) ? "matched" : "new"
        }

        let assignments: [AssignmentOut] = consolidated.compactMap { s in
            guard let pid = resolved[s.speakerId] else { return nil }
            return AssignmentOut(start: s.startTime, end: s.endTime,
                                 diarizerCluster: s.speakerId, dbProfile: pid)
        }

        meetingResults.append(MeetingResult(
            meeting: dump.meeting,
            diarizerClustersAfterConsolidation: byCluster.count,
            clusterToProfile: Dictionary(uniqueKeysWithValues: resolved.map { (String($0.key), $0.value) }),
            assignments: assignments,
            rawDiarizerClusters: dump.diarizerSpeakerCount,
            clusterStatus: clusterStatus,
            profilesAfterMeeting: surviving.count))

        FileHandle.standardError.write(Data((
            "[replay] \(dump.meeting): clusters=\(byCluster.count) "
            + "profilesNow=\(surviving.count) (match=\(matchArg) consolidation=\(consolidationArg) "
            + "sameVoice=\(sameVoiceArg) thresholds=\(thresholdProfile.rawValue) "
            + "fixes=\(writePathFixes ? "on" : "off") spunOff=\(spunOffProfileIds.count))\n").utf8))
    }

    let profilesAtEnd = await MainActor.run { db.allSpeakers().count }
    let result = ReplayResult(
        consolidationThreshold: consolidationArg,
        matchThreshold: fixedMatch ?? thresholds.matchManySegments,
        writePathFixes: writePathFixes,
        profilesAtEnd: profilesAtEnd,
        meetings: meetingResults,
        matchMode: fixedMatch == nil ? "adaptive" : "fixed",
        sameVoiceThreshold: sameVoice.map { (Double($0) * 10_000).rounded() / 10_000 },
        thresholdProfile: thresholdProfile.rawValue,
        dedupThreshold: dedupThreshold,
        writeBack: writeBack,
        backend: dumps.first?.backend ?? "pyannote",
        embedder: dumps.first?.embedder ?? (thresholdProfile == .eRes2Net ? "eres2net" : "wespeaker"))
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(result).write(to: url, options: .atomic)
    } catch {
        die("failed to write \(out): \(error.localizedDescription)")
    }
    FileHandle.standardError.write(Data("[replay] wrote \(out) (profilesAtEnd=\(profilesAtEnd))\n".utf8))
}
